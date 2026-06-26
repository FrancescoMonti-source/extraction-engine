# =============================================================================
# run_variable.R -- experimental execution spine + audit envelope
# -----------------------------------------------------------------------------
# Executes one variable_spec over supplied input rows and a named list of source
# data, then assembles a reviewable audit envelope (final value, selected
# channels, per-channel status (channel_status), evidence refs, channel
# coverage/absence).
#
# Channel execution dispatches on the channel TYPE (code / text / lab), NOT on the
# channel name -- the runner must stay free of any one concept's vocabulary. The
# existing measure_*() / run_extraction() functions are reused as TEMPORARY
# adapters (they are generic over their parameters); they are not the public
# architecture.
#
# VALUE assembly dispatches on combine vs output (design note §8):
#   - combine present (a hit-set expression; any_positive() lowered to one) ->
#     cross-channel hit-set algebra over >=2 channels -> a 0/1 membership value;
#   - combine = NULL -> a SINGLE channel, assembled by output() shape:
#       binary  -> the channel's observed membership (0/1),
#       number  -> the channel's reduced numeric value,
#       categorical -> the channel's documented status,
#       fields  -> the task's several extracted fields.
# =============================================================================

suppressWarnings(suppressMessages(library(dplyr)))

.source_name_for_channel <- function(channel_name, variable) {
    variable$concept$channels[[channel_name]]$source
}

.channel_type <- function(channel_name, variable) {
    variable$concept$channels[[channel_name]]$type
}

.window_days <- function(variable) {
    if (is.null(variable$window) || !inherits(variable$window, "ee_window")) {
        stop("This experimental runner requires a relative window.", call. = FALSE)
    }
    c(from_days = variable$window$from_days, to_days = variable$window$to_days)
}

.selector_codes <- function(selector, field) {
    if (!inherits(selector, "ee_selector")) {
        stop("Channel selector is not an experimental selector.", call. = FALSE)
    }
    selector[[field]]
}

# A text channel's {coverage, candidates} either come PRE-RETRIEVED (fixtures, for
# tests/debugging) or are produced by REAL retrieval from raw documents
# (corpus + docs_index). This is the seam that makes run_variable() a real entry
# point into retrieval instead of always being handed coverage/candidates.
.resolve_text_inputs <- function(src, channel_def, variable, tasks) {
    if (is.list(src) && all(c("coverage", "candidates") %in% names(src))) {
        return(list(coverage = src$coverage, candidates = src$candidates))
    }
    if (is.list(src) && all(c("corpus", "docs_index") %in% names(src))) {
        return(.retrieve_text_channel(channel_def, variable, tasks, src))
    }
    stop("A documents source must be pre-retrieved {coverage, candidates} or raw ",
         "{corpus, docs_index}.", call. = FALSE)
}

# Real retrieval from raw documents (corpus + docs_index). Eligibility is resolved
# by the channel's LINKAGE, so the spine stays concept-agnostic:
#   - event linkage   -> the subject's documents from the SAME event (PATID + EVTID),
#                        no date window (e.g. an operative report for one surgery);
#   - subject linkage -> the subject's documents inside the variable's date window.
# Then the existing retrieve() runs the channel's Lucene query and assembles
# candidates + coverage. (Whole-history text -- subject linkage, no window -- is not
# wired here yet; supply fixtures for that, a later parallel eligibility case.)
.retrieve_text_channel <- function(channel_def, variable, tasks, src) {
    linkage <- channel_def$linkage
    if (!is.null(linkage) && "event" %in% linkage) {
        if (!all(c("PATID", "EVTID") %in% names(tasks))) {
            stop("Event-scoped text retrieval requires tasks with PATID + EVTID.",
                 call. = FALSE)
        }
        eligibility <- src$docs_index %>%
            inner_join(distinct(tasks, task_id, PATID, EVTID, anchor_date),
                       by = c("PATID", "EVTID"), relationship = "many-to-many") %>%
            transmute(task_id, ELTID, RECDATE, RECTYPE, anchor_date)
        return(retrieve(src$corpus, tasks, eligibility,
                        query = channel_def$selector$query))
    }
    if (is.null(variable$window) || !inherits(variable$window, "ee_window")) {
        stop("Real retrieval needs a date window (subject linkage) or an event ",
             "linkage; supply pre-retrieved fixtures otherwise.", call. = FALSE)
    }
    w <- .window_days(variable)
    eligibility <- src$docs_index %>%
        inner_join(distinct(tasks, task_id, PATID, anchor_date),
                   by = "PATID", relationship = "many-to-many") %>%
        filter(RECDATE >= anchor_date + w[["from_days"]],
               RECDATE <= anchor_date + w[["to_days"]]) %>%
        transmute(task_id, ELTID, RECDATE, RECTYPE, anchor_date)
    retrieve(src$corpus, tasks, eligibility, query = channel_def$selector$query)
}

