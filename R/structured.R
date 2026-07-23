# =============================================================================
# structured.R — deterministic (non-LLM) extraction path for STRUCTURED sources
# -----------------------------------------------------------------------------
# Mirrors the text path's four views but: evidence = selected source rows,
# measurement = a deterministic rule, NO corpus and NO model. NEUTRAL, concept-
# agnostic executors only: measure_code_presence (code/act membership) and
# measure_analyte_values (valued rows of an analyte in a window -- the output
# expression is evaluated later during assembly); the
# run_variable() dispatch binds each to its source. Coverage census is kept over ALL
# tasks, same discipline as the text path. Provenance points at the exact source rows.
# =============================================================================

# --- contract / provenance helpers ------------------------------------------

.require_columns <- function(x, required, label) {
    missing <- setdiff(required, names(x))
    if (length(missing)) {
        stop(label, " requires: ", paste(required, collapse = ", "),
             "; missing: ", paste(missing, collapse = ", "), call. = FALSE)
    }
}

.validate_structured_inputs <- function(tasks, source_rows, source_required, source_label,
                                        require_anchor = TRUE) {
    task_cols <- if (require_anchor) c("task_id", "PATID", "anchor_date")
                 else c("task_id", "PATID")
    .require_columns(tasks, task_cols, "tasks")
    .require_columns(source_rows, source_required, source_label)

    task_ids <- as.character(tasks$task_id)
    source_ids <- as.character(source_rows$source_row_id)
    if (anyNA(task_ids) || any(!nzchar(task_ids)) || anyDuplicated(task_ids)) {
        stop("tasks$task_id must be non-missing and unique", call. = FALSE)
    }
    if (anyNA(tasks$PATID) || any(!nzchar(as.character(tasks$PATID)))) {
        stop("tasks$PATID must be non-missing", call. = FALSE)
    }
    if (require_anchor && anyNA(tasks$anchor_date)) {
        stop("tasks$anchor_date must be non-missing", call. = FALSE)
    }
    if (anyNA(source_ids) || any(!nzchar(source_ids)) || anyDuplicated(source_ids)) {
        stop(source_label, "$source_row_id must be non-missing and unique",
             call. = FALSE)
    }
    invisible(TRUE)
}

.clinical_date <- function(x) {
    if (inherits(x, "POSIXt")) {
        return(as.Date(x, tz = "Europe/Paris"))
    }
    if (inherits(x, "Date")) return(x)
    stop("Expected a Date or POSIXt value.",
         call. = FALSE)
}

.assert_evidence_resolves <- function(evidence, observations, source_rows) {
    if (!nrow(evidence)) return(invisible(TRUE))

    evidence_key <- paste(evidence$task_id, evidence$source_row_id, sep = "\r")
    observation_key <- paste(observations$task_id, observations$source_row_id, sep = "\r")
    if (anyDuplicated(evidence_key)) {
        stop("selected evidence contains duplicate task/source-row links",
             call. = FALSE)
    }
    source_matches <- vapply(
        evidence$source_row_id,
        function(id) sum(source_rows$source_row_id == id),
        integer(1))
    if (any(source_matches != 1L)) {
        stop("selected evidence source_row_id must resolve exactly once in source rows",
             call. = FALSE)
    }
    observation_matches <- vapply(
        evidence_key,
        function(key) sum(observation_key == key),
        integer(1))
    if (any(observation_matches != 1L)) {
        stop("selected evidence must resolve exactly once in observations",
             call. = FALSE)
    }
    invisible(TRUE)
}

# --- scope helpers (point / interval) ----------------------------------------

.within_point <- function(t, lo, hi) !is.na(t) & t >= lo & t <= hi

