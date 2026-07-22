# =============================================================================
# run_variable.R -- experimental execution spine + audit envelope
# -----------------------------------------------------------------------------
# Executes one variable_spec over supplied input rows and a named list of source
# data, then returns three ordinary relational views (values, channel_status,
# evidence) plus a nested audit bundle containing staged counts, LLM calls, an
# execution manifest, combine diagnostics, and internal channel intermediates.
#
# Channel execution dispatches on the channel TYPE (code / text / lab), NOT on the
# channel name -- the runner must stay free of any one concept's vocabulary. The
# existing measure_*() / run_extraction() functions are reused as TEMPORARY
# adapters (they are generic over their parameters); they are not the public
# architecture.
#
# VALUE assembly dispatches on combine vs output (design note §8): the combine
# gates ROWS, the output decides what those rows become.
#   - combine present -> set algebra over observed hit sets; bin_output() publishes
#     membership, while from_channel() publishes one explicitly named payload;
#   - combine = NULL -> a single channel publishes membership or its payload.
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

.window_days <- function(window) {
    if (is.null(window) || !inherits(window, "ee_window")) {
        stop("This experimental runner requires a relative window.", call. = FALSE)
    }
    c(from_days = window$from_days, to_days = window$to_days)
}

.has_activation_window <- function(variable) {
    any(vapply(variable$channels, function(channel) {
        inherits(channel$window, "ee_window")
    }, logical(1)))
}

.identity_spine <- c("PATID", "EVTID", "ELTID")

.audit_stage <- function(task_ids, channel, stage, unit, n) {
    if (length(n) != length(task_ids)) {
        stop("Internal audit count does not align with the task universe.",
             call. = FALSE)
    }
    tibble::tibble(
        task_id = as.character(task_ids),
        channel = channel,
        stage = stage,
        unit = unit,
        n = as.integer(n))
}

.count_task_rows <- function(rows, task_ids, keep = NULL) {
    if (!is.data.frame(rows) || !nrow(rows) || !"task_id" %in% names(rows)) {
        return(integer(length(task_ids)))
    }
    if (!is.null(keep)) rows <- rows[keep %in% TRUE, , drop = FALSE]
    index <- match(as.character(rows$task_id), as.character(task_ids))
    tabulate(index[!is.na(index)], nbins = length(task_ids))
}

.spine_keys_through <- function(level) {
    index <- match(level, .identity_spine)
    if (is.na(index)) {
        stop("Unknown identity-spine key: ", level, ".", call. = FALSE)
    }
    .identity_spine[seq_len(index)]
}

.output_grain_keys <- function(level) {
    if (level %in% .identity_spine) .spine_keys_through(level)
    else unique(c("PATID", level))
}

.selector_codes <- function(selector, field) {
    if (!inherits(selector, "ee_selector")) {
        stop("Channel selector is not an experimental selector.", call. = FALSE)
    }
    selector[[field]]
}

.validate_pre_retrieved_text <- function(coverage, candidates, tasks,
                                         required_roles, search_within) {
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
    coverage_ids <- as.character(coverage$task_id)
    task_ids <- as.character(tasks$task_id)
    if (anyNA(coverage_ids) || any(!nzchar(coverage_ids)) ||
        anyDuplicated(coverage_ids) ||
        length(coverage_ids) != length(task_ids) ||
        !setequal(coverage_ids, task_ids)) {
        stop("Pre-retrieved text coverage must contain exactly one row for ",
             "every task.", call. = FALSE)
    }
    coverage_state <- as.character(coverage$coverage_state)
    allowed_states <- c("candidate", "no_candidate", "no_eligible_document")
    if (anyNA(coverage_state) || any(!coverage_state %in% allowed_states)) {
        stop("Pre-retrieved text coverage_state must use only: ",
             paste(allowed_states, collapse = ", "), ".", call. = FALSE)
    }
    scope_columns <- if (identical(search_within, "EVTID")) {
        c("PATID", "EVTID")
    } else {
        "PATID"
    }
    missing_scope <- setdiff(scope_columns, names(tasks))
    invalid_scope <- length(missing_scope) || any(vapply(
        scope_columns,
        function(column) {
            value <- tasks[[column]]
            anyNA(value) || any(!nzchar(as.character(value)))
        },
        logical(1)
    ))
    if (invalid_scope) {
        stop("Pre-retrieved text search_within = '", search_within,
             "' requires task key(s): ", paste(scope_columns, collapse = ", "),
             ".", call. = FALSE)
    }
    candidate_tasks <- unique(coverage_ids[coverage_state == "candidate"])
    candidate_row_tasks <- unique(as.character(candidates$task_id))
    if (!setequal(candidate_tasks, candidate_row_tasks)) {
        stop("Pre-retrieved text coverage_state must be 'candidate' if and only ",
             "if candidate rows exist for that task.", call. = FALSE)
    }
    if (!length(candidate_tasks)) return(invisible(TRUE))

    role_columns <- c(
        event_id = "EVTID", point_date = "RECDATE", text = "snippet_text",
        source_item_id = "ELTID", document_type = "RECTYPE")
    required_columns <- unique(c(
        "task_id", "snippet_id", "hit_ref", scope_columns,
        unname(role_columns[intersect(required_roles, names(role_columns))])))
    missing <- setdiff(required_columns, names(candidates))
    if (length(missing)) {
        stop("Pre-retrieved text candidates are missing required column(s): ",
             paste(missing, collapse = ", "), ".", call. = FALSE)
    }
    relevant <- candidates
    for (column in setdiff(required_columns, "task_id")) {
        value <- relevant[[column]]
        if (anyNA(value) || any(!nzchar(as.character(value)))) {
            stop("Pre-retrieved text candidate column '", column,
                 "' contains missing values.", call. = FALSE)
        }
    }
    task_index <- match(as.character(relevant$task_id), as.character(tasks$task_id))
    for (column in scope_columns) {
        target <- tasks[[column]][task_index]
        if (anyNA(target) ||
            any(as.character(relevant[[column]]) != as.character(target))) {
            stop("Pre-retrieved text candidates do not match their task for ",
                 "search_within = '", search_within, "'.", call. = FALSE)
        }
    }
    if ("point_date" %in% required_roles &&
        !inherits(relevant$RECDATE, c("Date", "POSIXt"))) {
        stop("Pre-retrieved text point_date must be Date or POSIXt.",
             call. = FALSE)
    }
    invisible(TRUE)
}

.apply_pre_retrieved_text_window <- function(coverage, candidates, tasks,
                                              window) {
    if (is.null(window)) {
        return(list(coverage = coverage, candidates = candidates))
    }
    if (!"anchor_date" %in% names(tasks) || anyNA(tasks$anchor_date)) {
        stop("A windowed pre-retrieved text activation requires task anchor_date.",
             call. = FALSE)
    }
    if (!"RECDATE" %in% names(candidates)) {
        stop("Windowed pre-retrieved text candidates must contain RECDATE.",
             call. = FALSE)
    }
    if (nrow(candidates)) {
        candidate_dates <- .clinical_date(candidates$RECDATE)
        if (anyNA(candidate_dates)) {
            stop("Windowed pre-retrieved text candidates contain missing RECDATE.",
                 call. = FALSE)
        }
        task_index <- match(as.character(candidates$task_id),
                            as.character(tasks$task_id))
        anchor_dates <- .clinical_date(tasks$anchor_date[task_index])
        w <- .window_days(window)
        keep <- candidate_dates >= anchor_dates + w[["from_days"]] &
            candidate_dates <= anchor_dates + w[["to_days"]]
        candidates <- candidates[keep, , drop = FALSE]
    }
    remaining <- unique(as.character(candidates$task_id))
    coverage$coverage_state <- as.character(coverage$coverage_state)
    demote <- coverage$coverage_state == "candidate" &
        !as.character(coverage$task_id) %in% remaining
    coverage$coverage_state[demote] <- "no_candidate"
    list(coverage = coverage, candidates = candidates)
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
            coverage, candidates, tasks, channel_def$required_roles,
            channel_def$search_within)
        return(.apply_pre_retrieved_text_window(
            coverage, candidates, tasks, channel_def$window))
    }
    raw <- .raw_document_source(src)
    if (!is.null(raw)) {
        return(.retrieve_text_channel(channel_def, variable, tasks, raw, selector))
    }
    stop("A documents source must be a metadata-rich tCorpus or pre-retrieved ",
         "{coverage, candidates}.", call. = FALSE)
}