# Dispatch by channel TYPE. Each branch wraps an existing tested executor.
.run_selected_channel <- function(variable, channel_name, tasks, sources,
                                  caller, model_name) {
    channel_def <- variable$concept$channels[[channel_name]]
    source <- channel_def$source
    if (!source %in% names(sources)) {
        stop("Missing source data for channel '", channel_name,
             "' (source: ", source, ").", call. = FALSE)
    }
    # The window is only meaningful for date/interval-scoped structured channels;
    # text eligibility (date-window OR event membership) is resolved upstream, so a
    # text-only variable (e.g. event-scoped anastomoses) need not declare a window.
    switch(channel_def$type,
        code = {
            codes <- .selector_codes(channel_def$selector, "prefixes")
            if (is.null(variable$window)) {     # whole-history ("ever"): no anchor/window
                measure_code_presence_ever(sources[[source]], tasks, codes = codes,
                                           field = variable$name, source = source)
            } else {
                w <- .window_days(variable)     # neutral code executor (no clinical name)
                measure_code_presence(sources[[source]], tasks, codes = codes,
                                      from_days = w[["from_days"]], to_days = w[["to_days"]],
                                      field = variable$name, source = source)
            }
        },
        lab = {
            w <- .window_days(variable)     # neutral analyte executor (no clinical name)
            measure_analyte_value(          # max usable value in window; no threshold
                sources[[source]], tasks,   # for a numeric max_value output
                analytes = .selector_codes(channel_def$selector, "codes"),
                from_days = w[["from_days"]], to_days = w[["to_days"]],
                field = variable$name, source = source)
        },
        text = {
            if (is.null(caller)) {
                stop("Text channel '", channel_name, "' requires a caller.",
                     call. = FALSE)
            }
            # The answer schema may live on the activation (neutral concept, e.g.
            # smoking) or default to the channel (concept-owned, e.g. diabetes).
            extractor <- variable$channels[[channel_name]]$extractor
            if (is.null(extractor)) extractor <- channel_def$extractor
            if (is.null(extractor)) {
                stop("Text channel '", channel_name,
                     "' has no extractor (activation or concept).", call. = FALSE)
            }
            text_inputs <- .resolve_text_inputs(sources[[source]], channel_def,
                                                variable, tasks)
            run_extraction(
                text_inputs$coverage, text_inputs$candidates,
                extractor, caller, model_name,
                query = channel_def$selector$query)
        },
        stop("No experimental executor for channel type: ", channel_def$type,
             call. = FALSE))
}

# Raw per-channel state for one task, BEFORE the {complete/unavailable/invalid/
# error} collapse -- so the source-contribution view can show WHY a channel was
# silent (no_candidate vs no rows for the subject vs no source), not just "silent".
.channel_raw_state <- function(channel_results, ch, tid) {
    cov <- channel_results[[ch]]$coverage
    s <- cov$processing_state[as.character(cov$task_id) == tid]
    if (length(s)) as.character(s[[1]]) else NA_character_
}

