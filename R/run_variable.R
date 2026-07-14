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
# VALUE assembly dispatches on combine vs output (design note §8): the combine
# gates ROWS, the output decides what those rows become.
#   - combine present (a hit-set expression; any_positive() lowered to one) ->
#     set algebra over >=2 channels' observed hit sets; then bin_output() lifts
#     membership (0/1), while num/cat_output(values_from =, reduce =) reduce the
#     surviving tasks' payload values into the final value (gate-fail -> NA);
#   - combine = NULL -> a SINGLE channel, assembled by output() shape:
#       binary  -> the channel's observed membership (0/1),
#       number / categorical with reduce -> the channel's own payload rows reduced,
#       categorical without reduce -> a text channel's documented status,
#       fields  -> the task's several extracted fields.
# =============================================================================

# Execution receives only the compiled representation.
.channel_def <- function(variable, channel_name) {
    variable$channels[[channel_name]]
}

.source_name_for_channel <- function(channel_name, variable) {
    .channel_def(variable, channel_name)$source
}

.channel_type <- function(channel_name, variable) {
    .channel_def(variable, channel_name)$type
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

.validate_pre_retrieved_text <- function(coverage, candidates, tasks,
                                         required_roles) {
    if (!"coverage_state" %in% names(coverage)) {
        stop("Pre-retrieved text coverage must contain coverage_state.",
             call. = FALSE)
    }
    if ("subject_id" %in% required_roles &&
        (!"PATID" %in% names(tasks) || anyNA(tasks$PATID) ||
         any(!nzchar(as.character(tasks$PATID))))) {
        stop("Pre-retrieved text tasks do not satisfy required role subject_id.",
             call. = FALSE)
    }
    candidate_tasks <- unique(as.character(
        coverage$task_id[coverage$coverage_state == "candidate"]))
    candidate_tasks <- candidate_tasks[!is.na(candidate_tasks)]
    if (!length(candidate_tasks)) return(invisible(TRUE))

    role_columns <- c(
        event_id = "EVTID", point_date = "RECDATE", text = "snippet_text",
        source_item_id = "ELTID", document_type = "RECTYPE")
    required_columns <- unique(c(
        "task_id", "snippet_id", "hit_ref",
        unname(role_columns[intersect(required_roles, names(role_columns))])))
    missing <- setdiff(required_columns, names(candidates))
    if (length(missing)) {
        stop("Pre-retrieved text candidates are missing required column(s): ",
             paste(missing, collapse = ", "), ".", call. = FALSE)
    }
    relevant <- candidates[as.character(candidates$task_id) %in% candidate_tasks,
                           , drop = FALSE]
    missing_tasks <- setdiff(candidate_tasks, as.character(relevant$task_id))
    if (length(missing_tasks)) {
        stop("Pre-retrieved text coverage declares ", length(missing_tasks),
             " candidate task(s) without candidate rows.", call. = FALSE)
    }
    for (column in setdiff(required_columns, "task_id")) {
        value <- relevant[[column]]
        if (anyNA(value) || any(!nzchar(as.character(value)))) {
            stop("Pre-retrieved text candidate column '", column,
                 "' contains missing values.", call. = FALSE)
        }
    }
    if ("point_date" %in% required_roles &&
        !inherits(relevant$RECDATE, c("Date", "POSIXt"))) {
        stop("Pre-retrieved text point_date must be Date or POSIXt.",
             call. = FALSE)
    }
    invisible(TRUE)
}

# A text channel's {coverage, candidates} either come PRE-RETRIEVED (fixtures, for
# tests/debugging) or are produced by REAL retrieval from a metadata-rich tCorpus.
# This is the seam that makes run_variable() a real entry
# point into retrieval instead of always being handed coverage/candidates.
.resolve_text_inputs <- function(src, channel_def, variable, tasks, selector) {
    if (is.list(src) && all(c("coverage", "candidates") %in% names(src))) {
        coverage <- src$coverage
        candidates <- src$candidates
        if (!is.data.frame(coverage) || !is.data.frame(candidates)) {
            stop("Pre-retrieved text coverage and candidates must be data frames.",
                 call. = FALSE)
        }
        if (!"task_id" %in% names(coverage)) {
            stop("Pre-retrieved text coverage must contain task_id.",
                 call. = FALSE)
        }
        if (!"task_id" %in% names(candidates)) {
            if (nrow(candidates)) {
                stop("Pre-retrieved text candidates must contain task_id.",
                     call. = FALSE)
            }
            candidates$task_id <- character()
        }
        declared <- as.character(tasks$task_id)
        supplied <- unique(c(as.character(coverage$task_id),
                             as.character(candidates$task_id)))
        supplied <- supplied[!is.na(supplied)]
        unknown <- setdiff(supplied, declared)
        if (length(unknown)) {
            stop("Pre-retrieved text inputs reference ", length(unknown),
                 " task(s) outside the declared cohort.", call. = FALSE)
        }
        .validate_pre_retrieved_text(
            coverage, candidates, tasks, channel_def$required_roles)
        return(list(coverage = coverage, candidates = candidates))
    }
    raw <- .raw_document_source(src)
    if (!is.null(raw)) {
        return(.retrieve_text_channel(channel_def, variable, tasks, raw, selector))
    }
    stop("A documents source must be a metadata-rich tCorpus or pre-retrieved ",
         "{coverage, candidates}.", call. = FALSE)
}

# Real retrieval from a tCorpus and its private metadata view. The declared evidence
# scope is resolved first; an authored temporal window is then intersected with
# that eligible set. With no window, patient scope sees the whole record and event
# scope sees the whole event.
# Then the existing retrieve() runs the channel's Lucene query and assembles
# candidates + coverage. Eligibility keeps the document's EVTID when metadata
# carries it, so a text hit stays attributable to its stay (combine_at_level, §7).
.text_eligibility_cols <- function(d) {
    select(d, any_of(c("task_id", "ELTID", "EVTID", "RECDATE", "RECTYPE",
                       "anchor_date")))
}

.retrieve_text_channel <- function(channel_def, variable, tasks, src, selector) {
    event_scoped <- identical(channel_def$evidence_scope, "event")
    if (event_scoped) {
        if (!all(c("PATID", "EVTID") %in% names(tasks))) {
            stop("Event-scoped text retrieval requires tasks with PATID + EVTID.",
                 call. = FALSE)
        }
    }
    join_keys <- if (event_scoped) c("PATID", "EVTID") else "PATID"
    task_columns <- c("task_id", join_keys,
                      if (!is.null(variable$anchor)) "anchor_date")
    keys <- tasks %>% select(all_of(task_columns)) %>% distinct()
    eligibility <- src$docs_index %>%
        inner_join(keys, by = join_keys, relationship = "many-to-many")
    if (!is.null(variable$window)) {
        if (!inherits(variable$window, "ee_window")) {
            stop("Real retrieval requires a compiled relative window.",
                 call. = FALSE)
        }
        w <- .window_days(variable)
        eligibility <- eligibility %>%
            filter(RECDATE >= anchor_date + w[["from_days"]],
                   RECDATE <= anchor_date + w[["to_days"]])
    }
    eligibility <- .text_eligibility_cols(eligibility)
    retrieve(src$corpus, tasks, eligibility, query = selector$query)
}

# Deterministic text presence: a Lucene match is the measured signal. No prompt,
# schema, parser, or Chat participates in this path.
.run_lucene_presence <- function(text_inputs) {
    coverage <- text_inputs$coverage %>%
        mutate(processing_state = case_when(
            coverage_state == "no_eligible_document" ~ "no_eligible_document",
            coverage_state == "no_candidate" ~ "no_candidate",
            coverage_state == "candidate" ~ "measured",
            TRUE ~ "processing_error"))
    values <- text_inputs$candidates %>%
        distinct(task_id) %>%
        transmute(task_id = as.character(task_id), accepted_value = "present")
    list(
        coverage = coverage,
        values = values,
        evidence = text_inputs$candidates,
        attempts = tibble::tibble(),
        candidates = text_inputs$candidates,
        model_candidates = text_inputs$candidates[0, , drop = FALSE])
}

# Resolve a coded channel's PHYSICAL columns from its source's roles (registry):
# which column is the code, and the time field(s) -- a point source uses one date
# for both ends.
.code_source_binding <- function(source) {
    spec <- EE_SOURCES[[source]]
    if (is.null(spec)) stop("Unknown prepared EDSAN source: ", source, call. = FALSE)
    code_col <- source_roles(spec)$code
    if (is.null(code_col)) {
        stop("Prepared source '", source, "' has no code role.", call. = FALSE)
    }
    if (identical(spec$source_time_kind, "point")) {
        d <- spec$source_time_start
        list(code_col = code_col, start_col = d, end_col = d)
    } else {
        list(code_col = code_col,
             start_col = spec$source_time_start,
             end_col = spec$source_time_end)
    }
}

.lab_source_binding <- function(source) {
    spec <- EE_SOURCES[[source]]
    if (is.null(spec)) stop("Unknown prepared EDSAN source: ", source, call. = FALSE)
    roles <- source_roles(spec)
    required <- c("source_result_id", "point_date", "analyte", "value_num",
                  "value_str")
    missing <- setdiff(required, names(roles))
    if (length(missing)) {
        stop("Prepared source '", source, "' lacks lab role(s): ",
             paste(missing, collapse = ", "), ".", call. = FALSE)
    }
    list(
        result_id_col = roles$source_result_id,
        date_col = roles$point_date,
        analyte_col = roles$analyte,
        value_col = roles$value_num,
        value_raw_col = roles$value_str)
}

# Grain guard: the OUTPUT GRAIN (variable$output_one_row_per) is carried by the task
# universe -- one task row per grain unit. This checks the tasks frame actually is at
# the declared grain and returns the identity keys the structured executors scope by:
# unique(c("PATID", output_one_row_per)) -- "PATID" alone at patient grain, c("PATID",
# "EVTID") at stay grain. DESIGN §7: the variable_spec decides the unit; the engine
# checks the tasks can be mechanically linked to it.
.check_output_grain <- function(variable, tasks) {
    grain <- variable$output_one_row_per %||% "PATID"
    grain_keys <- unique(c("PATID", grain))
    missing_cols <- setdiff(grain_keys, names(tasks))
    if (length(missing_cols)) {
        stop("output_one_row_per = '", grain, "' needs task column(s): ",
             paste(missing_cols, collapse = ", "),
             " -- grain is carried by the task universe (one task per ", grain, ").",
             call. = FALSE)
    }
    for (k in grain_keys) {
        if (anyNA(tasks[[k]])) {
            stop("grain column '", k, "' has NA in tasks; every output row must ",
                 "identify its ", grain, ".", call. = FALSE)
        }
    }
    key <- do.call(paste, c(lapply(grain_keys, function(k) as.character(tasks[[k]])),
                            sep = "\r"))
    if (anyDuplicated(key)) {
        stop("output_one_row_per = '", grain, "' requires one task per ", grain,
             ", but the tasks frame repeats a ", paste(grain_keys, collapse = "+"),
             " combination.", call. = FALSE)
    }
    grain_keys
}

# Derived-anchor PASS: when variable$anchor is an index_event(), compute a per-subject
# anchor_date BEFORE windowing -- find each subject's event matching the selector in the
# named source and take its date at role `at`. This is a resolution pass producing
# (PATID, anchor_date), NOT an inter-channel dependency. A string anchor names the
# caller-supplied task column that is normalized to the internal anchor_date clock.
.resolve_anchor <- function(variable, tasks, sources) {
    anchor <- variable$anchor
    if (is.null(anchor)) {
        if (!is.null(variable$window)) {
            stop("A relative window cannot execute without a declared anchor.",
                 call. = FALSE)
        }
        return(tasks)
    }
    if (is.character(anchor)) {
        if (!anchor %in% names(tasks)) {
            stop("The declared anchor task column is missing: '", anchor, "'.",
                 call. = FALSE)
        }
        tasks$anchor_date <- .clinical_date(tasks[[anchor]])
        if (anyNA(tasks$anchor_date)) {
            stop("The declared anchor task column contains missing values.",
                 call. = FALSE)
        }
        return(tasks)
    }

    src <- sources[[anchor$source]]
    if (is.null(src)) {
        stop("index_event anchor needs source '", anchor$source, "' in sources.",
             call. = FALSE)
    }
    spec <- EE_SOURCES[[anchor$source]]
    if (is.null(spec)) {
        stop("index_event requires a registered prepared EDSAN source; got '",
             anchor$source, "'.", call. = FALSE)
    }
    validate_source_view(src, spec)
    roles <- source_roles(spec)
    code_col <- roles$code %||% NULL
    if (is.null(code_col)) {
        stop("index_event: source '", anchor$source, "' lacks a 'code' role.",
             call. = FALSE)
    }
    # `at` names the source's own date COLUMN (owner ruling 2026-07-07: raw names,
    # not role vocabulary); omitted, it defaults to the source's windowing clock.
    date_col <- anchor$at %||% spec$source_time_start
    if (is.null(date_col)) {
        stop("index_event: source '", anchor$source,
             "' has no registered source clock.", call. = FALSE)
    }
    if (!date_col %in% names(src)) {
        hint <- if (date_col %in% c("point_date", "event_start", "event_end")) {
            " (date ROLES were retired from `at`: name the source's own column, e.g. DATEACTE/DATENT/DATSORT)"
        } else ""
        stop("index_event: '", date_col, "' is not a column of source '",
             anchor$source, "'", hint, ".", call. = FALSE)
    }
    sel <- anchor$selector
    matched <- src %>%
        transmute(PATID = as.character(PATID),
                  EVTID = as.character(EVTID),
                  code_val = as.character(.data[[code_col[[1]]]]),
                  anchor_date = .clinical_date(.data[[date_col]])) %>%
        filter(.code_matches(code_val, sel$codes, sel$match))

    # Multi-match: the researcher's select_event closure picks which event(s)
    # anchor the clock (DESIGN §7, invariant 35); without it the engine never
    # picks -- loud error. The closure sees the subject's matched rows with the
    # date under the source's own COLUMN name (the resolved `at`), exactly as
    # written in the spec: select_event = \(d) dplyr::slice_min(d, DATEACTE, n = 1).
    select_event <- anchor$select_event
    dup <- matched %>% count(PATID) %>% filter(n > 1L)
    if (nrow(dup) && is.null(select_event)) {
        stop("index_event matched multiple events for ", nrow(dup),
             " subject(s) -- supply select_event = <closure over the matched rows> ",
             "(the engine never picks).", call. = FALSE)
    }
    if (!is.null(select_event) && nrow(matched)) {
        view <- matched %>% select(PATID, EVTID, anchor_date)
        names(view)[names(view) == "anchor_date"] <- date_col
        selected <- view %>%
            group_by(PATID) %>%
            group_modify(function(d, key) {
                out <- select_event(dplyr::bind_cols(key, d))
                if (!is.data.frame(out) ||
                    !all(c("EVTID", date_col) %in% names(out))) {
                    stop("select_event must return matched event row(s) ",
                         "keeping the EVTID and ", date_col, " columns.",
                         call. = FALSE)
                }
                out[setdiff(names(out), "PATID")]
            }) %>%
            ungroup()
        if (!nrow(selected) ||
            length(missing_sel <- setdiff(unique(matched$PATID),
                                          unique(selected$PATID)))) {
            n_missing <- if (nrow(selected)) length(missing_sel) else
                dplyr::n_distinct(matched$PATID)
            stop("select_event selected no event for ", n_missing,
                 " subject(s) -- every unit needs its index event.",
                 call. = FALSE)
        }
        matched <- selected %>%
            transmute(PATID = as.character(PATID),
                      EVTID = as.character(EVTID),
                      anchor_date = .clinical_date(.data[[date_col]]))
    }
    anchors <- matched %>% distinct(PATID, EVTID, anchor_date)

    # Per-event task emission (invariant 35): one task per SELECTED event, each
    # with its own anchor date and the index event's identity (EVTID). With one
    # event per subject and patient-grain output, task ids pass through
    # unchanged (today's behavior); several events per subject require the
    # output grain to name the event key, and task ids gain the event suffix.
    per_event <- !identical(variable$output_one_row_per, "PATID")
    multi <- anchors %>% count(PATID) %>% filter(n > 1L)
    if (nrow(multi) && !per_event) {
        stop("select_event kept several events for ", nrow(multi),
             " subject(s) -- output_one_row_per = 'PATID' allows one task per patient; ",
             "select one event or declare the event-grain output (one row ",
             "per index event).", call. = FALSE)
    }
    tasks$anchor_date <- NULL
    tasks$EVTID <- NULL
    tasks <- tasks %>%
        left_join(anchors, by = "PATID",
                  relationship = if (per_event) "many-to-many" else "many-to-one")
    unresolved <- unique(tasks$PATID[is.na(tasks$anchor_date)])
    if (length(unresolved)) {
        stop("index_event found no matching event for ", length(unresolved),
             " subject(s) -- every unit needs its index event.",
             call. = FALSE)
    }
    if (per_event) {
        tasks$task_id <- paste(tasks$task_id, tasks$EVTID, sep = "::")
    }
    tasks
}

.channel_scope_keys <- function(channel_def, variable, tasks, grain_keys) {
    if (identical(channel_def$evidence_scope, "event")) {
        required <- c("PATID", "EVTID")
        missing <- setdiff(required, names(tasks))
        if (length(missing)) {
            stop("Event-scoped channel '", channel_def$name,
                 "' requires task column(s): ", paste(missing, collapse = ", "),
                 ".", call. = FALSE)
        }
        if (anyNA(tasks$EVTID) || any(!nzchar(as.character(tasks$EVTID)))) {
            stop("Event-scoped tasks require non-missing EVTID values.",
                 call. = FALSE)
        }
        return(required)
    }
    if (is.null(variable$window)) grain_keys else "PATID"
}

# Dispatch by channel TYPE. Each branch wraps an existing tested executor.
.run_selected_channel <- function(variable, channel_name, tasks, sources,
                                  chat, grain_keys = "PATID") {
    channel_def <- .channel_def(variable, channel_name)
    # Activation may locally override the concept's baseline selector (DESIGN §14.3):
    # use_channel(selector = ...) replaces the inherited selector for THIS variable
    # without mutating the concept. It is resolved ONCE and used by every branch
    # (and threaded into text retrieval) so the override is uniform.
    selector <- channel_def$selector
    source <- channel_def$source
    if (!source %in% names(sources)) {
        stop("Missing source data for channel '", channel_name,
             "' (source: ", source, ").", call. = FALSE)
    }
    spec <- EE_SOURCES[[source]]
    if (is.null(spec)) {
        stop("Channel '", channel_name,
             "' requires a registered prepared EDSAN source; got '", source,
             "'.", call. = FALSE)
    }
    if (channel_def$type %in% c("code", "act", "lab")) {
        validate_source_view(sources[[source]], spec)
    }
    # The window is only meaningful for date/interval-scoped structured channels;
    # text eligibility (date-window OR event membership) is resolved upstream, so a
    # text-only variable (e.g. event-scoped anastomoses) need not declare a window.
    #
    # Aggregate membership predicates (keep_group_when, DESIGN §8) ride every
    # STRUCTURED channel (owner ruling 2026-07-05: "it will be needed 100%") --
    # lab groups over measurements, code/act over codes. Text is rejected loudly
    # until its post-acceptance semantics are decided: a text hit is an LLM answer
    # grounded on cited rows, so a group rule that empties the citations would
    # have to overturn the answer (absent? unevaluable?) -- an open fork, not a
    # silent ignore.
    if (!is.null(channel_def$keep_group_when) &&
        identical(channel_def$type, "text")) {
        stop("keep_group_when on text channel '", channel_name, "': the ",
             "post-acceptance semantics are undecided (structured channels ",
             "carry the group predicate today).", call. = FALSE)
    }
    switch(channel_def$type,
        code = ,
        act = {
            # code (CIM-10 over pmsi$diag) and act (CCAM over pmsi$actes) share the
            # neutral membership executor; only the source binding differs.
            sel <- selector
            bind <- .code_source_binding(source)
            w <- if (is.null(variable$window)) list(from_days = NULL, to_days = NULL)
                 else .window_days(variable)
            measure_code_presence(
                sources[[source]], tasks, codes = sel$codes, match = sel$match,
                grain_keys = grain_keys,
                from_days = w[["from_days"]], to_days = w[["to_days"]],
                group_at_level = channel_def$group_at_level,
                keep_group_when = channel_def$keep_group_when,
                code_col = bind$code_col, start_col = bind$start_col,
                end_col = bind$end_col, field = variable$name, source = source)
        },
        lab = {
            # Neutral analyte executor: scopes candidate rows by grain (subject or stay)
            # and window. A thresholded selector (analyte_value) folds a value predicate
            # into the target set (membership face); the value face reduces candidates in
            # assembly. A NULL window is event-scoped (rows sharing the task's grain unit).
            w <- if (is.null(variable$window)) list(from_days = NULL, to_days = NULL)
                 else .window_days(variable)
            bind <- .lab_source_binding(source)
            measure_analyte_values(
                sources[[source]], tasks,
                analytes = .selector_codes(selector, "codes"),
                gt = selector$gt, lt = selector$lt,
                keep_when = selector$keep_when, grain_keys = grain_keys,
                from_days = w[["from_days"]], to_days = w[["to_days"]],
                group_at_level = channel_def$group_at_level,
                keep_group_when = channel_def$keep_group_when,
                result_id_col = bind$result_id_col,
                date_col = bind$date_col,
                analyte_col = bind$analyte_col,
                value_col = bind$value_col,
                value_raw_col = bind$value_raw_col,
                field = variable$name, source = source)
        },
        doc = {
            # Metadata-selected document existence (no content, no LLM): the doc
            # branch reads document metadata only; a tCorpus contributes its
            # metadata view and a bare frame is already an index.
            if (!identical(selector$kind, "doc_meta")) {
                stop("Doc channel '", channel_name, "' needs a doc_meta() ",
                     "selector.", call. = FALSE)
            }
            src <- sources[[source]]
            docs_index <- .document_index(src)
            validate_source_view(docs_index, spec)
            w <- if (is.null(variable$window)) list(from_days = NULL, to_days = NULL)
                 else .window_days(variable)
            measure_doc_presence(
                docs_index, tasks, filters = selector$filters,
                grain_keys = grain_keys,
                from_days = w[["from_days"]], to_days = w[["to_days"]],
                group_at_level = channel_def$group_at_level,
                keep_group_when = channel_def$keep_group_when,
                date_col = spec$source_time_start,
                field = variable$name, source = source)
        },
        text = {
            method <- channel_def$method
            text_inputs <- .resolve_text_inputs(sources[[source]], channel_def,
                                                 variable, tasks, selector)
            if (identical(method, "lucene")) {
                .run_lucene_presence(text_inputs)
            } else if (identical(method, "lucene_llm")) {
                if (is.null(chat)) {
                    stop("Text channel '", channel_name,
                         "' with method = 'lucene_llm' requires an ellmer Chat.",
                         call. = FALSE)
                }
                definition <- .compile_llm_channel(channel_def, variable)
                run_extraction(
                    text_inputs$coverage, text_inputs$candidates,
                    definition, chat,
                    .candidate_selector(channel_def$max_candidates),
                    query = selector$query)
            } else {
                stop("Unsupported text method for channel '", channel_name,
                     "': ", method, ".", call. = FALSE)
            }
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

.no_candidate_status <- function(channel_name, variable) {
    channel <- .channel_def(variable, channel_name)
    if (identical(channel$type, "text") &&
        identical(channel$method, "lucene_llm")) {
        "unavailable"
    } else {
        "complete"
    }
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
    no_candidate <- .no_candidate_status(channel_name, variable)
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

# --- output payload (DESIGN §8) -------------------------------------------------
# The values BEHIND a channel's hits, one per surviving row: a lab row's value is
# its measurement, a code/act row's value is its code. The output's `reduce` (a
# plain values -> scalar closure) collapses them per task. With a sub-output-grain
# gate (combine_at_level, §7) `level` names the key the rows must carry, so the
# payload can be scoped to the qualifying keys.
.payload_values <- function(result, channel_type, level = NULL) {
    rows <- switch(channel_type,
        lab = result$candidates,
        code = ,
        act = result$evidence %>% mutate(value = code),
        stop("values_from is wired for lab/code/act channels, not '",
             channel_type, "'.", call. = FALSE))
    if (is.null(level)) {
        return(rows %>% transmute(task_id = as.character(task_id), value))
    }
    if (!level %in% names(rows)) {
        stop("values_from payload rows do not carry the combine_at_level key '",
             level, "'; the payload cannot be scoped to the qualifying keys.",
             call. = FALSE)
    }
    rows %>% transmute(task_id = as.character(task_id),
                       key = as.character(.data[[level]]), value)
}

# Date payload (date_output, DESIGN §8): the value of a hit row is its CLOCK --
# the same date the engine windowed the row on (doc RECDATE, lab DATEXAM, a
# code/act row's own start date). Text channels are design-ALLOWED as a date
# payload (owner ruling 2026-07-07: a document date is the researcher's call,
# guarded by provenance not prohibition) but wait for their consumer.
.payload_date_values <- function(result, channel_type, level = NULL) {
    rows <- switch(channel_type,
        doc = result$candidates,                       # value = the doc's clock
        lab = result$candidates %>% mutate(value = measurement_time),
        code = ,
        act = result$evidence %>% mutate(value = t_start),
        stop("date_output values_from is wired for doc/lab/code/act channels, ",
             "not '", channel_type, "' (a text channel's document date is ",
             "design-allowed but waits for its consumer).", call. = FALSE))
    if (is.null(level)) {
        return(rows %>% transmute(task_id = as.character(task_id), value))
    }
    if (!level %in% names(rows)) {
        stop("values_from payload rows do not carry the combine_at_level key '",
             level, "'; the payload cannot be scoped to the qualifying keys.",
             call. = FALSE)
    }
    rows %>% transmute(task_id = as.character(task_id),
                       key = as.character(.data[[level]]), value)
}

# The kind-appropriate payload rows for an output: dates read the rows' clock,
# num/cat read the rows' values (lab measurement / code).
.output_payload <- function(result, channel_type, output, level = NULL) {
    if (identical(output$kind, "date")) {
        .payload_date_values(result, channel_type, level = level)
    } else {
        .payload_values(result, channel_type, level = level)
    }
}

# Apply reduce to one task's payload values and validate the result against the
# output's declared contract. A closure breaking its own contract (non-numeric for
# num, outside `levels` for cat, not exactly one value) is a HARD error, not a
# review state: unlike an ungrounded LLM answer, a deterministic rule violating
# its declaration is a bug (DESIGN §8). A deliberate NA return is allowed for num
# (the closure's own missing rule), never for cat (NA is not a level).
.reduce_payload <- function(vals, output, variable_name) {
    res <- output$reduce(vals)
    if (length(res) != 1L) {
        stop("reduce for '", variable_name, "' must return exactly one value; ",
             "got ", length(res), ".", call. = FALSE)
    }
    if (identical(output$kind, "number")) {
        was_na <- is.na(res)
        res <- suppressWarnings(as.numeric(res))
        if (is.na(res) && !was_na) {
            stop("reduce for '", variable_name, "' returned a non-numeric value.",
                 call. = FALSE)
        }
        return(res)
    }
    if (identical(output$kind, "date")) {
        # A deliberate NA is the closure's own missing rule (like num); anything
        # else must BE a Date -- a silent coercion here would be exactly the
        # min()-over-strings failure date_output exists to prevent.
        if (!inherits(res, "Date") && !is.na(res)) {
            stop("reduce for '", variable_name, "' must return a Date (or NA); ",
                 "got class '", class(res)[[1]], "'.", call. = FALSE)
        }
        return(as.Date(res))
    }
    res <- as.character(res)
    if (is.na(res) || !res %in% output$levels) {
        stop("reduce for '", variable_name, "' returned '", res,
             "', not one of levels: ", paste(output$levels, collapse = ", "),
             ".", call. = FALSE)
    }
    res
}

# A single payload channel (combine = NULL, num/cat output with reduce): the
# channel's own filtered rows ARE the survivors; the output's reduce collapses
# each task's payload values (e.g. max glucose, count of acts, modality from a
# code family). A task with no payload rows is NA/partial. Status and evidence
# keep the OR-envelope shape; evidence is every row the reduction saw.
.single_payload_variable <- function(variable, tasks, channel_name, result) {
    var_name <- variable$name
    source_name <- .source_name_for_channel(channel_name, variable)
    output <- variable$output
    payload <- .output_payload(result, .channel_type(channel_name, variable),
                               output)
    task_ids <- as.character(tasks$task_id)
    state_of <- function(tid) {
        s <- result$coverage$processing_state[
            as.character(result$coverage$task_id) == tid]
        if (length(s)) as.character(s[[1]]) else NA_character_
    }
    na_value <- switch(output$kind,
                       number = NA_real_,
                       date = as.Date(NA),
                       NA_character_)

    values_l <- list(); status_l <- list()
    for (tid in task_ids) {
        vals <- payload$value[payload$task_id == tid]
        measured <- length(vals) > 0L
        value <- if (measured) .reduce_payload(vals, output, var_name) else na_value
        values_l[[length(values_l) + 1L]] <- tibble::tibble(
            task_id = tid, variable = var_name, value = value,
            channel_coverage = if (measured) "complete" else "partial",
            n_payload_rows = length(vals))
        status_l[[length(status_l) + 1L]] <- tibble::tibble(
            task_id = tid, variable = var_name, channel = channel_name,
            source = source_name,
            status = if (measured) "complete" else "unavailable",
            hit = if (measured) TRUE else NA,
            processing_state = state_of(tid),
            error = NA_character_)
    }
    evidence <- result$evidence %>%
        transmute(task_id, variable = var_name, channel = channel_name,
                  source, source_row_id, evidence_ref)
    list(values = bind_rows(values_l), channel_status = bind_rows(status_l),
         evidence = evidence)
}

# Gated payload (combine expression + num/cat payload output): the gate decides
# the survivors (observed hit-set algebra at combine_at_level); the payload
# channel's values for those survivors reduce to the final value. At the default
# level the survivors are tasks; at a sub-output level they are qualifying keys,
# and the payload rows are scoped to them (§14.9: values_from is key-scoped even
# when the channel is not in the expression -- there is no raw escape). Gate-fail
# -> NA (cat reserves no "excluded" level; bin encodes exclusion as 0, cat
# cannot). An empty payload behind a passing gate (task admitted via the other
# side of an `|`) is NA without calling reduce. The full hit-algebra audit
# (channel_status, membership, overlap) is untouched: only the value column
# changes meaning, and n_payload_rows records the post-combine rows reduced.
.apply_gated_payload <- function(variable, out, channel_results) {
    output <- variable$output
    level <- variable$combine_at_level
    sub_level <- !is.null(level) &&
        !identical(level, variable$output_one_row_per)
    payload <- .output_payload(
        channel_results[[output$values_from]],
        .channel_type(output$values_from, variable),
        output,
        level = if (sub_level) level else NULL)
    if (sub_level) {
        qk <- out$combine_keys
        qk <- qk[qk$qualifies, , drop = FALSE]
        keep <- paste(payload$task_id, payload$key, sep = "\r") %in%
            paste(qk$task_id, qk[[level]], sep = "\r")
        payload <- payload[keep, , drop = FALSE]
    }
    gate <- out$values
    n <- nrow(gate)
    value <- switch(output$kind,
                    number = rep(NA_real_, n),
                    date = rep(as.Date(NA), n),
                    rep(NA_character_, n))
    n_payload <- integer(n)
    for (i in seq_len(n)) {
        if (!identical(gate$value[[i]], 1L)) next
        vals <- payload$value[payload$task_id == as.character(gate$task_id[[i]])]
        n_payload[[i]] <- length(vals)
        if (!length(vals)) next
        value[[i]] <- .reduce_payload(vals, output, variable$name)
    }
    gate$value <- value
    gate$n_payload_rows <- n_payload
    out$values <- gate
    out
}

# categorical output (combine = NULL): a single text channel whose extracted
# categorical value becomes the cohort value. Keeps the categorical STRING (not a
# binary hit):
#   valid        -> the status; channel_coverage complete
#   no_candidate -> NA, partial (nothing retrieved; open-world, not absence)
#   invalid      -> NA, needs_review (the response broke the declared output)
# Citation warnings report unsupplied IDs; only supplied IDs materialize as evidence.
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
        rationale <- if (nrow(vrow) && "task_summary" %in% names(vrow) &&
                         scalar_present(vrow$task_summary[[1]])) {
            as.character(vrow$task_summary[[1]])
        } else {
            NA_character_
        }
        outside_contract <- identical(state, "valid") &&
            (nrow(vrow) != 1L || is.na(status_val) ||
             !status_val %in% variable$output$levels)
        if (outside_contract) {
            state <- "processing_error"
            status_val <- NA_character_
            reason <- "categorical value does not match the declared levels"
        }
        needs_review <- state %in% c("invalid", "model_error", "processing_error")
        tibble::tibble(
            task_id = tid,
            value = if (identical(state, "valid")) status_val else NA_character_,
            rationale = if (identical(state, "valid")) rationale else NA_character_,
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
    if (!is.null(variable$output$rationale)) {
        values$rationale <- rows$rationale
        front <- c("task_id", "variable", "value", "rationale")
        values <- values[c(front, setdiff(names(values), front))]
    }
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

# Validate the parser/output field-set contract per task. A malformed task is
# converted to processing_error and removed from publishable values/evidence;
# valid siblings continue through the batch.
.enforce_struct_output_contract <- function(variable, tasks, result) {
    task_ids <- as.character(tasks$task_id)
    coverage <- result$coverage
    checked <- as.character(coverage$task_id)[
        as.character(coverage$task_id) %in% task_ids &
            coverage$processing_state %in% c("valid", "invalid")]
    if (!length(checked)) return(result)

    bad <- vapply(checked, function(task_id) {
        fields <- if (is.data.frame(result$values) &&
                      all(c("task_id", "field") %in% names(result$values))) {
            as.character(result$values$field[
                as.character(result$values$task_id) == task_id])
        } else character()
        !length(fields) || anyNA(fields) || any(!nzchar(fields)) ||
            anyDuplicated(fields) || !setequal(fields, variable$output$fields)
    }, logical(1))
    bad_tasks <- checked[bad]
    if (!length(bad_tasks)) return(result)

    failed <- as.character(result$coverage$task_id) %in% bad_tasks
    result$coverage$processing_state[failed] <- "processing_error"
    for (component in c("values", "evidence")) {
        frame <- result[[component]]
        if (is.data.frame(frame) && "task_id" %in% names(frame)) {
            result[[component]] <- frame[
                !as.character(frame$task_id) %in% bad_tasks, , drop = FALSE]
        }
    }
    if (is.data.frame(result$attempts) && "task_id" %in% names(result$attempts)) {
        failed_attempt <- as.character(result$attempts$task_id) %in% bad_tasks
        if ("processing_status" %in% names(result$attempts)) {
            result$attempts$processing_status[failed_attempt] <- "processing_error"
        }
        if ("task_validity" %in% names(result$attempts)) {
            result$attempts$task_validity[failed_attempt] <- "invalid"
        }
        if ("error" %in% names(result$attempts)) {
            reason <- "struct output fields do not match the declared field set"
            previous <- as.character(result$attempts$error[failed_attempt])
            result$attempts$error[failed_attempt] <- ifelse(
                is.na(previous) | !nzchar(previous), reason,
                paste(previous, reason, sep = " || "))
        }
    }
    result
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
            needs_review = status == "error" | processing_state == "invalid" |
                n_invalid > 0L) %>%
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
# and the membership audit, never silently in the final set operation. NA is
# preserved only in the per-channel audit (membership/overlap), not propagated into
# value. (A strict epistemic mode that propagates NA into value is a deliberate future
# extension, not the default.) The public surface is value + channel_coverage;
# included/excluded is a presentation recoding of value, not an engine field, and
# expression polarity is derived internally, never a public per-channel column.
#   values        per task: value (1/0), channel_coverage (complete/partial/failed).
#   channel_status per task x channel: status, hit (TRUE/FALSE/NA), processing_state,
#                 contribution, evidence_refs.
#   evidence      per hit ref.
#   membership    long-form for analysis: task_id, channel, hit (TRUE/FALSE/NA),
#                 processing_state, evidence_refs.
#   overlap       UpSet-style summary: one row per membership pattern (TRUE/FALSE/NA
#                 preserved) across the expression channels, with count, value,
#                 channel_coverage.
# One channel's observed hit keys at a sub-output level: the DISTINCT level keys
# on its hit evidence rows (a hit IS a row set; the rows carry the identity spine,
# so the level placement is read off the evidence, never re-derived). Restricted
# to tasks whose reduced hit is TRUE -- a grounded-but-negative text answer may
# cite evidence, and a non-hit must not contribute keys. Fail closed twice: a
# channel whose evidence lacks the key cannot enter the algebra, and a hit row
# without a key value cannot be placed at the level.
.channel_level_keys <- function(res, level, channel_name, hit_task_ids) {
    ev <- res$evidence
    if (is.null(ev) || !nrow(ev) || !length(hit_task_ids)) {
        return(tibble::tibble(task_id = character(), key = character()))
    }
    if (!level %in% names(ev)) {
        stop("combine_at_level = '", level, "': channel '", channel_name,
             "' evidence does not carry that key; level algebra needs ",
             "spine-keyed evidence (HDW sources and raw-document retrieval ",
             "carry it; pre-retrieved text fixtures must include it).",
             call. = FALSE)
    }
    ev <- ev[as.character(ev$task_id) %in% hit_task_ids, , drop = FALSE]
    keys <- as.character(ev[[level]])
    if (anyNA(keys) || any(!nzchar(keys))) {
        stop("combine_at_level = '", level, "': channel '", channel_name,
             "' has hit evidence without a ", level, " value; a hit that ",
             "cannot be placed at the level cannot enter the algebra.",
             call. = FALSE)
    }
    dplyr::distinct(tibble::tibble(task_id = as.character(ev$task_id),
                                   key = keys))
}

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
    task_ids <- as.character(tasks$task_id)

    reduced <- lapply(declared, function(ch) {
        is_text <- identical(.channel_type(ch, variable), "text")
        id_col <- if (is_text) "hit_ref" else "source_row_id"
        no_candidate <- .no_candidate_status(ch, variable)
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
    vectors  <- stats::setNames(lapply(referenced, hit_vec), referenced)
    observed <- stats::setNames(lapply(vectors, function(v) v %in% TRUE), referenced)

    level <- variable$combine_at_level
    sub_level <- !is.null(level) &&
        !identical(level, variable$output_one_row_per)
    combine_keys <- NULL
    if (sub_level) {
        # Sub-output-grain evaluation (DESIGN §7): the expression is checked per
        # observed level key, then exists-lifted -- a task scores 1 iff at least
        # one of its keys satisfies the expression. The key universe is the union
        # of keys observed by the referenced channels (the engine has no roster of
        # unobserved stays, so negation is complement within the observed keys;
        # the task-level membership/overlap audit above is unchanged).
        keysets <- stats::setNames(lapply(referenced, function(ch) {
            .channel_level_keys(channel_results[[ch]], level, ch,
                                task_ids[vectors[[ch]] %in% TRUE])
        }), referenced)
        universe <- dplyr::distinct(bind_rows(keysets))
        pair_of <- function(d) paste(d$task_id, d$key, sep = "\r")
        u_pairs <- pair_of(universe)
        observed_keys <- lapply(keysets, function(ks) u_pairs %in% pair_of(ks))
        key_result <- if (nrow(universe)) {
            .eval_hitset_expr(combine$ast, observed_keys)
        } else {
            logical(0)
        }
        combine_keys <- tibble::tibble(task_id = universe$task_id)
        combine_keys[[level]] <- universe$key
        for (ch in referenced) combine_keys[[ch]] <- observed_keys[[ch]]
        combine_keys$qualifies <- key_result
        result <- task_ids %in% universe$task_id[key_result]
    } else {
        result <- .eval_hitset_expr(combine$ast, observed)   # always TRUE/FALSE
    }

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
        value = as.integer(result), channel_coverage = channel_coverage)

    status_l <- list(); evidence_l <- list()
    for (ch in declared) {
        src <- .source_name_for_channel(ch, variable)
        for (tid in task_ids) {
            r <- reduced[[ch]][[tid]]
            refs <- if (isTRUE(r$hit) && nrow(r$evidence)) {
                as.character(r$evidence$source_row_id)
            } else character()
            status_l[[length(status_l) + 1L]] <- tibble::tibble(
                task_id = tid, variable = var_name, channel = ch, source = src,
                status = r$status, hit = r$hit,
                processing_state = .channel_raw_state(channel_results, ch, tid),
                contribution = .contribution_class(r$status, r$hit),
                evidence_refs = if (length(refs)) paste(refs, collapse = "; ")
                                else NA_character_,
                error = NA_character_)
            if (length(refs)) {
                evidence_l[[length(evidence_l) + 1L]] <- tibble::tibble(
                    task_id = tid, variable = var_name, channel = ch, source = src,
                    source_row_id = refs, evidence_ref = refs)
            }
        }
    }
    channel_status <- bind_rows(status_l)

    wide <- tibble::tibble(task_id = task_ids)
    for (ch in referenced) wide[[ch]] <- vectors[[ch]]
    overlap <- hit_set_overlap(wide, referenced, as.integer(result),
                               channel_coverage)

    out <- list(
        values = values,
        channel_status = channel_status,
        evidence = if (length(evidence_l)) bind_rows(evidence_l) else
            tibble::tibble(task_id = character(), variable = character(),
                           channel = character(), source = character(),
                           source_row_id = character(),
                           evidence_ref = character()),
        membership = channel_status %>%
            transmute(task_id, channel, hit, processing_state, evidence_refs),
        overlap = overlap)
    # Level audit (sub-output-grain gate only): one row per observed (task, key)
    # pair with the per-channel key hits and the expression verdict -- the "which
    # stay qualified (or failed)" view the exists-lifted 0/1 cannot show.
    if (!is.null(combine_keys)) out$combine_keys <- combine_keys
    out
}

# --- produced-dataset provenance (DESIGN §12, invariant 27) --------------------
# Provenance is part of the output contract: `run$provenance` is a serializable
# snapshot of the RESOLVED definition that actually executed (post concept-default /
# activation-override inheritance) plus the execution facts the engine knows (model,
# timestamp, resolved source-role mappings). It is assembled from
# resolve_variable_spec(), so the audit trail and the executor read the SAME
# resolution -- a trail recording the concept baseline while the executor ran a
# local override would be a silent audit lie no review of the values can catch.
# Per-attempt LLM provenance (provider/seed/prompt/schema/query hashes) already
# rides on channel_results[[channel]]$attempts and is not duplicated here.

# Snapshot a selector as a plain named list (kind + identity fields, NULLs dropped):
# a serializable record, not a live spec object.
.provenance_selector <- function(selector) {
    if (is.null(selector)) return(NULL)
    snap <- unclass(selector)
    attributes(snap) <- list(names = names(snap))
    snap <- snap[!vapply(snap, is.null, logical(1))]
    # A closure member (e.g. analyte_value(keep_when =)) is deparsed, like the
    # anchor's select_event and the channel's keep_group_when -- the audit trail
    # carries the rule as serializable text, not a live function object.
    fns <- vapply(snap, is.function, logical(1))
    snap[fns] <- lapply(snap[fns], function(f) paste(deparse(f), collapse = " "))
    snap
}

.provenance_anchor <- function(anchor) {
    if (is.null(anchor)) return(NULL)
    if (inherits(anchor, "ee_index_event")) {
        # The EXECUTED anchor column: the declared `at`, or the source's
        # windowing clock it defaults to.
        return(list(kind = "index_event", source = anchor$source,
                    selector = .provenance_selector(anchor$selector),
                    at = anchor$at %||%
                        (if (anchor$source %in% names(EE_SOURCES)) {
                            EE_SOURCES[[anchor$source]]$source_time_start
                        } else NULL),
                    # The executed multi-match rule, serializable (like reduce).
                    select_event = if (is.function(anchor$select_event)) {
                        paste(deparse(anchor$select_event), collapse = " ")
                    } else NULL))
    }
    list(kind = "task_column", column = as.character(anchor))
}

.build_provenance <- function(variable, chat) {
    metadata <- .chat_metadata(chat)
    channels <- lapply(variable$channels, function(ch) {
        spec <- if (ch$source %in% names(EE_SOURCES)) EE_SOURCES[[ch$source]]
                else NULL
        list(
            type = ch$type,
            source = ch$source,
            source_roles = if (is.null(spec)) NULL else source_roles(spec),
            runtime_roles = if (identical(ch$type, "text")) {
                list(text = "snippet_text", evidence_ref = "hit_ref")
            } else NULL,
            required_roles = ch$required_roles,
            evidence_scope = ch$evidence_scope,
            selector = .provenance_selector(ch$selector),
            selector_source = ch$selector_source,
            method = ch$method,
            prompt = ch$prompt,
            system_prompt = if (identical(ch$method, "lucene_llm")) {
                ch$system_prompt %||% DEFAULT_LLM_SYSTEM_PROMPT
            } else NULL,
            max_candidates = ch$max_candidates,
            # Aggregate membership predicate (§16.7): the executed group rule,
            # serializable -- level + deparsed closure, like the output's reduce.
            group_at_level = ch$group_at_level,
            keep_group_when = if (is.function(ch$keep_group_when)) {
                paste(deparse(ch$keep_group_when), collapse = " ")
            } else NULL)
    })
    window <- if (inherits(variable$window, "ee_window")) {
        list(from_days = variable$window$from_days,
             to_days = variable$window$to_days,
             relation = variable$window$relation)
    } else NULL
    output <- if (is.null(variable$output)) NULL else {
        out <- list(kind = variable$output$kind)
        if (!is.null(variable$output$levels)) out$levels <- variable$output$levels
        if (!is.null(variable$output$description)) {
            out$description <- variable$output$description
        }
        if (!is.null(variable$output$rationale)) {
            out$rationale <- variable$output$rationale
        }
        if (!is.null(variable$output$fields)) out$fields <- variable$output$fields
        # Payload spec (DESIGN §8): values_from as resolved at build; reduce as
        # deparsed source -- the executed rule, serializable.
        if (!is.null(variable$output$values_from)) {
            out$values_from <- variable$output$values_from
        }
        if (is.function(variable$output$reduce)) {
            out$reduce <- paste(deparse(variable$output$reduce), collapse = " ")
        }
        out
    }
    structure(
        list(
            variable = variable$name,
            concept = variable$concept,
            output_one_row_per = variable$output_one_row_per,
            anchor = .provenance_anchor(variable$anchor),
            window = window,
            combine = variable$combine_rule,
            # The EXECUTED evaluation level: the declared combine_at_level, or the
            # output grain it defaults to. NULL when there is no combine algebra.
            combine_at_level = if (inherits(variable$combine, "ee_combiner") &&
                                   identical(variable$combine$kind, "hit_set_expr")) {
                variable$combine_at_level %||% variable$output_one_row_per
            } else NULL,
            output = output,
            channels = channels,
            provider = metadata$provider,
            model = metadata$model,
            model_params = metadata$params,
            executed_at = Sys.time()),
        class = c("ee_provenance", "list"))
}

# The COHORT is the variable's row universe: the validated unit list the engine
# answers about, one output row per grain-key combination. It is DECLARED, never
# inferred from whoever happens to have data rows (a subject with no rows keeps
# an NA/partial row; `!x` complements within it). The 99% path (owner, 2026-07-05):
# the engine runs DOWNSTREAM of a human-validated cohort -- candidates are
# screened and validated one by one BEFORE the engine, so the validated list is
# laid down WITH the data as sources$cohort and every variable derives its
# universe from it. An explicit frame remains the override (a narrowed
# sub-cohort, e.g. an inclusion variable's 1-rows; a researcher-supplied stay
# roster). task_id is derived from the grain keys when absent.
.resolve_cohort <- function(variable, cohort, sources) {
    if (is.null(cohort)) cohort <- sources$cohort
    if (is.null(cohort)) {
        stop("No cohort: lay the validated cohort down with the data ",
             "(sources$cohort) or pass a cohort frame explicitly -- the row ",
             "universe is declared, never inferred from data rows.",
             call. = FALSE)
    }
    # A bare vector of PATIDs (a list of ids, a spreadsheet column) is a
    # perfectly good patient-grain cohort.
    if (is.character(cohort)) {
        cohort <- tibble::tibble(PATID = as.character(cohort))
    }
    if (!is.data.frame(cohort) || !nrow(cohort)) {
        stop("cohort must be a non-empty data frame (one row per output unit) ",
             "or a character vector of PATIDs.", call. = FALSE)
    }
    # A cohort may be laid down at stay grain (PATID + EVTID) and reused by
    # variables with different output grains. The variable owns that choice:
    # project to its declared grain before deriving the public row identifier.
    # A caller-supplied anchor column remains part of the row declaration; if it
    # supplies several anchor values for one output unit, the grain guard below
    # rejects the ambiguity instead of silently choosing one.
    explicit_id <- "task_id" %in% names(cohort)
    if (!explicit_id) {
        grain <- variable$output_one_row_per %||% "PATID"
        grain_keys <- unique(c("PATID", grain))
        missing_keys <- setdiff(grain_keys, names(cohort))
        if (length(missing_keys)) {
            stop("output_one_row_per = '", grain,
                 "' needs cohort column(s): ",
                 paste(missing_keys, collapse = ", "), ".", call. = FALSE)
        }
        anchor_column <- if (is.character(variable$anchor)) variable$anchor else NULL
        keep <- unique(c(grain_keys, anchor_column))
        keep <- intersect(keep, names(cohort))
        cohort <- dplyr::distinct(tibble::as_tibble(cohort)[keep])
    }
    # task_id is internal execution plumbing derived from the declared grain
    # keys. Public result views publish those native keys, never this composite.
    if (!"task_id" %in% names(cohort)) {
        keys <- intersect(
            unique(c("PATID", variable$output_one_row_per %||% "PATID")),
            names(cohort))
        if (!length(keys)) {
            stop("cohort carries no grain key column(s); ",
                 "cannot identify its rows.", call. = FALSE)
        }
        cohort$task_id <- do.call(
            paste, c(lapply(cohort[keys], as.character), sep = "::"))
    }
    cohort
}

# Publish the native grain keys on every row-keyed output view. task_id remains
# only in raw channel_results, where it identifies one internal extraction task.
.publish_grain_keys <- function(run, tasks, grain_keys) {
    key_map <- dplyr::distinct(
        tibble::as_tibble(tasks)[c("task_id", grain_keys)])
    if (anyDuplicated(as.character(key_map$task_id))) {
        stop("Internal task_id does not map uniquely to the output grain.",
             call. = FALSE)
    }
    lapply(run, function(el) {
        if (is.data.frame(el) && "task_id" %in% names(el)) {
            index <- match(as.character(el$task_id),
                           as.character(key_map$task_id))
            if (anyNA(index)) {
                stop("A published result row does not resolve to its grain keys.",
                     call. = FALSE)
            }
            keys <- key_map[index, grain_keys, drop = FALSE]
            payload <- el[setdiff(names(el), c("task_id", grain_keys))]
            return(dplyr::bind_cols(keys, payload))
        }
        el
    })
}

# EXPLICIT union-of-sources universe: "whoever appears in these frames", as a
# conscious one-liner for exploration -- never a silent default (owner-settled
# 2026-07-05): a validated patient with no data rows in any loaded source would
# silently vanish from the denominator, and that patient must be NA everywhere,
# not absent.
cohort_from_sources <- function(sources) {
    ids <- unlist(lapply(sources, function(src) {
        if (is.data.frame(src) && "PATID" %in% names(src)) {
            return(as.character(src$PATID))
        }
        if (.is_tcorpus(src)) {
            index <- .document_index_from_corpus(src)
            return(as.character(index$PATID))
        }
        if (is.list(src) && is.data.frame(src$docs_index) &&
            "PATID" %in% names(src$docs_index)) {
            return(as.character(src$docs_index$PATID))
        }
        character()
    }), use.names = FALSE)
    ids <- sort(unique(ids[!is.na(ids) & nzchar(ids)]))
    if (!length(ids)) {
        stop("cohort_from_sources(): no PATID column found in sources.",
             call. = FALSE)
    }
    tibble::tibble(PATID = ids)
}

run_variable <- function(variable, cohort = NULL, sources = NULL, chat = NULL) {
    if (!inherits(variable, "ee_variable_spec")) {
        stop("run_variable() requires a variable_spec().", call. = FALSE)
    }
    variable <- resolve_variable_spec(variable)
    if (!length(variable$channels)) {
        stop("variable_spec has no selected channels.", call. = FALSE)
    }
    tasks <- .resolve_cohort(variable, cohort, sources)
    sources <- .prepare_execution_sources(sources, tasks)
    # Anchor first: a select_event closure may EMIT tasks (one per selected
    # event), and the grain guard must see the emitted universe, not the
    # pre-anchor one -- select_event = identity with output_one_row_per =
    # "PATID" must fail loudly (DESIGN §7).
    tasks <- .resolve_anchor(variable, tasks, sources)
    grain_keys <- .check_output_grain(variable, tasks)
    # Resolve transport ONCE per variable. run_protocol() iterates variables in
    # list order, and all of this variable's task rows are processed before the
    # next model can be selected. Per-task Chat clones isolate conversation state;
    # they keep the same provider/model and do not reconfigure Ollama.
    chat <- .resolve_variable_chat(variable, chat)
    # Scoping rule (DESIGN §7): an explicit event evidence scope constrains rows
    # to PATID + EVTID. Otherwise a declared window gathers per subject inside
    # each task's anchored window; with no window, the output grain is the scope.
    channel_results <- lapply(names(variable$channels), function(channel_name) {
        scope_keys <- .channel_scope_keys(
            .channel_def(variable, channel_name), variable, tasks, grain_keys)
        .run_selected_channel(
            variable, channel_name, tasks, sources, chat,
            grain_keys = scope_keys)
    })
    names(channel_results) <- names(variable$channels)

    channel_names <- names(variable$channels)
    selected_sources <- unname(vapply(channel_names, .source_name_for_channel,
                                      character(1), variable = variable))
    selected_produces <- vapply(channel_names, function(nm) {
        .channel_def(variable, nm)$produces
    }, character(1))
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
        # The expression gates rows; with a payload output (num/cat + values_from/
        # reduce, spec-validated) the surviving tasks' payload values become the
        # final value instead of the 0/1 membership lift.
        out <- .hit_set_expr_variable(variable, tasks, channel_results)
        if (!is.null(variable$output) &&
            variable$output$kind %in% c("number", "categorical", "date") &&
            is.function(variable$output$reduce)) {
            out <- .apply_gated_payload(variable, out, channel_results)
        }
    } else if (is.null(combine)) {
        # Single channel (constructor-guaranteed): assemble on the output() shape.
        ch <- names(channel_results)[[1]]
        ch_type <- .channel_type(ch, variable)
        output_kind <- if (is.null(variable$output)) NA_character_ else variable$output$kind
        out <- switch(output_kind,
            binary = .single_membership_variable(
                variable, tasks, ch, channel_results[[1]]),
            number = .single_payload_variable(
                variable, tasks, ch, channel_results[[1]]),
            date = .single_payload_variable(
                variable, tasks, ch, channel_results[[1]]),
            categorical = {
                if (is.function(variable$output$reduce)) {
                    # Payload flavor: the level is computed from the channel's own
                    # rows' values (e.g. a code-family rule).
                    .single_payload_variable(variable, tasks, ch,
                                             channel_results[[1]])
                } else {
                    if (!identical(ch_type, "text")) {
                        stop("categorical output without a payload spec requires ",
                             "a text channel (documented status); over a ",
                             "structured channel declare cat_output(levels, ",
                             "values_from =, reduce =).", call. = FALSE)
                    }
                    .documented_status_variable(variable, tasks, ch,
                                                channel_results[[1]])
                }
            },
            fields = {
                if (!identical(ch_type, "text")) {
                    stop("fields output currently requires a text channel.",
                         call. = FALSE)
                }
                channel_results[[1]] <- .enforce_struct_output_contract(
                    variable, tasks, channel_results[[1]])
                .multi_field_variable(variable, tasks, ch, channel_results[[1]])
            },
            stop("Unsupported single-channel output: ", output_kind,
                 " (expected binary/number/categorical/date/fields).",
                 call. = FALSE))
    } else {
        stop("Unsupported combine; expected a hit-set expression (>=2 channels) ",
             "or NULL (single channel).", call. = FALSE)
    }
    # combine_rule = the raw hit-set expression ("a | b", "a & !b") -- the same string
    # whether written directly or lowered from any_positive(); NA for a single-channel
    # variable, which has no cross-channel combine (its value comes from output()).
    combine_rule <- if (inherits(combine, "ee_combiner")) combine$expr else NA_character_
    .publish_grain_keys(
        c(list(spec = variable, selected_channels = selected,
                combine_rule = combine_rule,
               provenance = .build_provenance(variable, chat),
               channel_results = channel_results), out),
        tasks = tasks,
        grain_keys = grain_keys)
}

# The protocol run: every variable of a study over ONE declared cohort laid
# down with the data (sources$cohort), so all outputs share the denominator by
# construction. Variables execute sequentially in list order: each run resolves
# its own model once, then processes all of that variable's rows before the next
# variable. Today a thin orchestrator; study-level duties (shared channel
# caching, one combined output table, study provenance bundle) wait for their
# consumers.
run_protocol <- function(variables, cohort = NULL, sources = NULL,
                          chat = NULL) {
    .require_named_list(variables, "variables")
    lapply(variables, run_variable, cohort = cohort, sources = sources,
           chat = chat)
}