# Real retrieval from a tCorpus and its private metadata view. The declared search
# boundary is resolved first; an authored temporal window is then intersected with
# that eligible set. With no window, patient search sees the whole record and event
# search sees the whole event.
# Then the existing retrieve() runs the channel's Lucene query and assembles
# candidates + coverage. Eligibility keeps the document's EVTID when metadata
# carries it, so a text hit stays attributable to its stay for combine$by.
.text_eligibility_cols <- function(d) {
    select(d, any_of(c("task_id", "ELTID", "EVTID", "RECDATE", "RECTYPE",
                       "anchor_date")))
}

.retrieve_text_channel <- function(channel_def, variable, tasks, src, selector) {
    event_scoped <- identical(channel_def$search_within, "EVTID")
    if (event_scoped) {
        if (!all(c("PATID", "EVTID") %in% names(tasks))) {
            stop("Event-scoped text retrieval requires tasks with PATID + EVTID.",
                 call. = FALSE)
        }
    }
    join_keys <- if (event_scoped) c("PATID", "EVTID") else "PATID"
    task_columns <- c("task_id", join_keys,
                      if (!is.null(channel_def$window)) "anchor_date")
    keys <- tasks %>% select(all_of(task_columns)) %>% distinct()
    eligibility <- src$docs_index %>%
        inner_join(keys, by = join_keys, relationship = "many-to-many")
    if (!is.null(channel_def$window)) {
        if (!inherits(channel_def$window, "ee_window")) {
            stop("Real retrieval requires a compiled relative window.",
                 call. = FALSE)
        }
        w <- .window_days(channel_def$window)
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

.filter_text_candidates <- function(text_inputs, filter_rows, group_by,
                                    filter_groups, channel_name) {
    task_ids <- as.character(text_inputs$coverage$task_id)
    candidates <- text_inputs$candidates
    counts <- list(.audit_stage(
        task_ids, channel_name, "selector", "snippet",
        .count_task_rows(candidates, task_ids)))
    if (is.function(filter_rows)) {
        if (nrow(candidates)) {
            keep <- logical(nrow(candidates))
            groups <- split(seq_len(nrow(candidates)),
                            as.character(candidates$task_id))
            for (indices in groups) {
                keep[indices] <- .eval_row_predicate(
                    candidates[indices, , drop = FALSE],
                    filter_rows, channel_name)
            }
            candidates <- candidates[keep, , drop = FALSE]
        }
        counts[[length(counts) + 1L]] <- .audit_stage(
            task_ids, channel_name, "filter_rows", "snippet",
            .count_task_rows(candidates, task_ids))
    }
    if (is.function(filter_groups)) {
        if (nrow(candidates)) {
            candidates$is_target <- TRUE
            candidates <- .apply_group_predicate(
                candidates, group_by, filter_groups, channel_name)
            candidates <- candidates[candidates$is_target, , drop = FALSE]
            candidates$is_target <- NULL
            candidates$group_demoted <- NULL
        }
        counts[[length(counts) + 1L]] <- .audit_stage(
            task_ids, channel_name, "filter_groups", "snippet",
            .count_task_rows(candidates, task_ids))
    }
    text_inputs$candidates <- candidates
    text_inputs$audit_counts <- dplyr::bind_rows(counts)
    surviving_tasks <- unique(as.character(text_inputs$candidates$task_id))
    if ("n_snippets" %in% names(text_inputs$coverage)) {
        counts <- table(as.character(text_inputs$candidates$task_id))
        text_inputs$coverage$n_snippets <- as.integer(
            counts[as.character(text_inputs$coverage$task_id)])
        text_inputs$coverage$n_snippets[is.na(text_inputs$coverage$n_snippets)] <- 0L
    }
    demoted <- text_inputs$coverage$coverage_state == "candidate" &
        !as.character(text_inputs$coverage$task_id) %in% surviving_tasks
    text_inputs$coverage$coverage_state[demoted] <- "no_candidate"
    text_inputs
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
    required <- c("source_result_id", "point_date", "analyte")
    missing <- setdiff(required, names(roles))
    if (length(missing)) {
        stop("Prepared source '", source, "' lacks lab role(s): ",
             paste(missing, collapse = ", "), ".", call. = FALSE)
    }
    list(
        result_id_col = roles$source_result_id,
        date_col = roles$point_date,
        analyte_col = roles$analyte)
}

# A lab selector chooses analyte rows only. The output later names the physical
# prepared-source column (NUMRES, STRRES, DATEXAM, ...), so row selection never
# infers or validates a result lane.
# Grain guard: the OUTPUT GRAIN (variable$output$group_by) is carried by the task
# universe -- one task row per grain unit. This checks the tasks frame actually is at
# the declared grain and returns the identity keys the structured executors scope by:
# unique(c("PATID", group_by)) -- "PATID" alone at patient grain, c("PATID",
# "EVTID") at stay grain. DESIGN §7: the variable_spec decides the unit; the engine
# checks the tasks can be mechanically linked to it.
.check_output_grain <- function(variable, tasks) {
    grain <- variable$output$group_by
    grain_keys <- .output_grain_keys(grain)
    missing_cols <- setdiff(grain_keys, names(tasks))
    if (length(missing_cols)) {
        stop("output group_by = '", grain, "' needs task column(s): ",
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
        stop("output group_by = '", grain, "' requires one task per ", grain,
             ", but the tasks frame repeats a ", paste(grain_keys, collapse = "+"),
              " combination.", call. = FALSE)
    }
    task_ids <- as.character(tasks$task_id)
    if (anyNA(task_ids) || any(!nzchar(task_ids)) || anyDuplicated(task_ids)) {
        stop("Internal task_id must be non-missing, non-empty, and unique ",
             "before channel execution.", call. = FALSE)
    }
    grain_keys
}

# Derived-anchor PASS: when variable$anchor is an index_event(), compute a per-subject
# anchor_date BEFORE windowing -- find each subject's event matching the selector in the
# named source and take its date at role `at`. This is a resolution pass producing
# (PATID, anchor_date), NOT an inter-channel dependency. A string anchor names the
# caller-supplied cohort column that is normalized to the internal anchor_date clock.
.resolve_anchor <- function(variable, tasks, sources) {
    # A derived index event is also an identity operation: it may supply the
    # target EVTID used by search_within even when no activation has a window.
    # A plain date-column anchor, by contrast, is only consumed by windows.
    if (!.has_activation_window(variable) &&
        !inherits(variable$anchor, "ee_index_event")) return(tasks)
    anchor <- variable$anchor
    if (is.null(anchor)) {
        stop("An activation window cannot execute without a declared anchor.",
             call. = FALSE)
    }
    if (is.character(anchor)) {
        if (!anchor %in% names(tasks)) {
            stop("The declared anchor cohort column is missing: '", anchor, "'.",
                 call. = FALSE)
        }
        tasks$anchor_date <- .clinical_date(tasks[[anchor]])
        if (anyNA(tasks$anchor_date)) {
            stop("The declared anchor cohort column contains missing values.",
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
        filter(.code_matches(code_val, sel$codes, sel$match)) %>%
        distinct(PATID, EVTID, anchor_date)

    # Multi-match: the researcher's select_event closure picks which event(s)
    # anchor the clock (DESIGN §7, invariant 35); without it the engine never
    # picks -- loud error. The closure sees the subject's matched rows with the
    # date under the source's own COLUMN name (the resolved `at`), exactly as
    # written in the spec: select_event = \(d) dplyr::slice_min(d, DATEACTE, n = 1).
    # It is a selector, not a transformer: every returned EVTID/date tuple must
    # already exist in this patient's matched relation.
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
                available <- dplyr::bind_cols(key, d)
                out <- select_event(available)
                if (!is.data.frame(out) ||
                    !all(c("EVTID", date_col) %in% names(out))) {
                    stop("select_event must return matched event row(s) ",
                         "keeping the EVTID and ", date_col, " columns.",
                         call. = FALSE)
                }
                available_keys <- tibble::tibble(
                    EVTID = as.character(available$EVTID),
                    anchor_date = .clinical_date(available[[date_col]]))
                selected_keys <- tibble::tibble(
                    EVTID = as.character(out$EVTID),
                    anchor_date = .clinical_date(out[[date_col]]))
                if (nrow(dplyr::anti_join(
                    selected_keys, available_keys,
                    by = c("EVTID", "anchor_date")))) {
                    stop("select_event must return only rows from the matched ",
                         "event set; it cannot alter EVTID or ", date_col, ".",
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
    anchors <- matched %>%
        distinct(PATID, EVTID, anchor_date) %>%
        rename(anchor_EVTID = EVTID)

    # An index event generates EVTID tasks only when the declared event-grain
    # cohort supplied PATID alone. If the cohort already carries target EVTIDs,
    # preserve them and keep the selected event separately as anchor_EVTID.
    generates_events <- identical(variable$output$group_by, "EVTID") &&
        !"EVTID" %in% names(tasks)
    multi <- anchors %>% count(PATID) %>% filter(n > 1L)
    if (nrow(multi) && !generates_events) {
        stop("select_event kept several events for ", nrow(multi),
             " subject(s), but existing output tasks need one shared anchor per ",
             "patient; select one event or let index_event() generate EVTID tasks ",
             "from a PATID cohort.", call. = FALSE)
    }
    tasks$anchor_date <- NULL
    tasks$anchor_EVTID <- NULL
    tasks <- tasks %>%
        left_join(anchors, by = "PATID",
                  relationship = if (generates_events) "many-to-many" else
                      "many-to-one")
    unresolved <- unique(tasks$PATID[is.na(tasks$anchor_date)])
    if (length(unresolved)) {
        stop("index_event found no matching event for ", length(unresolved),
             " subject(s) -- every unit needs its index event.",
             call. = FALSE)
    }
    if (generates_events) {
        tasks$EVTID <- tasks$anchor_EVTID
        tasks$task_id <- paste(tasks$task_id, tasks$EVTID, sep = "::")
    } else if (!"EVTID" %in% names(tasks)) {
        # Patient-grain tasks may still need the selected event as the search
        # relation for search_within = "EVTID". It is context, not output grain.
        tasks$EVTID <- tasks$anchor_EVTID
    }
    tasks
}

.channel_scope_keys <- function(channel_def, variable, tasks, grain_keys) {
    if (identical(channel_def$search_within, "EVTID")) {
        required <- c("PATID", "EVTID")
        missing <- setdiff(required, names(tasks))
        if (length(missing)) {
            stop("Channel '", channel_def$name,
                 "' declares search_within = 'EVTID' but its task lacks ",
                 "column(s): ", paste(missing, collapse = ", "), ".",
                 call. = FALSE)
        }
        if (anyNA(tasks$EVTID) || any(!nzchar(as.character(tasks$EVTID)))) {
            stop("search_within = 'EVTID' requires non-missing task EVTID ",
                 "values.",
                 call. = FALSE)
        }
        return(required)
    }
    if (identical(channel_def$search_within, "PATID")) return("PATID")
    if (is.null(channel_def$window)) grain_keys else "PATID"
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
    switch(channel_def$type,
        code = ,
        act = {
            # code (CIM-10 over pmsi$diag) and act (CCAM over pmsi$actes) share the
            # neutral membership executor; only the source binding differs.
            sel <- selector
            bind <- .code_source_binding(source)
            w <- if (is.null(channel_def$window)) {
                list(from_days = NULL, to_days = NULL)
            } else .window_days(channel_def$window)
            measure_code_presence(
                sources[[source]], tasks, codes = sel$codes, match = sel$match,
                filter_rows = channel_def$filter_rows,
                grain_keys = grain_keys,
                from_days = w[["from_days"]], to_days = w[["to_days"]],
                group_by = channel_def$group_by,
                filter_groups = channel_def$filter_groups,
                code_col = bind$code_col, start_col = bind$start_col,
                end_col = bind$end_col, field = channel_name, source = source)
        },
        lab = {
            # Neutral analyte executor: the concept selector identifies rows;
            # activation predicates filter those rows, and from_channel() later
            # chooses an explicit prepared-source column.
            w <- if (is.null(channel_def$window)) {
                list(from_days = NULL, to_days = NULL)
            } else .window_days(channel_def$window)
            bind <- .lab_source_binding(source)
            measure_analyte_values(
                sources[[source]], tasks,
                analytes = .selector_codes(selector, "codes"),
                filter_rows = channel_def$filter_rows, grain_keys = grain_keys,
                from_days = w[["from_days"]], to_days = w[["to_days"]],
                group_by = channel_def$group_by,
                filter_groups = channel_def$filter_groups,
                result_id_col = bind$result_id_col,
                date_col = bind$date_col,
                analyte_col = bind$analyte_col,
                field = channel_name, source = source)
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
            w <- if (is.null(channel_def$window)) {
                list(from_days = NULL, to_days = NULL)
            } else .window_days(channel_def$window)
            measure_doc_presence(
                docs_index, tasks, filters = selector$filters,
                filter_rows = channel_def$filter_rows,
                grain_keys = grain_keys,
                from_days = w[["from_days"]], to_days = w[["to_days"]],
                group_by = channel_def$group_by,
                filter_groups = channel_def$filter_groups,
                date_col = spec$source_time_start,
                field = channel_name, source = source)
        },
        text = {
            method <- channel_def$method
            text_inputs <- .resolve_text_inputs(sources[[source]], channel_def,
                                                 variable, tasks, selector)
            text_inputs <- .filter_text_candidates(
                text_inputs, channel_def$filter_rows,
                channel_def$group_by, channel_def$filter_groups,
                channel_name)
            if (identical(method, "lucene")) {
                result <- .run_lucene_presence(text_inputs)
            } else if (identical(method, "lucene_llm")) {
                if (is.null(chat)) {
                    stop("Text channel '", channel_name,
                         "' with method = 'lucene_llm' requires an ellmer Chat.",
                         call. = FALSE)
                }
                definition <- .compile_llm_channel(channel_def, variable)
                result <- run_extraction(
                    text_inputs$coverage, text_inputs$candidates,
                    definition, chat,
                    .candidate_selector(channel_def$max_candidates),
                    query = selector$query)
            } else {
                stop("Unsupported text method for channel '", channel_name,
                          "': ", method, ".", call. = FALSE)
            }
            result$audit_counts <- text_inputs$audit_counts
            result
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

    values_l <- list(); status_l <- list()
    for (tid in task_ids) {
        r <- reduced[[tid]]
        observed <- isTRUE(r$hit)               # NA / FALSE -> non-member (0)
        coverage <- switch(r$status,
            complete = "complete",
            error    = "failed",
            "partial")                          # unavailable / invalid
        # A retained qualitative qualifier may document a negative membership;
        # evidence is therefore not restricted to positive hits.
        values_l[[length(values_l) + 1L]] <- tibble::tibble(
            task_id = tid, variable = var_name,
            value = as.integer(observed), channel_coverage = coverage)
        status_l[[length(status_l) + 1L]] <- tibble::tibble(
            task_id = tid, variable = var_name, channel = channel_name,
            source = source_name, status = r$status, hit = r$hit,
            processing_state = raw_state(tid),
            contribution = .contribution_class(r$status, r$hit),
            error = NA_character_)
    }
    list(
        values = bind_rows(values_l),
        channel_status = bind_rows(status_l),
        evidence = .public_evidence(
            result, var_name, channel_name, source_name, task_ids))
}

# --- from_channel() assembly ---------------------------------------------------
# Deterministic activations expose selected prepared-source rows. The output names
# the physical column it reads; no hidden `value` alias or result-lane inference is
# allowed. LLM activations instead expose their authored TypeObject fields as one
# wide row per task.
.candidate_rows <- function(result, channel_name) {
    rows <- result$candidates
    if (!is.data.frame(rows)) {
        rows <- result$evidence
    }
    if (!is.data.frame(rows) || !"task_id" %in% names(rows)) {
        stop("Channel '", channel_name,
             "' did not expose task-keyed candidate rows for from_channel().",
             call. = FALSE)
    }
    rows
}

.value_is_present <- function(x) {
    if (is.list(x) && !inherits(x, "POSIXlt")) {
        return(!vapply(x, function(value) {
            is.null(value) || !length(value) || all(is.na(value))
        }, logical(1)))
    }
    !is.na(x)
}

.typed_na <- function(prototype) {
    if (is.list(prototype) && !inherits(prototype, "POSIXlt")) return(list(NULL))
    prototype[NA_integer_]
}

.typed_na_frame <- function(prototype) {
    columns <- lapply(prototype, .typed_na)
    tibble::as_tibble(columns)
}

.deterministic_payload <- function(result, output, channel_name) {
    rows <- .candidate_rows(result, channel_name)
    if (!output$column %in% names(rows)) {
        stop("from_channel() column '", output$column,
             "' is unavailable on activation '", channel_name,
             "'. Available columns: ", paste(names(rows), collapse = ", "), ".",
             call. = FALSE)
    }
    if (".ee_payload_value" %in% names(rows)) {
        stop("Prepared-source column '.ee_payload_value' is reserved internally.",
             call. = FALSE)
    }
    payload <- tibble::as_tibble(rows)
    payload$task_id <- as.character(payload$task_id)
    payload$.ee_payload_value <- rows[[output$column]]
    payload
}

.reduce_from_channel <- function(values, output, variable_name) {
    values <- values[.value_is_present(values)]
    if (is.null(output$reduce)) {
        if (!length(values)) return(.typed_na(values))
        if (length(values) > 1L) {
            stop("from_channel() for '", variable_name,
                 "' found ", length(values), " non-missing values; supply reduce = ",
                 "<values-to-scalar function> or narrow the activation.",
                 call. = FALSE)
        }
        if (is.list(values) && !inherits(values, "POSIXlt")) {
            return(values[1])
        }
        return(values[[1]])
    }
    reduced <- output$reduce(values)
    if (length(reduced) != 1L || !is.null(dim(reduced))) {
        stop("from_channel() reduce for '", variable_name,
             "' must return exactly one scalar; got length ", length(reduced), ".",
             call. = FALSE)
    }
    reduced
}

.state_for_task <- function(result, task_id) {
    state <- result$coverage$processing_state[
        as.character(result$coverage$task_id) == task_id]
    if (length(state)) as.character(state[[1]]) else "no_eligible_source"
}

.status_from_processing_state <- function(state) {
    if (state %in% c("measured", "valid", "processed")) return("complete")
    if (state %in% c("invalid")) return("invalid")
    if (state %in% c("model_error", "processing_error")) return("error")
    "unavailable"
}

.hit_for_task <- function(result, task_id) {
    values <- result$values
    if (!is.data.frame(values) ||
        !all(c("task_id", "accepted_value") %in% names(values))) return(NA)
    accepted <- as.character(values$accepted_value[
        as.character(values$task_id) == task_id])
    if (!length(accepted)) return(NA)
    any(accepted %in% "present")
}

.public_evidence <- function(result, variable_name, channel_name, source_name,
                             task_ids = NULL) {
    evidence <- result$evidence
    if (!is.data.frame(evidence) || !nrow(evidence)) {
        return(tibble::tibble(
            task_id = character(), variable = character(), channel = character(),
            source = character(), evidence_ref = character()))
    }
    if (!is.null(task_ids)) {
        evidence <- evidence[as.character(evidence$task_id) %in% task_ids,
                             , drop = FALSE]
    }
    if (!nrow(evidence)) return(.public_evidence(
        list(evidence = evidence), variable_name, channel_name, source_name))
    if ("field" %in% names(evidence)) evidence$field <- NULL
    refs <- rep(NA_character_, nrow(evidence))
    for (column in c("evidence_ref", "hit_ref", "source_row_id")) {
        if (!column %in% names(evidence)) next
        candidate <- as.character(evidence[[column]])
        missing <- is.na(refs) | !nzchar(refs)
        refs[missing] <- candidate[missing]
    }
    if (anyNA(refs) || any(!nzchar(refs))) {
        stop("Public evidence contains a row without a resolvable evidence_ref.",
             call. = FALSE)
    }
    evidence$evidence_ref <- refs
    evidence$source_row_id <- NULL
    evidence$hit_ref <- NULL
    evidence$task_id <- as.character(evidence$task_id)
    evidence$variable <- variable_name
    evidence$channel <- channel_name
    evidence$source <- source_name
    front <- c("task_id", "variable", "channel", "source", "evidence_ref")
    evidence[c(front, setdiff(names(evidence), front))]
}

.single_from_channel_variable <- function(variable, tasks, channel_name, result) {
    output <- variable$output
    payload <- .deterministic_payload(result, output, channel_name)
    source_name <- .source_name_for_channel(channel_name, variable)
    task_ids <- as.character(tasks$task_id)
    rows <- lapply(task_ids, function(task_id) {
        values <- payload$.ee_payload_value[payload$task_id == task_id]
        n_values <- sum(.value_is_present(values))
        value <- .reduce_from_channel(values, output, variable$name)
        state <- .state_for_task(result, task_id)
        status <- .status_from_processing_state(state)
        tibble::tibble(
            task_id = task_id, variable = variable$name, value = value,
            channel_coverage = if (status == "error") "failed" else
                if (status == "complete") "complete" else "partial",
            n_payload_rows = as.integer(n_values))
    })
    values <- bind_rows(rows)
    status <- lapply(task_ids, function(task_id) {
        state <- .state_for_task(result, task_id)
        n_values <- sum(.value_is_present(
            payload$.ee_payload_value[payload$task_id == task_id]))
        tibble::tibble(
            task_id = task_id, variable = variable$name, channel = channel_name,
            source = source_name, status = .status_from_processing_state(state),
            hit = .hit_for_task(result, task_id), processing_state = state,
            n_payload_rows = as.integer(n_values), error = NA_character_)
    })
    list(
        values = values,
        channel_status = bind_rows(status),
        evidence = .public_evidence(
            result, variable$name, channel_name, source_name, task_ids))
}

.filter_payload_by_qualified <- function(variable, output, out, payload) {
    filter_by <- output$filter_by_qualified
    combine_level <- variable$combine$by
    output_group <- output$group_by
    combine_rank <- match(combine_level, .identity_spine)
    output_rank <- match(output_group, .identity_spine)
    if (is.na(combine_rank) || is.na(output_rank)) {
        stop("combine by and output group_by must name identity-spine keys.",
             call. = FALSE)
    }
    if (combine_rank <= output_rank) {
        if (!is.null(filter_by)) {
            stop("from_channel() filter_by_qualified must be NULL unless combine ",
                 "by is finer than output group_by.", call. = FALSE)
        }
        return(payload)
    }
    if (is.null(filter_by)) {
        stop("from_channel() must declare filter_by_qualified when combine by ('",
             combine_level, "') is finer than output group_by ('", output_group,
             "').", call. = FALSE)
    }
    if (!filter_by %in% c(combine_level, output_group)) {
        stop("from_channel() filter_by_qualified must equal combine by ('",
             combine_level, "') or output group_by ('", output_group, "').",
             call. = FALSE)
    }
    qualified <- out$combine_keys[out$combine_keys$qualifies, , drop = FALSE]
    if (identical(filter_by, output_group)) {
        if (!"task_id" %in% names(qualified)) {
            stop("Combined-key relation lacks task_id for output-level payload ",
                 "filtering.", call. = FALSE)
        }
        return(dplyr::semi_join(
            payload,
            dplyr::distinct(qualified["task_id"]),
            by = "task_id"))
    }
    if (!filter_by %in% names(payload)) {
        stop("from_channel() payload alias '", output$channel,
             "' does not carry filter_by_qualified key '", filter_by,
             "'. Available columns: ", paste(names(payload), collapse = ", "), ".",
             call. = FALSE)
    }
    join_keys <- unique(c("task_id", filter_by))
    missing <- setdiff(join_keys, names(qualified))
    if (length(missing)) {
        stop("Combined-key relation lacks payload filtering column(s): ",
             paste(missing, collapse = ", "), ".", call. = FALSE)
    }
    dplyr::semi_join(
        payload,
        dplyr::distinct(qualified[join_keys]),
        by = join_keys)
}

.apply_gated_from_channel <- function(variable, out, channel_results) {
    output <- variable$output
    channel_name <- output$channel
    result <- channel_results[[channel_name]]
    payload <- .deterministic_payload(result, output, channel_name)
    payload <- .filter_payload_by_qualified(variable, output, out, payload)
    gate <- out$values
    qualified_task_ids <- as.character(gate$task_id[gate$value %in% 1L])
    payload <- payload[
        as.character(payload$task_id) %in% qualified_task_ids, , drop = FALSE]

    # Public payload evidence follows the same relational gate as the reducer.
    # Other channels retain their complete hit evidence, and the unfiltered
    # payload intermediate remains available under audit$internal.
    payload_keys <- paste(
        as.character(payload$task_id), as.character(payload$source_row_id),
        sep = "\r")
    evidence_keys <- paste(
        as.character(out$evidence$task_id),
        as.character(out$evidence$evidence_ref), sep = "\r")
    is_payload_evidence <- out$evidence$channel == channel_name
    out$evidence <- out$evidence[
        !is_payload_evidence | evidence_keys %in% payload_keys,
        , drop = FALSE]

    value_rows <- vector("list", nrow(gate))
    n_payload <- integer(nrow(gate))
    for (i in seq_len(nrow(gate))) {
        task_id <- as.character(gate$task_id[[i]])
        values <- payload$.ee_payload_value[payload$task_id == task_id]
        if (identical(gate$value[[i]], 1L)) {
            n_payload[[i]] <- sum(.value_is_present(values))
            value_rows[[i]] <- .reduce_from_channel(values, output, variable$name)
            payload_status <- .status_from_processing_state(
                .state_for_task(result, task_id))
            if (payload_status == "error") {
                gate$channel_coverage[[i]] <- "failed"
            } else if (payload_status != "complete" &&
                       gate$channel_coverage[[i]] != "failed") {
                gate$channel_coverage[[i]] <- "partial"
            }
        } else {
            value_rows[[i]] <- .typed_na(payload$.ee_payload_value)
        }
    }
    gate$value <- bind_rows(lapply(
        value_rows, function(value) tibble::tibble(value = value)))$value
    gate$n_payload_rows <- n_payload
    out$values <- gate
    out
}

.single_llm_from_channel_variable <- function(variable, tasks, channel_name,
                                              result) {
    output <- variable$output
    prototype <- result$value_prototype
    if (!is.data.frame(prototype)) {
        stop("LLM activation '", channel_name,
             "' did not expose its authored response prototype.", call. = FALSE)
    }
    if (!is.null(output$column) && !output$column %in% names(prototype)) {
        stop("from_channel() column '", output$column,
             "' is unavailable on LLM activation '", channel_name,
             "'. Available fields: ", paste(names(prototype), collapse = ", "), ".",
             call. = FALSE)
    }
    task_ids <- as.character(tasks$task_id)
    authored <- names(prototype)
    value_rows <- lapply(task_ids, function(task_id) {
        state <- .state_for_task(result, task_id)
        selected <- result$values[
            as.character(result$values$task_id) == task_id, , drop = FALSE]
        valid <- identical(state, "valid") && nrow(selected) == 1L
        response <- if (valid) selected[authored] else .typed_na_frame(prototype)
        if (!is.null(output$column)) {
            response <- tibble::tibble(value = response[[output$column]])
        }
        citation_warning <- valid && isTRUE(selected$citation_warning[[1]])
        review <- state %in% c("invalid", "model_error", "processing_error")
        bind_cols(
            tibble::tibble(task_id = task_id, variable = variable$name),
            response,
            tibble::tibble(
                channel_coverage = if (valid) "complete" else
                    if (state %in% c("model_error", "processing_error")) "failed" else "partial",
                needs_review = review,
                citation_warning = citation_warning,
                review_reason = if (review && nrow(selected) &&
                    "task_validity_reason" %in% names(selected)) {
                    as.character(selected$task_validity_reason[[1]])
                } else if (review) state else NA_character_))
    })
    values <- bind_rows(value_rows)
    source_name <- .source_name_for_channel(channel_name, variable)
    status <- bind_rows(lapply(task_ids, function(task_id) {
        state <- .state_for_task(result, task_id)
        selected <- result$values[
            as.character(result$values$task_id) == task_id, , drop = FALSE]
        tibble::tibble(
            task_id = task_id, variable = variable$name, channel = channel_name,
            source = source_name, status = .status_from_processing_state(state),
            hit = if (identical(state, "valid")) TRUE else NA,
            processing_state = state,
            citation_warning = nrow(selected) == 1L &&
                isTRUE(selected$citation_warning[[1]]),
            needs_review = state %in% c("invalid", "model_error", "processing_error"))
    }))
    list(
        values = values,
        channel_status = status,
        evidence = .public_evidence(
            result, variable$name, channel_name, source_name, task_ids))
}

.apply_gated_llm_from_channel <- function(variable, out, tasks, channel_results) {
    channel_name <- variable$output$channel
    assembled <- .single_llm_from_channel_variable(
        variable, tasks, channel_name, channel_results[[channel_name]])
    gate <- out$values[c("task_id", "value")]
    names(gate)[[2]] <- ".qualifies"
    values <- left_join(assembled$values, gate, by = "task_id")
    authored <- setdiff(
        names(values),
        c("task_id", "variable", "channel_coverage", "needs_review",
          "citation_warning", "review_reason", ".qualifies"))
    excluded <- !values$.qualifies %in% 1L
    for (column in authored) values[[column]][excluded] <- .typed_na(values[[column]])
    included <- !excluded
    combine_coverage <- out$values$channel_coverage[
        match(values$task_id, out$values$task_id)]
    payload_coverage <- values$channel_coverage
    values$channel_coverage <- combine_coverage
    values$channel_coverage[included &
        (combine_coverage == "failed" | payload_coverage == "failed")] <- "failed"
    values$channel_coverage[included &
        values$channel_coverage != "failed" &
        (combine_coverage == "partial" | payload_coverage == "partial")] <- "partial"
    values$channel_coverage[included &
        combine_coverage == "complete" & payload_coverage == "complete"] <- "complete"
    values$.qualifies <- NULL
    out$values <- values
    out
}

# combine_channels(): the string boolean operator. The final cohort decision is
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
#                 contribution.
#   evidence      per hit ref.
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
.channel_combine_keys <- function(res, by, channel_name, hit_task_ids) {
    ev <- res$evidence
    if (is.null(ev) || !nrow(ev) || !length(hit_task_ids)) {
        return(tibble::tibble(task_id = character(), key = character()))
    }
    if (!by %in% names(ev)) {
        stop("combine by = '", by, "': channel '", channel_name,
             "' evidence does not carry that key; level algebra needs ",
             "spine-keyed evidence (HDW sources and raw-document retrieval ",
             "carry it; pre-retrieved text fixtures must include it).",
             call. = FALSE)
    }
    ev <- ev[as.character(ev$task_id) %in% hit_task_ids, , drop = FALSE]
    keys <- as.character(ev[[by]])
    if (anyNA(keys) || any(!nzchar(keys))) {
        stop("combine by = '", by, "': channel '", channel_name,
             "' has hit evidence without a ", by, " value; a hit that ",
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
    audit_vectors <- stats::setNames(lapply(declared, hit_vec), declared)
    vectors <- audit_vectors[referenced]
    observed <- stats::setNames(lapply(vectors, function(v) v %in% TRUE), referenced)

    combine_level <- combine$by
    output_group <- variable$output$group_by
    combine_rank <- match(combine_level, .identity_spine)
    output_rank <- match(output_group, .identity_spine)
    if (is.na(combine_rank) || is.na(output_rank)) {
        stop("combine by and output group_by must name identity-spine keys.",
             call. = FALSE)
    }

    if (combine_rank > output_rank) {
        # Fine -> coarse: evaluate over the observed finer-key universe and then
        # project with exists() to each output task. The engine has no roster of
        # unobserved finer units, so negation is complement within observed keys.
        keysets <- stats::setNames(lapply(referenced, function(ch) {
            .channel_combine_keys(channel_results[[ch]], combine_level, ch,
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
        combine_keys[[combine_level]] <- universe$key
        for (ch in referenced) combine_keys[[ch]] <- observed_keys[[ch]]
        combine_keys$qualifies <- key_result
        result <- task_ids %in% universe$task_id[key_result]
    } else {
        # Same grain is direct. Coarse -> fine is the explicitly authored
        # broadcast: aggregate observed hits at combine$by, evaluate once there,
        # then attach that verdict to every descendant output task.
        required <- c("task_id", combine_level)
        missing <- setdiff(required, names(tasks))
        if (length(missing)) {
            stop("combine by = '", combine_level,
                 "' requires task column(s): ", paste(missing, collapse = ", "),
                 ".", call. = FALSE)
        }
        task_units <- dplyr::distinct(tibble::as_tibble(tasks)[required])
        task_units$task_id <- as.character(task_units$task_id)
        task_units[[combine_level]] <- as.character(task_units[[combine_level]])
        units <- dplyr::distinct(task_units[combine_level])
        observed_units <- stats::setNames(lapply(referenced, function(ch) {
            positive_tasks <- task_ids[vectors[[ch]] %in% TRUE]
            positive_units <- unique(task_units[[combine_level]][
                task_units$task_id %in% positive_tasks])
            units[[combine_level]] %in% positive_units
        }), referenced)
        unit_result <- .eval_hitset_expr(combine$ast, observed_units)
        relation <- units
        for (ch in referenced) relation[[ch]] <- observed_units[[ch]]
        relation$qualifies <- unit_result
        task_decisions <- dplyr::left_join(
            task_units, relation, by = combine_level,
            relationship = "many-to-one")
        result <- task_decisions$qualifies[
            match(task_ids, task_decisions$task_id)]
        # Keep the audit relation at combine$by. task_decisions is the explicit
        # broadcast to output tasks and is execution plumbing, not a second
        # definition of the qualifying relation.
        combine_keys <- relation
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
            status_l[[length(status_l) + 1L]] <- tibble::tibble(
                task_id = tid, variable = var_name, channel = ch, source = src,
                status = r$status, hit = r$hit,
                processing_state = .channel_raw_state(channel_results, ch, tid),
                contribution = .contribution_class(r$status, r$hit),
                error = NA_character_)
        }
        evidence_l[[ch]] <- .public_evidence(
            channel_results[[ch]], var_name, ch, src,
            task_ids[audit_vectors[[ch]] %in% TRUE])
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
                           evidence_ref = character()),
        overlap = overlap)
    # Relation audit: one row per evaluated combine key, attached to its output
    # task when projection or broadcast is required.
    out$combine_keys <- combine_keys
    out
}

# --- normalized audit ----------------------------------------------------------

.audit_coverage_count <- function(result, task_ids, column) {
    coverage <- result$coverage
    if (!is.data.frame(coverage) || !column %in% names(coverage)) {
        return(integer(length(task_ids)))
    }
    index <- match(as.character(task_ids), as.character(coverage$task_id))
    n <- as.integer(coverage[[column]][index])
    n[is.na(n)] <- 0L
    n
}

.channel_audit_counts <- function(variable, channel_name, result, task_ids) {
    channel <- variable$channels[[channel_name]]
    counts <- list()

    if (is.data.frame(result$audit_counts)) {
        counts[[length(counts) + 1L]] <- result$audit_counts
    } else if (channel$type %in% c("code", "act", "lab", "doc")) {
        counts[[length(counts) + 1L]] <- .audit_stage(
            task_ids, channel_name, "task_join", "source_row",
            .audit_coverage_count(result, task_ids, "n_source_rows"))
        if (inherits(channel$window, "ee_window")) {
            counts[[length(counts) + 1L]] <- .audit_stage(
                task_ids, channel_name, "window", "source_row",
                .audit_coverage_count(result, task_ids, "n_scope_rows"))
        }

        observations <- result$observations
        selector_keep <- observations$is_target | observations$row_demoted |
            observations$group_demoted
        counts[[length(counts) + 1L]] <- .audit_stage(
            task_ids, channel_name, "selector", "source_row",
            .count_task_rows(observations, task_ids, selector_keep))
        if (is.function(channel$filter_rows)) {
            after_rows <- observations$is_target | observations$group_demoted
            counts[[length(counts) + 1L]] <- .audit_stage(
                task_ids, channel_name, "filter_rows", "source_row",
                .count_task_rows(observations, task_ids, after_rows))
        }
        if (is.function(channel$filter_groups)) {
            counts[[length(counts) + 1L]] <- .audit_stage(
                task_ids, channel_name, "filter_groups", "source_row",
                .count_task_rows(observations, task_ids,
                                 observations$is_target))
        }
    }

    if (.channel_needs_chat(channel)) {
        counts[[length(counts) + 1L]] <- .audit_stage(
            task_ids, channel_name, "model_input", "snippet",
            .count_task_rows(result$model_candidates, task_ids))
    }
    dplyr::bind_rows(counts)
}

.build_audit_counts <- function(variable, channel_results, out, tasks) {
    task_ids <- as.character(tasks$task_id)
    counts <- lapply(names(channel_results), function(channel_name) {
        .channel_audit_counts(
            variable, channel_name, channel_results[[channel_name]], task_ids)
    })
    if (identical(variable$output$kind, "from_channel") &&
        "n_payload_rows" %in% names(out$values)) {
        index <- match(task_ids, as.character(out$values$task_id))
        n <- as.integer(out$values$n_payload_rows[index])
        n[is.na(n)] <- 0L
        counts[[length(counts) + 1L]] <- .audit_stage(
            task_ids, variable$output$channel, "output_input",
            "non_missing_value", n)
    }
    result <- dplyr::bind_rows(counts)
    if (!nrow(result)) {
        return(tibble::tibble(
            task_id = character(), channel = character(), stage = character(),
            unit = character(), n = integer()))
    }
    result
}

.build_audit_llm_calls <- function(channel_results) {
    calls <- lapply(names(channel_results), function(channel_name) {
        frame <- channel_results[[channel_name]]$attempts
        if (!is.data.frame(frame)) return(NULL)
        if (!"task_id" %in% names(frame)) frame$task_id <- character()
        frame$channel <- channel_name
        frame[c("task_id", "channel",
                setdiff(names(frame), c("task_id", "channel")))]
    })
    result <- dplyr::bind_rows(calls)
    if (!nrow(result) && !all(c("task_id", "channel") %in% names(result))) {
        result <- tibble::tibble(task_id = character(), channel = character())
    }
    result
}

.build_channel_intermediates <- function(channel_results) {
    lapply(channel_results, function(result) {
        result[setdiff(names(result), c("attempts", "audit_counts"))]
    })
}

# --- resolved execution manifest (DESIGN §12, invariant 27) --------------------
# `run$audit$execution_manifest` is a serializable snapshot of the RESOLVED
# definition that actually executed (post concept-default / activation-override
# inheritance) plus the execution facts the engine knows (timestamp and resolved
# source-role mappings). It is assembled from
# resolve_variable_spec(), so the audit trail and the executor read the SAME
# resolution -- a trail recording the concept baseline while the executor ran a
# local override would be a silent audit lie no review of the values can catch.
# Per-call LLM details (provider/seed/prompt/schema/query hashes) already
# ride on channel_results[[channel]]$attempts and are not duplicated here.

# Snapshot a selector as a plain named list (kind + identity fields, NULLs dropped):
# a serializable record, not a live spec object.
.manifest_selector <- function(selector) {
    if (is.null(selector)) return(NULL)
    snap <- unclass(selector)
    attributes(snap) <- list(names = names(snap))
    snap <- snap[!vapply(snap, is.null, logical(1))]
    # Closure members are deparsed, like the anchor's select_event and activation
    # row/group filters -- the audit trail
    # carries the rule as serializable text, not a live function object.
    fns <- vapply(snap, is.function, logical(1))
    snap[fns] <- lapply(snap[fns], function(f) paste(deparse(f), collapse = " "))
    snap
}

.manifest_anchor <- function(anchor) {
    if (is.null(anchor)) return(NULL)
    if (inherits(anchor, "ee_index_event")) {
        # The EXECUTED anchor column: the declared `at`, or the source's
        # windowing clock it defaults to.
        return(list(kind = "index_event", source = anchor$source,
                    selector = .manifest_selector(anchor$selector),
                    at = anchor$at %||%
                        (if (anchor$source %in% names(EE_SOURCES)) {
                            EE_SOURCES[[anchor$source]]$source_time_start
                        } else NULL),
                    # The executed multi-match rule, serializable (like reduce).
                    select_event = if (is.function(anchor$select_event)) {
                        paste(deparse(anchor$select_event), collapse = " ")
                    } else NULL))
    }
    list(kind = "cohort_column", column = as.character(anchor))
}

.build_execution_manifest <- function(variable) {
    channels <- lapply(variable$channels, function(ch) {
        spec <- if (ch$source %in% names(EE_SOURCES)) EE_SOURCES[[ch$source]]
                else NULL
        list(
            alias = ch$name,
            origin_name = ch$origin_name,
            origin_kind = ch$origin_kind,
            type = ch$type,
            source = ch$source,
            source_roles = if (is.null(spec)) NULL else source_roles(spec),
            runtime_roles = if (identical(ch$type, "text")) {
                list(text = "snippet_text", evidence_ref = "hit_ref")
            } else NULL,
            required_roles = ch$required_roles,
            search_within = ch$search_within,
            original_selector = .manifest_selector(ch$original_selector),
            effective_selector = .manifest_selector(ch$selector),
            selector_source = ch$selector_source,
            filter_rows = if (is.function(ch$filter_rows)) {
                paste(deparse(ch$filter_rows), collapse = " ")
            } else NULL,
            window = if (inherits(ch$window, "ee_window")) {
                list(from_days = ch$window$from_days,
                     to_days = ch$window$to_days,
                     relation = ch$window$relation)
            } else NULL,
            method = ch$method,
            declared_model = if (identical(ch$method, "lucene_llm")) {
                ch$model
            } else NULL,
            declared_model_params = if (identical(ch$method, "lucene_llm")) {
                ch$model_params
            } else NULL,
            response = ch$response,
            user_prompt = ch$user_prompt,
            system_prompt = if (identical(ch$method, "lucene_llm")) {
                ch$system_prompt %||% DEFAULT_LLM_SYSTEM_PROMPT
            } else NULL,
            rationale = ch$rationale,
            max_candidates = ch$max_candidates,
            group_by = ch$group_by,
            filter_groups = if (is.function(ch$filter_groups)) {
                paste(deparse(ch$filter_groups), collapse = " ")
            } else NULL)
    })
    output <- if (is.null(variable$output)) NULL else {
        out <- list(kind = variable$output$kind)
        if (!is.null(variable$output$channel)) out$channel <- variable$output$channel
        if (!is.null(variable$output$column)) out$column <- variable$output$column
        if (!is.null(variable$output$filter_by_qualified)) {
            out$filter_by_qualified <- variable$output$filter_by_qualified
        }
        out$group_by <- variable$output$group_by
        if (is.function(variable$output$reduce)) {
            out$reduce <- paste(deparse(variable$output$reduce), collapse = " ")
        }
        out
    }
    combine <- if (inherits(variable$combine, "ee_combiner") &&
                   identical(variable$combine$kind, "hit_set_expr")) {
        list(expr = variable$combine$expr, by = variable$combine$by)
    } else NULL
    structure(
        list(
            variable = variable$name,
            concept = variable$concept,
            anchor = .manifest_anchor(variable$anchor),
            combine = combine,
            output = output,
            channels = channels,
            executed_at = Sys.time()),
        class = c("ee_execution_manifest", "list"))
}

print.ee_execution_manifest <- function(x, ...) {
    output <- x$output
    output_label <- output$kind %||% "none"
    if (identical(output$kind, "from_channel")) {
        payload <- if (is.null(output$column)) {
            paste0(output$channel, " (all structured fields)")
        } else {
            paste0(output$channel, "$", output$column)
        }
        output_label <- paste0(output$kind, " from ", payload)
    }

    cat("Execution manifest: ", x$variable, "\n", sep = "")
    cat("  concept: ", x$concept, "\n", sep = "")
    if (!is.null(x$anchor)) {
        anchor_label <- if (identical(x$anchor$kind, "cohort_column")) {
            paste0(x$anchor$column, " (provided by cohort)")
        } else {
            paste0("index event from ", x$anchor$source,
                   if (is.null(x$anchor$at)) "" else paste0(" at ", x$anchor$at))
        }
        cat("  anchor: ", anchor_label, "\n", sep = "")
    }
    if (!is.null(x$combine)) {
        cat("  combine: ", x$combine$expr, "\n", sep = "")
        cat("  combine by: ", x$combine$by, "\n", sep = "")
    }
    cat("  output: ", output_label, "\n", sep = "")
    if (!is.null(output$filter_by_qualified)) {
        cat("  filter by qualified: ", output$filter_by_qualified, "\n", sep = "")
    }
    cat("  group by: ", output$group_by, "\n", sep = "")
    if (!is.null(output$reduce)) cat("  reduce: configured\n")

    cat("\nChannels:\n")
    for (name in names(x$channels)) {
        channel <- x$channels[[name]]
        method <- if (is.null(channel$method)) "" else paste0(" / ", channel$method)
        cat("  ", name, " <- ", channel$origin_kind, ":", channel$origin_name,
            " [", channel$type, " / ", channel$source, method, "]\n", sep = "")
        .print_selector(channel$effective_selector, indent = "    ")
        if (identical(channel$selector_source, "activation")) {
            cat("    selector: activation override\n")
        }
        .print_search_within(channel$search_within, indent = "    ")
        if (!is.null(channel$window)) {
            cat("    window: ", channel$window$from_days, " to ",
                channel$window$to_days, " days\n", sep = "")
        }
        if (!is.null(channel$filter_rows)) cat("    filter rows: configured\n")
        if (!is.null(channel$filter_groups)) {
            cat("    filter groups by ", channel$group_by, ": configured\n", sep = "")
        }
        if (identical(channel$method, "lucene_llm")) {
            cat("    model: ", channel$declared_model %||% "Chat override",
                "\n", sep = "")
            fields <- .response_field_names(channel$response)
            if (!is.null(channel$rationale)) fields <- c(fields, "rationale")
            cat("    response fields: ", paste(fields, collapse = ", "),
                "\n", sep = "")
        }
    }
    cat("\nExecuted at: ", format(x$executed_at, usetz = TRUE), "\n", sep = "")
    invisible(x)
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
# roster). task_id is always derived from the declared output grain keys.
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
    grain <- variable$output$group_by
    grain_keys <- .output_grain_keys(grain)
    missing_keys <- setdiff(grain_keys, names(cohort))
    generates_evtid <- identical(grain, "EVTID") &&
        inherits(variable$anchor, "ee_index_event") &&
        "PATID" %in% names(cohort) && !"EVTID" %in% names(cohort)
    if (length(missing_keys) &&
        !(generates_evtid && identical(missing_keys, "EVTID"))) {
        stop("output group_by = '", grain,
             "' needs cohort column(s): ",
             paste(missing_keys, collapse = ", "), ".", call. = FALSE)
    }
    anchor_column <- if (is.character(variable$anchor)) variable$anchor else NULL
    keep <- unique(c(grain_keys, anchor_column))
    keep <- intersect(keep, names(cohort))
    # task_id is always internal and always derived from output$group_by. A
    # caller column with that name cannot override task identity.
    cohort <- dplyr::distinct(tibble::as_tibble(cohort)[keep])
    # task_id is internal execution plumbing derived from the declared grain
    # keys. Public result views publish those native keys, never this composite.
    if (!"task_id" %in% names(cohort)) {
        keys <- intersect(
            .output_grain_keys(variable$output$group_by),
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
    published <- lapply(names(run), function(component) {
        el <- run[[component]]
        if (is.data.frame(el) && "task_id" %in% names(el)) {
            index <- match(as.character(el$task_id),
                           as.character(key_map$task_id))
            if (anyNA(index)) {
                stop("A published result row does not resolve to its grain keys.",
                     call. = FALSE)
            }
            keys <- key_map[index, grain_keys, drop = FALSE]
            # EVTID on evidence always belongs to the source row. Publish it as
            # source_EVTID, then add the target EVTID from the task grain when the
            # result itself is event-level.
            if (identical(component, "evidence") && "EVTID" %in% names(el)) {
                el$source_EVTID <- as.character(el$EVTID)
                el$EVTID <- NULL
            }
            payload <- el[setdiff(names(el), c("task_id", grain_keys))]
            return(dplyr::bind_cols(keys, payload))
        }
        el
    })
    names(published) <- names(run)
    published
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
    # pre-anchor one -- select_event = identity with output group_by =
    # "PATID" must fail loudly (DESIGN §7).
    tasks <- .resolve_anchor(variable, tasks, sources)
    grain_keys <- .check_output_grain(variable, tasks)
    # Resolve one transport per LLM activation. A run_variable(chat=) argument is
    # a global test/debug override for every LLM activation in this run. Per-task
    # Chat clones still isolate conversation state within each activation.
    channel_chats <- .resolve_channel_chats(variable, chat)
    # Scoping rule (DESIGN §7): an explicit event evidence scope constrains rows
    # to PATID + EVTID. Otherwise a declared window gathers per subject inside
    # each task's anchored window; with no window, the output grain is the scope.
    channel_results <- lapply(names(variable$channels), function(channel_name) {
        scope_keys <- .channel_scope_keys(
            .channel_def(variable, channel_name), variable, tasks, grain_keys)
        .run_selected_channel(
            variable, channel_name, tasks, sources,
            channel_chats[[channel_name]],
            grain_keys = scope_keys)
    })
    names(channel_results) <- names(variable$channels)

    combine <- variable$combine
    if (inherits(combine, "ee_combiner") &&
        identical(combine$kind, "hit_set_expr")) {
        # Multi-channel hit-set algebra gates tasks/keys. bin_output() publishes
        # membership; from_channel() publishes a separately named payload alias.
        out <- .hit_set_expr_variable(variable, tasks, channel_results)
        if (identical(variable$output$kind, "from_channel")) {
            payload_channel <- .channel_def(variable, variable$output$channel)
            out <- if (identical(payload_channel$method, "lucene_llm")) {
                .apply_gated_llm_from_channel(
                    variable, out, tasks, channel_results)
            } else {
                .apply_gated_from_channel(variable, out, channel_results)
            }
        }
    } else if (is.null(combine)) {
        # Single channel: publish membership or the activation payload.
        ch <- names(channel_results)[[1]]
        output_kind <- variable$output$kind
        out <- switch(output_kind,
            binary = .single_membership_variable(
                variable, tasks, ch, channel_results[[1]]),
            from_channel = {
                if (identical(.channel_def(variable, ch)$method, "lucene_llm")) {
                    .single_llm_from_channel_variable(
                        variable, tasks, ch, channel_results[[1]])
                } else {
                    .single_from_channel_variable(
                        variable, tasks, ch, channel_results[[1]])
                }
            },
            stop("Unsupported single-channel output: ", output_kind,
                 " (expected binary/from_channel).",
                 call. = FALSE))
    } else {
        stop("Unsupported combine; expected a hit-set expression (>=2 channels) ",
             "or NULL (single channel).", call. = FALSE)
    }
    counts <- .build_audit_counts(variable, channel_results, out, tasks)
    llm_calls <- .build_audit_llm_calls(channel_results)

    # n_payload_rows is execution bookkeeping, not part of the produced variable.
    out$values$n_payload_rows <- NULL
    out$channel_status$n_payload_rows <- NULL

    core <- out[intersect(c("values", "channel_status", "evidence"), names(out))]
    temporary <- c(
        core,
        list(.audit_counts = counts, .audit_llm_calls = llm_calls),
        if (is.data.frame(out$combine_keys)) {
            list(.audit_combine_keys = out$combine_keys)
        } else list())
    published <- .publish_grain_keys(
        temporary, tasks = tasks, grain_keys = grain_keys)

    audit <- list(
        counts = published$.audit_counts,
        llm_calls = published$.audit_llm_calls,
        execution_manifest = .build_execution_manifest(variable))
    if (is.data.frame(out$overlap)) audit$overlap <- out$overlap
    if (is.data.frame(out$combine_keys)) {
        audit$combine_keys <- published$.audit_combine_keys
    }
    audit$internal <- list(
        resolved_spec = variable,
        channel_intermediates = .build_channel_intermediates(channel_results))
    result <- published[intersect(
        c("values", "channel_status", "evidence"), names(published))]
    result$audit <- audit
    result
}

# The protocol run: every variable of a study over ONE declared cohort laid
# down with the data (sources$cohort), so all outputs share the denominator by
# construction. Variables execute sequentially in list order: each run resolves
# every LLM activation's model, then processes its task rows. Today a thin
# orchestrator; study-level duties (shared channel
# caching, one combined output table, study provenance bundle) wait for their
# consumers.
run_protocol <- function(variables, cohort = NULL, sources = NULL,
                          chat = NULL) {
    if (!is.list(variables) || !length(variables)) {
        stop("run_protocol() variables must be a non-empty list.",
             call. = FALSE)
    }
    bad <- !vapply(variables, inherits, logical(1), "ee_variable_spec")
    if (any(bad)) {
        stop("Every run_protocol() entry must be a variable_spec(); invalid ",
             "position(s): ", paste(which(bad), collapse = ", "), ".",
             call. = FALSE)
    }
    canonical_names <- unname(vapply(
        variables, function(spec) spec$name, character(1)))
    duplicated_names <- unique(canonical_names[duplicated(canonical_names)])
    if (length(duplicated_names)) {
        stop("run_protocol() spec$name values must be unique; duplicated: ",
             paste(duplicated_names, collapse = ", "), ".", call. = FALSE)
    }

    supplied_names <- names(variables)
    if (!is.null(supplied_names)) {
        if (anyNA(supplied_names)) {
            stop("run_protocol() variables must be entirely unnamed or entirely ",
                 "named.", call. = FALSE)
        }
        has_name <- nzchar(supplied_names)
        if (any(has_name) && !all(has_name)) {
            stop("run_protocol() variables must be entirely unnamed or entirely ",
                 "named.", call. = FALSE)
        }
        if (all(has_name) && !identical(supplied_names, canonical_names)) {
            stop("run_protocol() list names must exactly match spec$name in the ",
                 "same order. Expected: ", paste(canonical_names, collapse = ", "),
                 "; got: ", paste(supplied_names, collapse = ", "), ".",
                 call. = FALSE)
        }
    }

    results <- lapply(variables, run_variable, cohort = cohort, sources = sources,
                      chat = chat)
    names(results) <- canonical_names
    results
}