# How a channel contributed to the OR result, derived from its collapsed status +
# hit. The engine does NOT estimate certainty; it just exposes the contribution so
# the researcher can see e.g. a `1` that came only from the code channel while the
# text channel was silent.
.contribution_class <- function(status, hit) {
    dplyr::case_when(
        hit %in% TRUE        ~ "signal",     # this channel carried a positive
        status == "complete" ~ "negative",   # ascertained, no signal
        status == "unavailable" ~ "silent",  # nothing to ascertain (see processing_state)
        status == "invalid"  ~ "invalid",
        status == "error"    ~ "error",
        TRUE                 ~ "unknown")
}

# Single-channel binary membership (combine = NULL + binary output): the value IS
# the channel's observed hit, as OBSERVED set algebra -- a task is a member iff
# hit == TRUE, so both FALSE and NA give 0 and the value is always 0/1 (a degenerate
# one-set hit-algebra; the open-world uncertainty rides on channel_coverage, never on
# the value). The per-channel channel_status keeps the RAW processing_state, the raw
# TRUE/FALSE/NA hit, and a contribution class so a `0` from an unavailable channel is
# distinguishable from an ascertained negative.
.single_membership_variable <- function(variable, tasks, channel_name, result) {
    var_name <- variable$name
    source_name <- .source_name_for_channel(channel_name, variable)
    is_text <- identical(.channel_type(channel_name, variable), "text")
    id_col <- if (is_text) "hit_ref" else "source_row_id"
    no_candidate <- if (is_text) "unavailable" else "complete"
    task_ids <- as.character(tasks$task_id)
    reduced <- .reduce_channel_result(result, task_ids, id_col, no_candidate)

    raw_state <- function(tid) {
        s <- result$coverage$processing_state[as.character(result$coverage$task_id) == tid]
        if (length(s)) as.character(s[[1]]) else NA_character_
    }

    values_l <- list(); status_l <- list(); evidence_l <- list()
    for (tid in task_ids) {
        r <- reduced[[tid]]
        observed <- isTRUE(r$hit)               # NA / FALSE -> non-member (0)
        coverage <- switch(r$status,
            complete = "complete",
            error    = "failed",
            "partial")                          # unavailable / invalid
        refs <- if (observed && nrow(r$evidence)) {
            as.character(r$evidence$source_row_id)
        } else character()
        values_l[[length(values_l) + 1L]] <- tibble::tibble(
            task_id = tid, variable = var_name,
            value = as.integer(observed), channel_coverage = coverage)
        status_l[[length(status_l) + 1L]] <- tibble::tibble(
            task_id = tid, variable = var_name, channel = channel_name,
            source = source_name, status = r$status, hit = r$hit,
            processing_state = raw_state(tid),
            contribution = .contribution_class(r$status, r$hit),
            evidence_refs = if (length(refs)) paste(refs, collapse = "; ")
                            else NA_character_,
            error = NA_character_)
        if (length(refs)) {
            evidence_l[[length(evidence_l) + 1L]] <- tibble::tibble(
                task_id = tid, variable = var_name, channel = channel_name,
                source = source_name, source_row_id = refs, evidence_ref = refs)
        }
    }
    list(
        values = bind_rows(values_l),
        channel_status = bind_rows(status_l),
        evidence = if (length(evidence_l)) bind_rows(evidence_l) else
            tibble::tibble(task_id = character(), variable = character(),
                           channel = character(), source = character(),
                           source_row_id = character(), evidence_ref = character()))
}

