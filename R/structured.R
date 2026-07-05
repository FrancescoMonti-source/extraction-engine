# =============================================================================
# structured.R — deterministic (non-LLM) extraction path for STRUCTURED sources
# -----------------------------------------------------------------------------
# Mirrors the text path's four views but: evidence = selected source rows,
# measurement = a deterministic rule, NO corpus and NO model. NEUTRAL, concept-
# agnostic executors only: measure_code_presence (code/act membership) and
# measure_analyte_values (valued rows of an analyte in a window -- reduction is a
# plain function on the variable's channel activation, applied in assembly); the
# run_variable() dispatch binds each to its source. Coverage census is kept over ALL
# tasks, same discipline as the text path. Provenance points at the exact source rows.
# =============================================================================

suppressWarnings(suppressMessages(library(dplyr)))

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
    as.Date(x)
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

# Value predicate for a thresholded analyte selector (DESIGN §8): strict cutoffs,
# `gt` above and/or `lt` below. A missing value never passes; NULL bounds leave the
# value unconstrained on that side.
.passes_threshold <- function(value, gt, lt = NULL) {
    ok <- !is.na(value)
    if (!is.null(gt)) ok <- ok & value > gt
    if (!is.null(lt)) ok <- ok & value < lt
    ok
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
                                  grain_keys = "PATID",
                                  from_days = NULL, to_days = NULL,
                                  code_col = "diag", start_col = "DATENT",
                                  end_col = "DATSORT",
                                  missing_end = c("use_start", "exclude"),
                                  field = "code_presence", source = "diagnosis") {
    match <- match.arg(match)
    missing_end <- match.arg(missing_end)
    windowed <- !is.null(from_days) && !is.null(to_days)   # NULL window -> whole history
    # Grain is DECLARED by the variable (output_one_row_per) and passed as grain_keys by
    # the caller (run_variable): "PATID" alone scopes by subject (patient grain);
    # c("PATID","EVTID") scopes each task to its OWN stay (stay grain) -- closing the
    # DESIGN §7 executor gap ("EVTID is invariant across HDW rows"). source_counts and
    # the join both use grain_keys, so coverage is per grain unit.
    .validate_structured_inputs(
        tasks, source_table,
        unique(c("source_row_id", "PATID", "EVTID", "ELTID",
                 code_col, start_col, end_col)),
        "coded rows", require_anchor = windowed)

    rows <- source_table %>% transmute(
        source_row_id = as.character(source_row_id),
        PATID = as.character(PATID),
        EVTID = as.character(EVTID),
        ELTID = as.character(ELTID),
        code = as.character(.data[[code_col]]),
        t_start = .clinical_date(.data[[start_col]]),
        t_end = .clinical_date(.data[[end_col]]))
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
            t_start, t_end, anchor_date + from_days, anchor_date + to_days,
            missing_datsort = missing_end))
    }
    observations <- scoped %>%
        mutate(
            field = field,
            source = source,
            in_scope = TRUE,
            is_target = .code_matches(code, codes, match),
            selected_evidence = is_target,
            scope_reason = if (windowed) "in scope for the task window"
                           else "whole history (no window)",
            observation_reason = if_else(is_target,
                "code matches the declared family",
                "code outside the declared family"))

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
            measurement_value = NA_real_,
            measurement_time = as.Date(NA),
            n_scope_rows,
            n_matching_rows)

    evidence <- observations %>%
        filter(selected_evidence) %>%
        transmute(
            task_id, field, source, source_row_id,
            evidence_ref = source_row_id,
            evidence_summary = sprintf("%s (%s)", code, t_start),
            PATID, EVTID, ELTID, code, t_start, t_end)

    rule <- if (windowed) {
        sprintf("same_subject; interval_overlap[%d,%+d]; %s match {%s}",
                as.integer(from_days), as.integer(to_days), match,
                paste(codes, collapse = ","))
    } else {
        sprintf("whole_history; %s match {%s}", match, paste(codes, collapse = ","))
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

    # No candidates frame: a coded/act row's payload value IS its code, which already
    # rides `evidence` (one row per matching source row) -- the payload path
    # (.payload_values) reads it there, and a count is reduce = length over the codes.
    .assert_evidence_resolves(evidence, observations, rows)
    list(
        coverage = coverage,
        values = values,
        evidence = evidence,
        observations = observations,
        derivation = derivation)
}