# Find data-column references without evaluating author code. Bare names resolve
# against the prepared columns first and then the quosure environment; explicit
# .data accesses always name prepared columns. This makes a misspelled column fail
# even when the selector happens to produce zero target rows.
.data_mask_references <- function(expression) {
    env <- rlang::quo_get_env(expression)
    required <- character()

    resolve_pronoun_key <- function(node, pronoun) {
        key <- if (is.character(node) && length(node) == 1L) {
            node
        } else if (rlang::is_symbol(node)) {
            name <- rlang::as_string(node)
            if (!rlang::env_has(env, name, inherit = TRUE)) {
                stop(pronoun, "[[", name,
                     "]] requires that '", name,
                     "' be defined in the expression environment.",
                     call. = FALSE)
            }
            rlang::env_get(env, name, inherit = TRUE)
        } else {
            stop(pronoun,
                 "[[...]] accepts only a literal column name or a symbol ",
                 "bound to one; author code is not executed during validation.",
                 call. = FALSE)
        }
        if (!is.character(key) || length(key) != 1L ||
            is.na(key) || !nzchar(key)) {
            stop(pronoun,
                 "[[...]] must resolve to one non-empty name.",
                 call. = FALSE)
        }
        key
    }

    visit <- function(node, locals = character()) {
        if (rlang::is_symbol(node)) {
            name <- rlang::as_string(node)
            if (name %in% c(".data", ".env", locals) ||
                rlang::env_has(env, name, inherit = TRUE)) {
                return(locals)
            }
            required <<- c(required, name)
            return(locals)
        }
        if (!rlang::is_call(node)) return(locals)

        if (rlang::is_call(node, "{")) {
            for (argument in as.list(node)[-1L]) {
                locals <- visit(argument, locals)
            }
            return(locals)
        }
        if ((rlang::is_call(node, "<-") || rlang::is_call(node, "=")) &&
            length(node) >= 3L && rlang::is_symbol(node[[2L]])) {
            locals <- visit(node[[3L]], locals)
            return(unique(c(locals, rlang::as_string(node[[2L]]))))
        }
        # Only assignments reached sequentially in a `{}` block are known to
        # define a name for later expressions. An exhaustive if/else may also
        # define names, but only those defined by both branches.
        if (rlang::is_call(node, "if")) {
            condition_locals <- visit(node[[2L]], locals)
            then_locals <- visit(node[[3L]], condition_locals)
            if (length(node) < 4L) return(condition_locals)
            else_locals <- visit(node[[4L]], condition_locals)
            return(unique(c(
                condition_locals,
                intersect(then_locals, else_locals)
            )))
        }
        if (rlang::is_call(node, "for") && length(node) >= 4L &&
            rlang::is_symbol(node[[2L]])) {
            visit(node[[3L]], locals)
            loop_locals <- unique(c(locals, rlang::as_string(node[[2L]])))
            visit(node[[4L]], loop_locals)
            return(locals)
        }
        if (rlang::is_call(node, "while") || rlang::is_call(node, "repeat")) {
            for (argument in as.list(node)[-1L]) visit(argument, locals)
            return(locals)
        }
        if (rlang::is_call(node, "function") && length(node) >= 3L) {
            formals <- names(as.list(node[[2L]]))
            visit(node[[3L]], unique(c(locals, formals)))
            return(locals)
        }
        if (rlang::is_call(node, "~")) {
            formula_locals <- unique(c(
                locals, ".", ".x", ".y", "..1", "..2"
            ))
            for (argument in as.list(node)[-1L]) {
                visit(argument, formula_locals)
            }
            return(locals)
        }

        operator <- node[[1L]]
        if (rlang::is_symbol(operator) &&
            rlang::as_string(operator) %in% c("$", "[[")) {
            object <- node[[2L]]
            if (rlang::is_symbol(object, ".data")) {
                key <- if (rlang::is_call(node, "$")) {
                    rlang::as_string(node[[3L]])
                } else {
                    resolve_pronoun_key(node[[3L]], ".data")
                }
                required <<- c(required, key)
                return(locals)
            }
            if (rlang::is_symbol(object, ".env")) {
                key <- if (rlang::is_call(node, "$")) {
                    rlang::as_string(node[[3L]])
                } else {
                    resolve_pronoun_key(node[[3L]], ".env")
                }
                if (!rlang::env_has(env, key, inherit = TRUE)) {
                    stop(".env$", key, " is not defined in the expression environment.",
                         call. = FALSE)
                }
                return(locals)
            }
            # In ordinary `$`, the field name is not evaluated. An ordinary
            # `[[` index is, so visit it after the object.
            visit(object, locals)
            if (rlang::is_call(node, "[[")) {
                visit(node[[3L]], locals)
            }
            return(locals)
        }

        # The call head names a function/operator, not a data column.
        for (argument in as.list(node)[-1L]) {
            visit(argument, locals)
        }
        locals
    }

    visit(rlang::quo_get_expr(expression))
    unique(required)
}

