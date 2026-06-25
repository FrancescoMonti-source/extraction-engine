# =============================================================================
# run_variable.R -- experimental execution spine + audit envelope
# -----------------------------------------------------------------------------
# Executes one variable_spec over supplied input rows and a named list of source
# data, then assembles a reviewable audit envelope (final value, selected
# channels, per-channel/source status, evidence refs, ascertainment/absence).
#
# Channel execution dispatches on the channel TYPE (code / text / lab), NOT on the
# channel name -- the runner must stay free of any one concept's vocabulary. The
# existing measure_*() / run_extraction() functions are reused as TEMPORARY
# adapters (they are generic over their parameters); they are not the public
# architecture. Cross-channel combination reuses combine_any_source_hit().
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

# Dispatch by channel TYPE. Each branch wraps an existing tested executor.
.run_selected_channel <- function(variable, channel_name, tasks, sources,
                                  caller, model_name) {
    channel_def <- variable$concept$channels[[channel_name]]
    source <- channel_def$source
    if (!source %in% names(sources)) {
        stop("Missing source data for channel '", channel_name,
             "' (source: ", source, ").", call. = FALSE)
    }
    w <- .window_days(variable)

    # TODO(slice-N): the lab branch reuses measure_hyperkalaemia() only as a
    # temporary adapter -- its max-usable-value-in-window + threshold core is
    # generic over the analyte and is not potassium-specific. Extract that core
    # under a neutral name (e.g. measure_analyte_value()) and have hyperkalaemia
    # become one caller, so the lab channel stops borrowing a clinically-named fn.
    switch(channel_def$type,
        code = measure_diabetes(            # temporary adapter: generic over `codes=`
            sources[[source]], tasks,
            codes = .selector_codes(channel_def$selector, "prefixes"),
            from_days = w[["from_days"]], to_days = w[["to_days"]]),
        lab = measure_hyperkalaemia(        # temporary adapter: selects the max usable
            sources[[source]], tasks,       # value in window; the threshold is unused
            analytes = .selector_codes(channel_def$selector, "codes"),  # for numeric output
            from_days = w[["from_days"]], to_days = w[["to_days"]]),
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
            run_extraction(
                sources[[source]]$coverage, sources[[source]]$candidates,
                extractor, caller, model_name,
                query = channel_def$selector$query)
        },
        stop("No experimental executor for channel type: ", channel_def$type,
             call. = FALSE))
}

# Reduce one channel's full result to the per-task {status, hit, evidence}
# contract combine_any_source_hit() consumes.
.reduce_channel_result <- function(result, task_ids, id_col,
                                   no_candidate_status = "complete") {
    .reduce_source(result, task_ids, id_col,
                   no_candidate_status = no_candidate_status)
}