# --- generic analyte candidates: valued rows of an analyte in a point-window -----
# Neutral lab/analyte executor behind the run_variable() lab branch, serving BOTH lab
# faces (DESIGN §8). Per task it SCOPES the declared analyte's rows to a point-window
# around the anchor. A thresholded selector (analyte_value(gt/lt)) folds a value
# predicate into the target set, so the target rows are the measurements past the
# threshold. It returns those targets two ways: as CANDIDATES (source_row_id + numeric
# value) for the VALUE face, and as a present/absent `values` frame for the MEMBERSHIP
# face (bin_output / combine) -- it does NOT reduce the value face itself.
# The reduction is a plain function on the value vector, supplied on the variable's
# OUTPUT (num_output(values_from =, reduce = function(x) max(x, na.rm = TRUE)),
# DESIGN §8) and applied downstream in assembly; a bespoke "max" executor /
# max_value() operator would be ad-hoc for a one-line base reduction. No usability/validity check:
# HDW numeric results live in a numeric field (NUMRES; qualitative results are STRRES,
# which BIOL_SOURCE does not read), so a target row always has a value. Evidence =
# every candidate row (the inputs to the reduction), so provenance shows the whole
# window the number was reduced from, whatever the reducer.
#
# source_table: normalized result rows
#   source_row_id, PATID, EVTID, ELTID, BIOL_ID, DATEXAM, analyte, value, value_raw.
# tasks: task_id + the grain_keys columns (PATID, or PATID+EVTID for stay grain);
#   anchor_date only when windowed (a NULL window is event-scoped, no anchor needed).
measure_analyte_values <- function(source_table, tasks, analytes,
                                   gt = NULL, lt = NULL, grain_keys = "PATID",
                                   from_days = -7L, to_days = 7L,
                                   field = "analyte_value", source = "biology") {
    windowed <- !is.null(from_days) && !is.null(to_days)   # NULL window -> event scope
    .validate_structured_inputs(
        tasks, source_table,
        c("source_row_id", "PATID", "EVTID", "ELTID", "BIOL_ID", "DATEXAM",
          "analyte", "value", "value_raw"),
        "biology rows", require_anchor = windowed)

    biol <- source_table %>% transmute(
        source_row_id = as.character(source_row_id),
        PATID = as.character(PATID),
        EVTID = as.character(EVTID),
        ELTID = as.character(ELTID),
        BIOL_ID = as.character(BIOL_ID),
        DATEXAM = .clinical_date(DATEXAM),
        analyte = as.character(analyte),
        value = suppressWarnings(as.numeric(value)),
        value_raw = as.character(value_raw))
    # Grain is DECLARED by the variable (output_one_row_per) and passed as grain_keys:
    # "PATID" scopes by subject; c("PATID","EVTID") scopes each task to its OWN stay
    # (stay grain), the DESIGN §7 executor gap ("EVTID is invariant across HDW rows").
    tkeys <- tasks %>%
        transmute(task_id = as.character(task_id), PATID = as.character(PATID))
    for (k in setdiff(grain_keys, "PATID")) tkeys[[k]] <- as.character(tasks[[k]])
    if (windowed) tkeys$anchor_date <- .clinical_date(tasks$anchor_date)
    target_analytes <- toupper(trimws(as.character(analytes)))

    source_counts <- biol %>%
        filter(!is.na(PATID)) %>%
        group_by(across(all_of(grain_keys))) %>%
        summarise(n_source_rows = n(), .groups = "drop")

    scoped <- biol %>%
        inner_join(tkeys, by = grain_keys, relationship = "many-to-many")
    if (windowed) {
        scoped <- scoped %>% filter(.within_point(
            DATEXAM, anchor_date + from_days, anchor_date + to_days))
    }
    observations <- scoped %>%
        mutate(
            field = field,
            source = source,
            in_scope = TRUE,
            is_target = !is.na(analyte) &
                toupper(trimws(analyte)) %in% target_analytes &
                .passes_threshold(value, gt, lt),
            selected_evidence = is_target,     # every candidate is evidence
            scope_reason = if (windowed) "point time inside the task window"
                           else "same grain unit (no window)",
            observation_reason = if_else(is_target,
                "analyte matches the declared concept",
                "analyte outside the declared concept"),
            # Non-target rows establish source/scope coverage; their unrelated
            # result values are unnecessary in persisted structured artifacts.
            value_raw = if_else(is_target, value_raw, NA_character_),
            value = if_else(is_target, value, NA_real_))

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
            across(
                c(n_source_rows, n_scope_rows, n_candidate_rows),
                ~ coalesce(as.integer(.x), 0L)),
            processing_state = case_when(
                n_source_rows == 0L ~ "no_eligible_source",
                n_candidate_rows == 0L ~ "no_candidate",
                TRUE ~ "measured"))

    # Membership face (bin_output / combine): a task is "present" iff it has >=1
    # thresholded candidate. A subject with in-scope measurements but none past the
    # threshold is no_candidate -> the assembler reads that as an observed FALSE
    # (complete coverage); a subject with no biology at all is no_eligible_source
    # -> unevaluable (NA / partial). Same present/absent contract as the code executor,
    # so a lab hit means the same thing as a code hit inside a hit-set expression.
    values <- coverage %>%
        filter(processing_state == "measured") %>%
        mutate(normalized_value = if_else(n_candidate_rows > 0L, "present", "absent")) %>%
        transmute(
            task_id,
            field = field,
            normalized_value,
            accepted_value = normalized_value,
            n_scope_rows,
            n_candidate_rows)

    # The value vector the output's reduce collapses to one number, ordered so the
    # assembler can carry a stable measurement_time alongside the reduced value.
    # Candidates keep the identity spine: a sub-output-grain gate (combine_at_level,
    # DESIGN §7) scopes the payload to qualifying keys by joining on these columns.
    candidates <- observations %>%
        filter(is_target) %>%
        arrange(task_id, desc(value), DATEXAM, source_row_id) %>%
        transmute(task_id, source_row_id, PATID, EVTID, ELTID,
                  value, measurement_time = DATEXAM)

    evidence <- observations %>%
        filter(selected_evidence) %>%
        transmute(
            task_id, field, source, source_row_id,
            evidence_ref = source_row_id,
            evidence_summary = sprintf(
                "%s = %s on %s", analyte,
                ifelse(is.na(value_raw) | !nzchar(value_raw), value, value_raw),
                DATEXAM),
            PATID, EVTID, ELTID, BIOL_ID, DATEXAM, analyte, value, value_raw)

    threshold_txt <- paste0(
        if (!is.null(gt)) sprintf("value>%g; ", gt) else "",
        if (!is.null(lt)) sprintf("value<%g; ", lt) else "")
    scope_txt <- paste(grain_keys, collapse = "+")
    window_txt <- if (windowed) {
        sprintf("point_window[%d,%+d]; ", as.integer(from_days), as.integer(to_days))
    } else {
        "event_scope (no window); "
    }
    rule <- sprintf(
        paste0(
            "grain=%s; %sanalyte=%s; %s",
            "candidates reduced by the output's reduce function; unit ignored"),
        scope_txt, window_txt, paste(analytes, collapse = ","), threshold_txt)
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