.validate_data_mask_expression <- function(expression, columns, field, what) {
    if (!rlang::is_quosure(expression)) {
        stop(what, " for channel '", field,
             "' is not a captured data-masked expression.", call. = FALSE)
    }
    references <- tryCatch(
        .data_mask_references(expression),
        error = function(cnd) {
            stop(what, " for channel '", field,
                 "' could not resolve its data-mask references: ",
                 conditionMessage(cnd), call. = FALSE)
        })
    missing <- setdiff(references, columns)
    if (length(missing)) {
        stop(what, " for channel '", field,
             "' references missing prepared-source column(s): ",
             paste(missing, collapse = ", "), ". Available columns: ",
             paste(columns, collapse = ", "), ".", call. = FALSE)
    }
    invisible(TRUE)
}

# Data-masked activation expressions see complete prepared-source columns and the
# quosure's lexical environment. Evaluation errors are reported at the channel
# boundary with the available columns so a missing prepared-view column stays a
# source-contract error rather than an opaque tidy-eval failure.
.eval_activation_expression <- function(rows, expression, field, what,
                                        mask_columns) {
    mask <- rows[intersect(mask_columns, names(rows))]
    tryCatch(
        rlang::eval_tidy(expression, data = mask),
        error = function(cnd) {
            stop(what, " for channel '", field,
                 "' could not be evaluated against prepared-source columns ",
                 paste(names(mask), collapse = ", "), ": ",
                 conditionMessage(cnd), call. = FALSE)
        })
}

# A row predicate returns one logical per row. An NA result is not a hit.
.eval_row_predicate <- function(rows, filter_rows, field, mask_columns) {
    res <- .eval_activation_expression(
        rows, filter_rows, field, "filter_rows", mask_columns)
    if (!is.logical(res) || length(res) != nrow(rows)) {
        stop("filter_rows for channel '", field, "' must return one logical ",
             "per row (got ", class(res)[1L], " of length ", length(res), " for ",
             nrow(rows), " rows); a row predicate breaking its contract is a bug.",
             call. = FALSE)
    }
    res & !is.na(res)
}

# Apply a row predicate independently to each task's current target rows. Demoted
# rows stay in observations and NA predicate results are false.
.apply_row_predicate <- function(observations, filter_rows, field,
                                 mask_columns) {
    observations$row_demoted <- FALSE
    if (is.null(filter_rows)) return(observations)

    .validate_data_mask_expression(
        filter_rows, mask_columns, field, "filter_rows")
    target_rows <- which(observations$is_target)
    if (!length(target_rows)) return(observations)
    by_task <- split(target_rows, observations$task_id[target_rows])
    for (idx in by_task) {
        keep <- .eval_row_predicate(
            observations[idx, , drop = FALSE], filter_rows, field,
            mask_columns)
        observations$row_demoted[idx] <- !keep
        observations$is_target[idx] <- keep
    }
    observations
}

# Aggregate predicate: evaluate the data-masked expression on current target rows,
# separately for every task + declared level. For lab channels these are the rows
# that survived filter_rows. Failing groups are demoted in-place so observations
# retain the complete audit trail.
.apply_group_predicate <- function(observations, group_by,
                                   filter_groups, field, mask_columns) {
    observations$group_demoted <- FALSE
    if (is.null(filter_groups)) return(observations)
    if (is.null(group_by) || !group_by %in% mask_columns) {
        stop("filter_groups for channel '", field, "' groups by '",
             group_by, "', which the prepared source does not carry.",
             call. = FALSE)
    }

    .validate_data_mask_expression(
        filter_groups, mask_columns, field, "filter_groups")
    target_rows <- which(observations$is_target)
    if (!length(target_rows)) return(observations)
    group_key <- paste(observations$task_id[target_rows],
                       observations[[group_by]][target_rows], sep = "\r")
    groups <- split(target_rows, group_key)
    keep <- vapply(groups, function(idx) {
        rows <- observations[idx, , drop = FALSE]
        res <- .eval_activation_expression(
            rows, filter_groups, field, "filter_groups", mask_columns)
        if (!is.logical(res) || length(res) != 1L || is.na(res)) {
            stop("filter_groups for channel '", field,
                 "' must return exactly one TRUE/FALSE per task + ",
                 group_by, " group; a group predicate breaking its ",
                 "contract is a bug.", call. = FALSE)
        }
        res
    }, logical(1))
    demoted <- unlist(groups[!keep], use.names = FALSE)
    if (length(demoted)) {
        observations$group_demoted[demoted] <- TRUE
        observations$is_target[demoted] <- FALSE
    }
    observations
}