# A single numeric channel (e.g. max glucose): pass the measurement through as the
# value, with per-source status and evidence shaped like the OR envelope.
.single_numeric_variable <- function(variable, tasks, channel_name, result) {
    var_name <- variable$name
    source_name <- .source_name_for_channel(channel_name, variable)
    values <- result$coverage %>%
        transmute(task_id, variable = var_name,
                  value = measurement_value,
                  channel_coverage = if_else(processing_state == "measured",
                                             "complete", "partial"))
    status <- result$coverage %>%
        transmute(
            task_id,
            variable = var_name,
            channel = channel_name,
            source = source_name,
            status = case_when(
                processing_state == "measured" ~ "complete",
                processing_state == "invalid" ~ "invalid",
                processing_state %in% c("processing_error", "model_error") ~ "error",
                TRUE ~ "unavailable"),
            hit = if_else(processing_state == "measured", TRUE, NA),
            error = NA_character_)
    evidence <- result$evidence %>%
        transmute(task_id, variable = var_name, channel = channel_name,
                  source, source_row_id, evidence_ref)
    list(values = values, channel_status = status, evidence = evidence)
}

# categorical output (combine = NULL): a single text channel whose accepted
# categorical status becomes the cohort value. Keeps the categorical STRING (not a
# binary hit), and the three non-positive outcomes distinct:
#   valid        -> the status; channel_coverage complete
#   no_candidate -> NA, partial (nothing retrieved; open-world, not absence)
#   invalid      -> NA, needs_review (e.g. definitive status without grounding)
# citation_warning (D1 keep-and-flag) rides through as a structured column: a value
# grounded by >=1 real id is kept even if the model also cited an unsupplied id.
.documented_status_variable <- function(variable, tasks, channel_name, result) {
    var_name <- variable$name
    source_name <- .source_name_for_channel(channel_name, variable)
    cov <- result$coverage
    vals <- result$values
    ev <- result$evidence
    task_ids <- as.character(tasks$task_id)
    # run_extraction returns a column-less empty tibble when no task was processed
    # (e.g. every task no_candidate); guard the per-task value lookup.
    has_vals <- nrow(vals) > 0L && "task_id" %in% names(vals)

    rows <- bind_rows(lapply(task_ids, function(tid) {
        state <- cov$processing_state[cov$task_id == tid]
        state <- if (length(state)) as.character(state[[1]]) else "no_eligible_source"
        vrow <- if (has_vals) vals[vals$task_id == tid, , drop = FALSE] else vals[0, ]
        status_val <- if (nrow(vrow)) as.character(vrow$accepted_value[[1]]) else NA_character_
        cw <- isTRUE(nrow(vrow) > 0L && "citation_warning" %in% names(vrow) &&
                     isTRUE(vrow$citation_warning[[1]]))
        reason <- if (nrow(vrow)) as.character(vrow$validity_reason[[1]]) else NA_character_
        needs_review <- state %in% c("invalid", "model_error", "processing_error")
        tibble::tibble(
            task_id = tid,
            value = if (identical(state, "valid")) status_val else NA_character_,
            channel_coverage = if (identical(state, "valid")) "complete" else "partial",
            needs_review = needs_review,
            citation_warning = cw,
            review_reason = if (needs_review) reason else NA_character_,
            status = switch(state,
                valid = "complete", invalid = "invalid",
                model_error = "error", processing_error = "error",
                "unavailable"))
    }))

    values <- rows %>%
        transmute(task_id, variable = var_name, value, channel_coverage,
                  needs_review, citation_warning, review_reason)
    channel_status <- rows %>%
        transmute(task_id, variable = var_name, channel = channel_name,
                  source = source_name, status, value, citation_warning, needs_review)
    evidence <- if (nrow(ev)) {
        ev %>% transmute(task_id, variable = var_name, channel = channel_name,
                         source = source_name, source_row_id = hit_ref,
                         evidence_ref = hit_ref, hit_text)
    } else {
        tibble::tibble(task_id = character(), variable = character(),
                       channel = character(), source = character(),
                       source_row_id = character(), evidence_ref = character(),
                       hit_text = character())
    }
    list(values = values, channel_status = channel_status, evidence = evidence)
}