# any_positive(): OR across the activated channels, one combine per task. Keyed on
# channel TYPE, not source name. The text default (no_candidate -> unavailable)
# keeps "no text retrieved" distinct from a documented negative, honouring the
# open-world absence policy; the incomplete_value comes from that policy.
.combine_any_variable <- function(variable, tasks, channel_results) {
    var_name <- variable$name
    spec_obj <- variable   # alias: `variable` is also a mutate() column name below
    task_ids <- as.character(tasks$task_id)
    values <- vector("list", length(task_ids))
    status_l <- vector("list", length(task_ids))
    evidence_l <- list()
    absence_value <- variable$absence_policy$incomplete_value
    for (i in seq_along(task_ids)) {
        tid <- task_ids[[i]]
        reduced <- lapply(names(channel_results), function(ch) {
            is_text <- identical(.channel_type(ch, variable), "text")
            id_col <- if (is_text) "hit_ref" else "source_row_id"
            no_candidate <- if (is_text) "unavailable" else "complete"
            .reduce_channel_result(channel_results[[ch]], tid, id_col,
                                   no_candidate)[[tid]]
        })
        names(reduced) <- names(channel_results)
        combined <- combine_any_source_hit(reduced, incomplete_value = absence_value)
        values[[i]] <- tibble::tibble(
            task_id = tid, variable = var_name, value = combined$value,
            ascertainment = combined$ascertainment)
        status_l[[i]] <- combined$source_status %>%
            rename(channel = source) %>%
            mutate(
                task_id = tid,
                variable = var_name,
                source = unname(vapply(channel, .source_name_for_channel,
                                       character(1), variable = spec_obj)),
                .before = 1L)
        if (nrow(combined$evidence)) {
            evidence_l[[length(evidence_l) + 1L]] <- combined$evidence %>%
                rename(channel = source) %>%
                mutate(
                    task_id = tid,
                    variable = var_name,
                    source = unname(vapply(channel, .source_name_for_channel,
                                           character(1), variable = spec_obj)),
                    evidence_ref = source_row_id,
                    .before = 1L)
        }
    }
    list(
        values = bind_rows(values),
        source_status = bind_rows(status_l),
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
                  ascertainment = if_else(processing_state == "measured",
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
    list(values = values, source_status = status, evidence = evidence)
}

# documented_status(): a single text channel whose accepted categorical status
# becomes the cohort value. Keeps the categorical STRING (not a binary hit), and
# the three non-positive outcomes distinct:
#   valid        -> the status; ascertainment complete
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

    rows <- bind_rows(lapply(task_ids, function(tid) {
        state <- cov$processing_state[cov$task_id == tid]
        state <- if (length(state)) as.character(state[[1]]) else "no_eligible_source"
        vrow <- vals[vals$task_id == tid, , drop = FALSE]
        status_val <- if (nrow(vrow)) as.character(vrow$accepted_value[[1]]) else NA_character_
        cw <- isTRUE(nrow(vrow) > 0L && "citation_warning" %in% names(vrow) &&
                     isTRUE(vrow$citation_warning[[1]]))
        reason <- if (nrow(vrow)) as.character(vrow$validity_reason[[1]]) else NA_character_
        needs_review <- state %in% c("invalid", "model_error", "processing_error")
        tibble::tibble(
            task_id = tid,
            value = if (identical(state, "valid")) status_val else NA_character_,
            ascertainment = if (identical(state, "valid")) "complete" else "partial",
            needs_review = needs_review,
            citation_warning = cw,
            review_reason = if (needs_review) reason else NA_character_,
            status = switch(state,
                valid = "complete", invalid = "invalid",
                model_error = "error", processing_error = "error",
                "unavailable"))
    }))

    values <- rows %>%
        transmute(task_id, variable = var_name, value, ascertainment,
                  needs_review, citation_warning, review_reason)
    source_status <- rows %>%
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
    list(values = values, source_status = source_status, evidence = evidence)
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
        identical(combine$kind, "any_positive")) {
        out <- .combine_any_variable(variable, tasks, channel_results)
    } else if (inherits(combine, "ee_combiner") &&
               identical(combine$kind, "documented_status")) {
        if (length(channel_results) != 1L) {
            stop("documented_status() currently supports a single channel.",
                 call. = FALSE)
        }
        ch <- names(channel_results)[[1]]
        if (!identical(.channel_type(ch, variable), "text")) {
            stop("documented_status() currently requires a text channel.",
                 call. = FALSE)
        }
        out <- .documented_status_variable(variable, tasks, ch, channel_results[[1]])
    } else if (length(channel_results) == 1L) {
        ch <- names(channel_results)[[1]]
        reducer <- variable$channels[[ch]]$reducer
        if (!inherits(reducer, "ee_reducer") ||
            !identical(reducer$kind, "max_value")) {
            stop("Single-channel direct specs currently require max_value().",
                 call. = FALSE)
        }
        out <- .single_numeric_variable(variable, tasks, ch, channel_results[[1]])
    } else {
        stop("This experimental runner supports any_positive(), documented_status(), ",
             "or a single max_value() channel.", call. = FALSE)
    }
    c(list(spec = variable, selected_channels = selected,
           channel_results = channel_results), out)
}

run_variables <- function(variables, tasks, sources, caller = NULL,
                          model_name = "fake") {
    .require_named_list(variables, "variables")
    lapply(variables, run_variable, tasks = tasks, sources = sources,
           caller = caller, model_name = model_name)
}