.overlaps_interval <- function(start, end, lo, hi,
                               missing_datsort = c("use_start", "exclude")) {
    missing_datsort <- match.arg(missing_datsort)
    end_eff <- if (identical(missing_datsort, "use_start")) {
        dplyr::coalesce(end, start)
    } else {
        end
    }
    !is.na(start) & start <= hi & end_eff >= lo
}

# Code matching for a coded channel. The code is NORMALIZED (dots/spaces stripped,
# upper-cased) before matching, so "E11.9" and "E119" are the same code.
#   - exact: normalized code is in the declared set
#   - regex: normalized code matches ANY declared pattern (e.g. "^E1[0-4]")
# No usability/shape check -- HDW codes are standardized (CIM-10 in pmsi$diag, CCAM
# in pmsi$actes), so there is no "malformed code" to route to review.
.code_matches <- function(codes, patterns, match = c("regex", "exact")) {
    match <- match.arg(match)
    ncodes <- toupper(gsub("[^A-Za-z0-9]", "", as.character(codes)))
    ok <- !is.na(ncodes) & nzchar(ncodes)
    if (identical(match, "exact")) {
        target <- toupper(gsub("[^A-Za-z0-9]", "", as.character(patterns)))
        target <- target[!is.na(target) & nzchar(target)]
        ok & ncodes %in% target
    } else {
        pats <- as.character(patterns)
        pats <- pats[!is.na(pats) & nzchar(pats)]
        hit <- rep(FALSE, length(ncodes))
        for (p in pats) hit <- hit | grepl(p, ncodes, perl = TRUE)
        ok & hit
    }
}