# fields output (combine = NULL): one text task -> several fields. Emits one value
# row per task x field (the field's accepted value -- already NA for invalid fields, so a
# valid grounded field survives an invalid sibling), a per-task channel status with
# field counts, and per-field evidence. The task is flagged for review iff any
# field is invalid or the call failed.
.multi_field_variable <- function(variable, tasks, channel_name, result) {
    var_name <- variable$name
    source_name <- .source_name_for_channel(channel_name, variable)
    cov <- result$coverage; vals <- result$values; ev <- result$evidence
    task_ids <- as.character(tasks$task_id)

    values <- if (nrow(vals)) {
        vals %>%
            filter(task_id %in% task_ids) %>%
            transmute(task_id, variable = var_name, field,
                      value = accepted_value, field_validity,
                      needs_review = field_validity == "invalid",
                      citation_warning, validity_reason, summary = task_summary)
    } else {
        tibble::tibble(task_id = character(), variable = character(),
                       field = character(), value = character(),
                       field_validity = character(), needs_review = logical(),
                       citation_warning = logical(),
                       validity_reason = character(), summary = character())
    }

    # Per-task citation_warning = any field flagged (D1 keep-and-flag). Folded into the
    # field-count summary so the channel status row carries the same transparency as the
    # documented_status (smoking) path.
    field_counts <- if (nrow(vals)) {
        vals %>% group_by(task_id) %>%
            summarise(n_fields = n(),
                      n_valid = sum(field_validity == "valid"),
                      n_invalid = sum(field_validity == "invalid"),
                      citation_warning = any(citation_warning), .groups = "drop")
    } else {
        tibble::tibble(task_id = character(), n_fields = integer(),
                       n_valid = integer(), n_invalid = integer(),
                       citation_warning = logical())
    }
    channel_status <- tibble::tibble(task_id = task_ids) %>%
        left_join(distinct(cov, task_id, processing_state), by = "task_id") %>%
        left_join(field_counts, by = "task_id") %>%
        mutate(
            across(c(n_fields, n_valid, n_invalid), ~ coalesce(as.integer(.x), 0L)),
            citation_warning = coalesce(citation_warning, FALSE),
            status = case_when(
                processing_state %in% c("model_error", "processing_error") ~ "error",
                processing_state %in% c("no_candidate", "no_eligible_document",
                                        "not_called") ~ "unavailable",
                TRUE ~ "complete"),       # valid OR invalid task: the call produced fields
            needs_review = status == "error" | n_invalid > 0L) %>%
        transmute(task_id, variable = var_name, channel = channel_name,
                  source = source_name, status, n_fields, n_valid, n_invalid,
                  citation_warning, needs_review)

    evidence <- if (nrow(ev)) {
        ev %>% transmute(task_id, variable = var_name, channel = channel_name,
                         source = source_name, field, source_row_id = hit_ref,
                         evidence_ref = hit_ref, hit_text)
    } else {
        tibble::tibble(task_id = character(), variable = character(),
                       channel = character(), source = character(),
                       field = character(), source_row_id = character(),
                       evidence_ref = character(), hit_text = character())
    }
    list(values = values, channel_status = channel_status, evidence = evidence)
}

# hit_set_expr(): the string boolean operator. The final cohort decision is
# OBSERVED hit-set algebra, not Kleene truth logic: each channel contributes its
# OBSERVED hit set (a task is a member iff hit == TRUE; both FALSE and NA mean "no
# observed hit", hence non-member). `!A` is the complement of A's observed hit set
# within the task universe. So `A & !B` with B unavailable keeps an A-hit task
# INCLUDED (B produced no observed hit) -- the uncertainty lives in channel_coverage
# and the membership audit, never silently in the final set operation. The decision
# is therefore always determined (included / excluded); NA is preserved only in the
# per-channel audit (membership/overlap), not propagated into value/decision. (A
# strict epistemic mode that propagates NA into the decision is a deliberate future
# extension, not the default.)
#   values        per task: value (1/0), decision (included/excluded),
#                 decision_state (determined), channel_coverage (complete/partial/failed).
#   channel_status per task x channel: role (asserted/negated/mixed), status, hit
#                 (TRUE/FALSE/NA), processing_state, contribution, evidence_refs.
#   evidence      per hit ref, role-tagged.
#   membership    long-form for analysis: task_id, channel, role, hit (TRUE/FALSE/NA),
#                 processing_state, evidence_refs.
#   overlap       UpSet-style summary: one row per membership pattern (TRUE/FALSE/NA
#                 preserved) across the expression channels, with count, decision,
#                 decision_state, channel_coverage.
.hit_set_expr_variable <- function(variable, tasks, channel_results) {
    var_name <- variable$name
    combine <- variable$combine
    declared <- names(channel_results)
    referenced <- combine$channels
    missing_ch <- setdiff(referenced, declared)
    if (length(missing_ch)) {
        stop("hit-set expression references unactivated channel(s): ",
             paste(missing_ch, collapse = ", "), call. = FALSE)
    }
    roles <- combine$roles
    task_ids <- as.character(tasks$task_id)

    reduced <- lapply(declared, function(ch) {
        is_text <- identical(.channel_type(ch, variable), "text")
        id_col <- if (is_text) "hit_ref" else "source_row_id"
        no_candidate <- if (is_text) "unavailable" else "complete"
        .reduce_channel_result(channel_results[[ch]], task_ids, id_col, no_candidate)
    })
    names(reduced) <- declared

    # Audit truth: one three-valued hit vector per channel (TRUE/FALSE/NA), kept for
    # membership/overlap. Decision input: the OBSERVED hit set (hit == TRUE), so the
    # set algebra is two-valued and the decision is always determined.
    hit_vec <- function(ch) vapply(task_ids, function(tid) {
        h <- reduced[[ch]][[tid]]$hit
        if (length(h)) h[[1]] else NA
    }, logical(1))
    vectors  <- setNames(lapply(referenced, hit_vec), referenced)
    observed <- setNames(lapply(vectors, function(v) v %in% TRUE), referenced)

    result <- .eval_hitset_expr(combine$ast, observed)   # always TRUE/FALSE
    decision <- if_else(result, "included", "excluded")
    decision_state <- rep("determined", length(result))  # observed mode is determined

    # channel_coverage: were the selected channels actually evaluable for this task?
    # failed (a channel errored) > partial (a channel unavailable/unusable) > complete.
    coverage_of <- function(tid) {
        sts <- vapply(referenced, function(ch) reduced[[ch]][[tid]]$status,
                      character(1))
        if (any(sts == "error")) "failed"
        else if (any(sts %in% c("unavailable", "invalid"))) "partial"
        else "complete"
    }
    channel_coverage <- unname(vapply(task_ids, coverage_of, character(1)))

    values <- tibble::tibble(
        task_id = task_ids, variable = var_name,
        value = as.integer(result), decision = decision,
        decision_state = decision_state, channel_coverage = channel_coverage)

    role_of <- function(ch) {
        r <- if (ch %in% names(roles)) unname(roles[[ch]]) else NA_character_
        if (is.na(r)) "asserted" else r
    }
    status_l <- list(); evidence_l <- list()
    for (ch in declared) {
        src <- .source_name_for_channel(ch, variable)
        role <- role_of(ch)
        for (tid in task_ids) {
            r <- reduced[[ch]][[tid]]
            refs <- if (isTRUE(r$hit) && nrow(r$evidence)) {
                as.character(r$evidence$source_row_id)
            } else character()
            status_l[[length(status_l) + 1L]] <- tibble::tibble(
                task_id = tid, variable = var_name, channel = ch, source = src,
                role = role, status = r$status, hit = r$hit,
                processing_state = .channel_raw_state(channel_results, ch, tid),
                contribution = .contribution_class(r$status, r$hit),
                evidence_refs = if (length(refs)) paste(refs, collapse = "; ")
                                else NA_character_,
                error = NA_character_)
            if (length(refs)) {
                evidence_l[[length(evidence_l) + 1L]] <- tibble::tibble(
                    task_id = tid, variable = var_name, channel = ch, source = src,
                    role = role, source_row_id = refs, evidence_ref = refs)
            }
        }
    }
    channel_status <- bind_rows(status_l)

    wide <- tibble::tibble(task_id = task_ids)
    for (ch in referenced) wide[[ch]] <- vectors[[ch]]
    overlap <- hit_set_overlap(wide, referenced, decision, decision_state,
                               channel_coverage)

    list(
        values = values,
        channel_status = channel_status,
        evidence = if (length(evidence_l)) bind_rows(evidence_l) else
            tibble::tibble(task_id = character(), variable = character(),
                           channel = character(), source = character(),
                           role = character(), source_row_id = character(),
                           evidence_ref = character()),
        membership = channel_status %>%
            transmute(task_id, channel, role, hit, processing_state, evidence_refs),
        overlap = overlap)
}