# --- generic code presence: a code family over a coded source ------------------
# Neutral structured executor behind the run_variable() code (CIM-10 / pmsi$diag)
# AND act (CCAM / pmsi$actes) branches. Per task it marks "present" if any code in
# the declared family is in scope for the task, "absent" if in-scope rows exist but
# none matches, with coverage / values / evidence / observation / derivation
# artifacts. The caller resolves the PHYSICAL columns from the source's roles:
# `code_col` holds the code; `start_col`/`end_col` the time interval (a point-dated
# source passes one date for both). `match` is exact (a code set) or regex. `field` /
# `source` name the output rows; `codes` is the declared family (no concept baked in).
#
# source_table: a coded source frame
#   source_row_id, PATID, EVTID, ELTID, <code_col>, <start_col>, <end_col>.
# tasks: task_id, PATID, anchor_date (anchor only when windowed).
measure_code_presence <- function(source_table, tasks, codes,
                                  match = c("regex", "exact"),
                                  filter_rows = NULL,
                                  grain_keys = "PATID",
                                  from_days = NULL, to_days = NULL,
                                  group_by = NULL, filter_groups = NULL,
                                  code_col = "diag", start_col = "DATENT",
                                  end_col = "DATSORT",
                                  missing_end = c("use_start", "exclude"),
                                  field = "code_presence", source = "diagnosis") {
    match <- match.arg(match)
    missing_end <- match.arg(missing_end)
    windowed <- !is.null(from_days) && !is.null(to_days)   # NULL window -> whole history
    # Grain is declared by the output contract (output$group_by) and passed as grain_keys by
    # the caller (run_variable): "PATID" alone scopes by subject (patient grain);
    # c("PATID","EVTID") scopes each task to its OWN stay (stay grain) -- closing the
    # DESIGN §7 executor gap ("EVTID is invariant across HDW rows"). source_counts and
    # the join both use grain_keys, so coverage is per grain unit.
    .validate_structured_inputs(
        tasks, source_table,
        unique(c("source_row_id", "PATID", "EVTID", "ELTID",
                 code_col, start_col, end_col)),
        "coded rows", require_anchor = windowed)

    source_columns <- names(source_table)
    rows <- tibble::as_tibble(source_table) %>%
        mutate(
            source_row_id = as.character(source_row_id),
            PATID = as.character(PATID),
            EVTID = as.character(EVTID),
            ELTID = as.character(ELTID),
            .ee_t_start = .clinical_date(.data[[start_col]]),
            .ee_t_end = .clinical_date(.data[[end_col]]))
    tkeys <- tasks %>%
        transmute(task_id = as.character(task_id), PATID = as.character(PATID))
    for (k in setdiff(grain_keys, "PATID")) tkeys[[k]] <- as.character(tasks[[k]])
    if (windowed) tkeys$anchor_date <- .clinical_date(tasks$anchor_date)

    source_counts <- rows %>%
        filter(!is.na(PATID)) %>%
        group_by(across(all_of(grain_keys))) %>%
        summarise(n_source_rows = n(), .groups = "drop")

    scoped <- rows %>%
        inner_join(tkeys, by = grain_keys, relationship = "many-to-many")
    if (windowed) {
        scoped <- scoped %>% filter(.overlaps_interval(
            .data$.ee_t_start, .data$.ee_t_end,
            anchor_date + from_days, anchor_date + to_days,
            missing_datsort = missing_end))
    }
    observations <- scoped %>%
        mutate(
            field = field,
            source = source,
            in_scope = TRUE,
            is_target = .code_matches(.data[[code_col]], codes, match))

    observations <- .apply_row_predicate(
        observations, filter_rows, field, source_columns)
    observations <- .apply_group_predicate(
        observations, group_by, filter_groups, field, source_columns)

    observations <- observations %>%
        mutate(
            selected_evidence = is_target,
            scope_reason = if (windowed) "in scope for the task window"
                           else "whole history (no window)",
            observation_reason = case_when(
                .data$is_target ~ "code matches the declared family",
                .data$group_demoted ~ "group aggregate predicate not satisfied",
                .data$row_demoted ~ "row predicate not satisfied",
                TRUE ~ "code outside the declared family"))

    counts <- observations %>%
        group_by(task_id) %>%
        summarise(
            n_scope_rows = n(),
            n_matching_rows = sum(is_target),
            .groups = "drop")
    coverage <- tkeys %>%
        left_join(source_counts, by = grain_keys) %>%
        left_join(counts, by = "task_id") %>%
        mutate(
            across(c(n_source_rows, n_scope_rows, n_matching_rows),
                   ~ coalesce(as.integer(.x), 0L)),
            processing_state = case_when(
                n_source_rows == 0L ~ "no_eligible_source",
                windowed & n_scope_rows == 0L ~ "no_candidate",
                TRUE ~ "measured"))

    values <- coverage %>%
        filter(processing_state == "measured") %>%
        mutate(normalized_value = if_else(n_matching_rows > 0L, "present", "absent")) %>%
        transmute(
            task_id,
            field = field,
            normalized_value,
            accepted_value = normalized_value,
            n_scope_rows,
            n_matching_rows)

    candidate_columns <- unique(c("task_id", source_columns))
    candidates <- observations %>%
        filter(is_target) %>%
        arrange(task_id, .data$.ee_t_start, source_row_id) %>%
        select(all_of(candidate_columns))

    evidence_columns <- unique(c(
        "task_id", "field", "source", "source_row_id", "evidence_ref",
        "evidence_summary", setdiff(source_columns, "source_row_id")))
    evidence <- observations %>%
        filter(selected_evidence) %>%
        mutate(
            evidence_ref = source_row_id,
            evidence_summary = sprintf(
                "%s (%s)", .data[[code_col]], .data$.ee_t_start)) %>%
        select(all_of(evidence_columns))

    rule <- if (windowed) {
        sprintf("same_subject; interval_overlap[%g,%+g]; %s match {%s}",
                from_days, to_days, match,   # %g: c(-Inf, 0) legal
                paste(codes, collapse = ","))
    } else {
        sprintf("whole_history; %s match {%s}", match, paste(codes, collapse = ","))
    }
    if (!is.null(filter_rows)) {
        rule <- sprintf("%s; rows kept when predicate holds", rule)
    }
    if (!is.null(filter_groups)) {
        rule <- sprintf("%s; group(%s) kept when predicate holds",
                        rule, group_by)
    }
    derivation <- coverage %>%
        transmute(
            task_id,
            field = field,
            rule = rule,
            n_source_rows,
            n_scope_rows,
            n_matching_rows,
            status = processing_state,
            error = NA_character_)

    .assert_evidence_resolves(evidence, observations, rows)
    list(
        coverage = coverage,
        values = values,
        candidates = candidates,
        evidence = evidence,
        observations = observations,
        derivation = derivation)
}

# --- generic document presence: metadata-selected docs_index rows ---------------
# Neutral executor behind the run_variable() doc branch: a document's EXISTENCE is
# the hit, selected on docs_index METADATA (exact any-of filters per column) -- no
# content, no Lucene, no LLM. Same present/absent membership contract as the code
# executor, so a doc hit means the same thing inside a hit-set expression. Matching
# candidates retain the full metadata row for explicit from_channel() projection.
#
# docs_index: ELTID (unique), PATID, EVTID, <date_col>, plus the filter columns.
# tasks: task_id, PATID (+ grain keys); anchor_date only when windowed.
measure_doc_presence <- function(docs_index, tasks, filters,
                                 filter_rows = NULL,
                                 grain_keys = "PATID",
                                 from_days = NULL, to_days = NULL,
                                 group_by = NULL, filter_groups = NULL,
                                 date_col = "RECDATE",
                                 field = "doc_presence", source = "documents") {
    windowed <- !is.null(from_days) && !is.null(to_days)   # NULL window -> whole history
    .require_columns(docs_index,
                     unique(c("ELTID", "PATID", "EVTID", date_col, names(filters))),
                     "docs index")

    source_columns <- names(docs_index)
    rows <- tibble::as_tibble(docs_index) %>% mutate(
        source_row_id = as.character(ELTID),
        PATID = as.character(PATID),
        EVTID = as.character(EVTID),
        ELTID = as.character(ELTID),
        .ee_doc_date = .clinical_date(.data[[date_col]]))
    .validate_structured_inputs(
        tasks, rows,
        c("source_row_id", "PATID", "EVTID", "ELTID", ".ee_doc_date"),
        "docs index", require_anchor = windowed)

    tkeys <- tasks %>%
        transmute(task_id = as.character(task_id), PATID = as.character(PATID))
    for (k in setdiff(grain_keys, "PATID")) tkeys[[k]] <- as.character(tasks[[k]])
    if (windowed) tkeys$anchor_date <- .clinical_date(tasks$anchor_date)

    source_counts <- rows %>%
        filter(!is.na(PATID)) %>%
        group_by(across(all_of(grain_keys))) %>%
        summarise(n_source_rows = n(), .groups = "drop")

    scoped <- rows %>%
        inner_join(tkeys, by = grain_keys, relationship = "many-to-many")
    if (windowed) {
        scoped <- scoped %>% filter(.within_point(
            .data$.ee_doc_date,
            anchor_date + from_days, anchor_date + to_days))
    }
    matches <- rep(TRUE, nrow(scoped))
    for (cl in names(filters)) {
        matches <- matches & (as.character(scoped[[cl]]) %in% filters[[cl]])
    }
    observations <- scoped %>%
        mutate(
            field = field,
            source = source,
            in_scope = TRUE,
            is_target = matches & !is.na(matches))

    observations <- .apply_row_predicate(
        observations, filter_rows, field, source_columns)
    observations <- .apply_group_predicate(
        observations, group_by, filter_groups, field, source_columns)

    observations <- observations %>%
        mutate(
            selected_evidence = is_target,
            scope_reason = if (windowed) "in scope for the task window"
                           else "whole history (no window)",
            observation_reason = case_when(
                .data$is_target ~ "document metadata matches the declared filters",
                .data$group_demoted ~ "group aggregate predicate not satisfied",
                .data$row_demoted ~ "row predicate not satisfied",
                TRUE ~ "document metadata outside the declared filters"))

    counts <- observations %>%
        group_by(task_id) %>%
        summarise(
            n_scope_rows = n(),
            n_matching_rows = sum(is_target),
            .groups = "drop")
    coverage <- tkeys %>%
        left_join(source_counts, by = grain_keys) %>%
        left_join(counts, by = "task_id") %>%
        mutate(
            across(c(n_source_rows, n_scope_rows, n_matching_rows),
                   ~ coalesce(as.integer(.x), 0L)),
            processing_state = case_when(
                n_source_rows == 0L ~ "no_eligible_source",
                windowed & n_scope_rows == 0L ~ "no_candidate",
                TRUE ~ "measured"))

    values <- coverage %>%
        filter(processing_state == "measured") %>%
        mutate(normalized_value = if_else(n_matching_rows > 0L, "present", "absent")) %>%
        transmute(
            task_id,
            field = field,
            normalized_value,
            accepted_value = normalized_value,
            n_scope_rows,
            n_matching_rows)

    filter_txt <- paste(vapply(names(filters), function(cl) {
        sprintf("%s in {%s}", cl, paste(filters[[cl]], collapse = ","))
    }, character(1)), collapse = "; ")

    candidate_columns <- unique(c(
        "task_id", "source_row_id", source_columns))
    candidates <- observations %>%
        filter(is_target) %>%
        arrange(task_id, .data$.ee_doc_date, source_row_id) %>%
        select(all_of(candidate_columns))

    evidence_columns <- unique(c(
        "task_id", "field", "source", "source_row_id", "evidence_ref",
        "evidence_summary", source_columns))
    evidence <- observations %>%
        filter(selected_evidence) %>%
        mutate(
            evidence_ref = source_row_id,
            evidence_summary = sprintf(
                "%s (%s)", filter_txt, .data$.ee_doc_date)) %>%
        select(all_of(evidence_columns))

    rule <- if (windowed) {
        sprintf("same_subject; point_window[%g,%+g]; %s", from_days, to_days,
                filter_txt)
    } else {
        sprintf("whole_history; %s", filter_txt)
    }
    if (!is.null(filter_rows)) {
        rule <- sprintf("%s; rows kept when predicate holds", rule)
    }
    if (!is.null(filter_groups)) {
        rule <- sprintf("%s; group(%s) kept when predicate holds",
                        rule, group_by)
    }
    derivation <- coverage %>%
        transmute(
            task_id,
            field = field,
            rule = rule,
            n_source_rows,
            n_scope_rows,
            n_matching_rows,
            status = processing_state,
            error = NA_character_)

    .assert_evidence_resolves(evidence, observations, rows)
    list(
        coverage = coverage,
        values = values,
        candidates = candidates,
        evidence = evidence,
        observations = observations,
        derivation = derivation)
}