run_variable <- function(variable, tasks, sources, caller = NULL,
                         model_name = "fake") {
    if (!inherits(variable, "ee_variable_spec")) {
        stop("run_variable() requires a variable_spec().", call. = FALSE)
    }
    if (!length(variable$channels)) {
        stop("variable_spec has no selected channels.", call. = FALSE)
    }
    channel_results <- lapply(
        names(variable$channels),
        .run_selected_channel,
        variable = variable,
        tasks = tasks,
        sources = sources,
        caller = caller,
        model_name = model_name)
    names(channel_results) <- names(variable$channels)

    channel_names <- names(variable$channels)
    selected_sources <- unname(vapply(channel_names, .source_name_for_channel,
                                      character(1), variable = variable))
    selected_produces <- vapply(variable$concept$channels[channel_names],
                                function(ch) ch$produces, character(1))
    selected <- tibble::tibble(
        variable = variable$name,
        channel = channel_names,
        source = selected_sources,
        produces = selected_produces)

    combine <- variable$combine
    if (inherits(combine, "ee_combiner") &&
        identical(combine$kind, "hit_set_expr")) {
        # Multi-channel hit-set algebra (any_positive() lowered to an expression at
        # build, or a written expression). The constructor guarantees >=2 channels.
        out <- .hit_set_expr_variable(variable, tasks, channel_results)
    } else if (is.null(combine)) {
        # Single channel (constructor-guaranteed): assemble on the output() shape.
        ch <- names(channel_results)[[1]]
        ch_type <- .channel_type(ch, variable)
        output_kind <- if (is.null(variable$output)) NA_character_ else variable$output$kind
        out <- switch(output_kind,
            binary = .single_membership_variable(
                variable, tasks, ch, channel_results[[1]]),
            number = .single_numeric_variable(
                variable, tasks, ch, channel_results[[1]]),
            categorical = {
                if (!identical(ch_type, "text")) {
                    stop("categorical output currently requires a text channel.",
                         call. = FALSE)
                }
                .documented_status_variable(variable, tasks, ch, channel_results[[1]])
            },
            fields = {
                if (!identical(ch_type, "text")) {
                    stop("fields output currently requires a text channel.",
                         call. = FALSE)
                }
                .multi_field_variable(variable, tasks, ch, channel_results[[1]])
            },
            stop("Unsupported single-channel output: ", output_kind,
                 " (expected binary/number/categorical/fields).", call. = FALSE))
    } else {
        stop("Unsupported combine; expected a hit-set expression (>=2 channels) ",
             "or NULL (single channel).", call. = FALSE)
    }
    # combine_rule = the raw hit-set expression ("a | b", "a & !b") -- the same string
    # whether written directly or lowered from any_positive(); NA for a single-channel
    # variable, which has no cross-channel combine (its value comes from output()).
    combine_rule <- if (inherits(combine, "ee_combiner")) combine$expr else NA_character_
    c(list(spec = variable, selected_channels = selected,
           combine_rule = combine_rule, channel_results = channel_results), out)
}

run_variables <- function(variables, tasks, sources, caller = NULL,
                          model_name = "fake") {
    .require_named_list(variables, "variables")
    lapply(variables, run_variable, tasks = tasks, sources = sources,
           caller = caller, model_name = model_name)
}