# --- generic analyte candidates: selected prepared rows in a point-window -------
# The lab executor selects rows by the source's analyte role only. NUMRES, STRRES,
# DATEXAM, identifiers, units, qualifiers and role-less predicate columns remain
# ordinary prepared-source columns; `from_channel(value =)` evaluates its payload
# expression downstream. A row may therefore carry either, both, or neither result
# column.
#
# filter_rows is evaluated on analyte matches separately for each task after grain and
# window scoping. filter_groups then sees the surviving rows in each task + group_by
# group. Both filters demote rows in observations without stripping source payload.
measure_analyte_values <- function(source_table, tasks, analytes,
                                   filter_rows = NULL,
                                   grain_keys = "PATID",
                                   from_days = -7L, to_days = 7L,
                                   group_by = NULL, filter_groups = NULL,
                                   result_id_col = "BIOL_ID",
                                   date_col = "DATEXAM",
                                   analyte_col = "TYPEANA",
                                   field = "analyte", source = "biology") {
    windowed <- !is.null(from_days) && !is.null(to_days)   # NULL window -> event scope
    .validate_structured_inputs(
        tasks, source_table,
        unique(c("source_row_id", "PATID", "EVTID", "ELTID",
                 date_col, analyte_col)),
        "biology rows", require_anchor = windowed)

    # Preserve the complete prepared row. Only identifier/date role columns are
    # normalized for joins and window arithmetic; result columns are never inferred
    # or collapsed into a synthetic `value` lane.
    biol <- tibble::as_tibble(source_table)
    source_columns <- names(biol)
    # The native exam identifier is optional provenance. `source_row_id` is the
    # execution coordinate for each prepared result row.
    id_columns <- intersect(
        unique(c("source_row_id", "PATID", "EVTID", "ELTID", result_id_col)),
        names(biol))
    for (column in id_columns) {
        biol[[column]] <- as.character(biol[[column]])
    }
    biol$.ee_point_date <- .clinical_date(biol[[date_col]])
    biol$.ee_analyte <- as.character(biol[[analyte_col]])


    # Grain is declared by the variable and carried by the task universe.
    tkeys <- tasks %>%
        transmute(task_id = as.character(task_id), PATID = as.character(PATID))
    for (key in setdiff(grain_keys, "PATID")) {
        tkeys[[key]] <- as.character(tasks[[key]])
    }
    if (windowed) tkeys$anchor_date <- .clinical_date(tasks$anchor_date)
    target_analytes <- toupper(trimws(as.character(analytes)))

    source_counts <- biol %>%
        filter(!is.na(PATID)) %>%
        group_by(across(all_of(grain_keys))) %>%
        summarise(n_source_rows = n(), .groups = "drop")

    scoped <- biol %>%
        inner_join(tkeys, by = grain_keys, relationship = "many-to-many")
    if (windowed) {
        scoped <- scoped %>%
            filter(.within_point(.data$.ee_point_date,
                                 anchor_date + from_days,
                                 anchor_date + to_days))
    }
    observations <- scoped %>%
        mutate(field = field, source = source, in_scope = TRUE)
    analyte_match <- !is.na(observations$.ee_analyte) &
        toupper(trimws(observations$.ee_analyte)) %in% target_analytes

    observations$is_target <- analyte_match
    observations <- .apply_row_predicate(
        observations, filter_rows, field, source_columns)
    observations <- .apply_group_predicate(
        observations, group_by, filter_groups, field, source_columns)
    observations <- observations %>%
        mutate(
            selected_evidence = is_target,
            scope_reason = if (windowed) "point time inside the task window"
                           else "same grain unit (no window)",
            observation_reason = case_when(
                .data$is_target ~ "analyte matches the declared concept",
                .data$group_demoted ~ "group aggregate predicate not satisfied",
                .data$row_demoted ~ "row predicate not satisfied",
                analyte_match ~ "analyte match demoted by activation rules",
                TRUE ~ "analyte outside the declared concept"))

    counts <- observations %>%
        group_by(task_id) %>%
        summarise(
            n_scope_rows = n(),
            n_candidate_rows = sum(is_target),
            .groups = "drop")

    coverage <- tkeys %>%
        left_join(source_counts, by = grain_keys) %>%
        left_join(counts, by = "task_id") %>%
        mutate(
            across(c(n_source_rows, n_scope_rows, n_candidate_rows),
                   ~ coalesce(as.integer(.x), 0L)),
            processing_state = case_when(
                n_source_rows == 0L ~ "no_eligible_source",
                n_candidate_rows == 0L ~ "no_candidate",
                TRUE ~ "measured"))

    # Membership face (bin_output / combine): a task is present iff at least one
    # analyte row survives the activation filters.
    values <- coverage %>%
        filter(processing_state == "measured") %>%
        mutate(normalized_value = if_else(n_candidate_rows > 0L,
                                          "present", "absent")) %>%
        transmute(
            task_id,
            field = field,
            normalized_value,
            accepted_value = normalized_value,
            n_scope_rows,
            n_candidate_rows)

    # Candidates are task identity + the complete prepared source row. Reducers and
    # projections consume real column names rather than a hidden `value` alias.
    candidate_columns <- unique(c("task_id", source_columns))
    candidates <- observations %>%
        filter(is_target) %>%
        arrange(task_id, .data$.ee_point_date, source_row_id) %>%
        select(all_of(candidate_columns))

    # Evidence uses the same complete row and adds only stable engine provenance.
    evidence_columns <- unique(c(
        "task_id", "field", "source", "source_row_id", "evidence_ref",
        "evidence_summary", setdiff(source_columns, "source_row_id")))
    evidence <- observations %>%
        filter(selected_evidence) %>%
        mutate(
            evidence_ref = source_row_id,
            evidence_summary = sprintf(
                "%s on %s", .data$.ee_analyte, .data$.ee_point_date)) %>%
        select(all_of(evidence_columns))

    filter_txt <- paste0(
        if (!is.null(filter_rows)) {
            sprintf("row kept when %s; ", .one_line(filter_rows))
        } else "",
        if (!is.null(filter_groups)) {
            sprintf("group(%s) kept when %s; ", group_by,
                    .one_line(filter_groups))
        } else "")
    scope_txt <- paste(grain_keys, collapse = "+")
    window_txt <- if (windowed) {
        sprintf("point_window[%g,%+g]; ", from_days, to_days)
    } else {
        "event_scope (no window); "
    }
    rule <- sprintf(
        paste0("grain=%s; %sanalyte=%s; %s",
               "candidates preserve complete prepared-source rows"),
        scope_txt, window_txt, paste(analytes, collapse = ","), filter_txt)
    derivation <- coverage %>%
        transmute(
            task_id,
            field = field,
            rule = rule,
            n_source_rows,
            n_scope_rows,
            n_candidate_rows,
            status = processing_state,
            error = NA_character_)

    .assert_evidence_resolves(evidence, observations, biol)
    list(
        coverage = coverage,
        values = values,
        candidates = candidates,
        evidence = evidence,
        observations = observations,
        derivation = derivation)
}
