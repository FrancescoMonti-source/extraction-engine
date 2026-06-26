# =============================================================================
# structured.R — deterministic (non-LLM) extraction path for STRUCTURED sources
# -----------------------------------------------------------------------------
# Mirrors the text path's four views but: evidence = selected source rows,
# measurement = a deterministic rule, NO corpus and NO model. NEUTRAL execution
# machinery only (measure_code_presence[_ever] / measure_analyte_value); the
# clinically-named callers (measure_diabetes, measure_hyperkalaemia) live beside
# their concepts. Coverage census is kept over ALL tasks, same discipline as the
# text path. Provenance points at the exact source rows.
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

.validate_structured_inputs <- function(tasks, source_rows, source_required, source_label) {
    .require_columns(tasks, c("task_id", "PATID", "anchor_date"), "tasks")
    .require_columns(source_rows, source_required, source_label)

    task_ids <- as.character(tasks$task_id)
    source_ids <- as.character(source_rows$source_row_id)
    if (anyNA(task_ids) || any(!nzchar(task_ids)) || anyDuplicated(task_ids)) {
        stop("tasks$task_id must be non-missing and unique", call. = FALSE)
    }
    if (anyNA(tasks$PATID) || any(!nzchar(as.character(tasks$PATID)))) {
        stop("tasks$PATID must be non-missing", call. = FALSE)
    }
    if (anyNA(tasks$anchor_date)) {
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

.structured_execution_error <- function(tasks, field, measure_name, error) {
    coverage <- tasks %>%
        mutate(
            n_source_rows = NA_integer_,
            n_scope_rows = NA_integer_,
            processing_state = "processing_error")
    values <- tibble::tibble(
        task_id = character(), field = character(),
        normalized_value = character(), accepted_value = character(),
        measurement_value = double(), measurement_time = as.Date(character()),
        field_validity = character(), validity_reason = character())
    evidence <- tibble::tibble(
        task_id = character(), field = character(), source = character(),
        source_row_id = character(), evidence_ref = character(),
        evidence_summary = character())
    derivation <- tasks %>%
        transmute(
            task_id,
            field = field,
            rule = paste0("execution:", measure_name),
            n_source_rows = NA_integer_,
            n_scope_rows = NA_integer_,
            status = "processing_error",
            error = error)
    list(
        coverage = coverage, values = values, evidence = evidence,
        observations = tibble::tibble(), derivation = derivation)
}

# Production wrapper: programming/data-shape failures remain visible as a
# complete derivation census rather than disappearing with an aborted script.
run_structured_measurement <- function(measure, source_rows, tasks, ..., field) {
    measure_name <- deparse(substitute(measure))
    tryCatch(
        measure(source_rows, tasks, ...),
        error = function(e) {
            .structured_execution_error(
                tasks, field, measure_name, conditionMessage(e))
        })
}

# --- scope helpers (point / interval) ----------------------------------------

.within_point <- function(t, lo, hi) !is.na(t) & t >= lo & t <= hi

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

# ICD-10 family membership by code prefix (E11 matches E11, E11.9, E119, ...).
code_in_family <- function(codes, families) {
    norm <- function(x) toupper(gsub("[^A-Za-z0-9]", "", as.character(x)))
    fam <- norm(families)
    fam <- fam[!is.na(fam) & nzchar(fam)]
    vapply(norm(codes), function(code) {
        !is.na(code) && nzchar(code) && length(fam) && any(startsWith(code, fam))
    }, logical(1))
}

.usable_icd10_code <- function(codes) {
    normalized <- toupper(gsub("[^A-Za-z0-9]", "", as.character(codes)))
    !is.na(normalized) & grepl("^[A-Z][0-9]{2}[A-Z0-9]{0,4}$", normalized)
}

# --- generic code presence: ICD-10 family over pmsi$diag (interval time) -------
# Neutral structured executor: the generic core behind the clinically-named caller
# (measure_diabetes) and the run_variable() code branch. Per task it marks "present"
# if any usable ICD-10 code in the declared family overlaps the anchor window, "absent"
# if in-scope rows exist but none matches, with full coverage / values / evidence /
# observation / derivation artifacts. `field`/`source` name the output rows; `codes`
# is the declared family (required -- no concept baked in).
#
# diag: pmsi$diag rows
#   source_row_id, PATID, EVTID, ELTID, diag, DATENT, DATSORT.
# tasks: task_id, PATID, anchor_date.
measure_code_presence <- function(diag, tasks, codes,
                                  from_days = -1825L, to_days = 7L,
                                  missing_datsort = c("use_start", "exclude"),
                                  field = "code_presence", source = "diagnosis") {
    missing_datsort <- match.arg(missing_datsort)
    .validate_structured_inputs(
        tasks, diag,
        c("source_row_id", "PATID", "EVTID", "ELTID", "diag", "DATENT", "DATSORT"),
        "diagnosis rows")

    diag <- diag %>% transmute(
        source_row_id = as.character(source_row_id),
        PATID = as.character(PATID),
        EVTID = as.character(EVTID),
        ELTID = as.character(ELTID),
        diag = as.character(diag),
        DATENT = .clinical_date(DATENT),
        DATSORT = .clinical_date(DATSORT))
    tkeys <- tasks %>% transmute(
        task_id = as.character(task_id),
        PATID = as.character(PATID),
        anchor_date = .clinical_date(anchor_date))

    source_counts <- diag %>%
        filter(!is.na(PATID)) %>%
        count(PATID, name = "n_source_rows")
    missing_end_counts <- diag %>%
        filter(!is.na(PATID), is.na(DATSORT)) %>%
        count(PATID, name = "n_missing_datsort")

    observations <- diag %>%
        inner_join(tkeys, by = "PATID", relationship = "many-to-many") %>%
        filter(.overlaps_interval(
            DATENT, DATSORT, anchor_date + from_days, anchor_date + to_days,
            missing_datsort = missing_datsort)) %>%
        mutate(
            field = field,
            source = source,
            in_scope = TRUE,
            usable = .usable_icd10_code(diag),
            invalid = !usable,
            is_target = usable & code_in_family(diag, codes),
            selected_evidence = is_target,
            scope_reason = if_else(
                is.na(DATSORT),
                "interval overlap; missing DATSORT handled with use_start",
                "interval overlap"),
            observation_reason = case_when(
                is_target ~ "ICD-10 code matches the declared family",
                !usable ~ "malformed or missing ICD-10 code; excluded",
                TRUE ~ "diagnosis code outside the declared family"))

    counts <- observations %>%
        group_by(task_id) %>%
        summarise(
            n_scope_rows = n(),
            n_usable = sum(usable),
            n_unusable = sum(invalid),
            n_matching_rows = sum(is_target),
            .groups = "drop")
    coverage <- tkeys %>%
        left_join(source_counts, by = "PATID") %>%
        left_join(missing_end_counts, by = "PATID") %>%
        left_join(counts, by = "task_id") %>%
        mutate(
            across(c(n_source_rows, n_missing_datsort, n_scope_rows, n_usable,
                     n_unusable, n_matching_rows),
                   ~ coalesce(as.integer(.x), 0L)),
            processing_state = case_when(
                n_source_rows == 0L ~ "no_eligible_source",
                n_scope_rows == 0L ~ "no_candidate",
                n_usable == 0L ~ "invalid",
                TRUE ~ "measured"))

    values <- coverage %>%
        filter(processing_state %in% c("measured", "invalid")) %>%
        mutate(normalized_value = case_when(
            processing_state == "invalid" ~ NA_character_,
            n_matching_rows > 0L ~ "present",
            TRUE ~ "absent")) %>%
        transmute(
            task_id,
            field = field,
            normalized_value,
            accepted_value = if_else(
                processing_state == "measured", normalized_value, NA_character_),
            measurement_value = NA_real_,
            measurement_time = as.Date(NA),
            field_validity = if_else(
                processing_state == "measured", "valid", "invalid"),
            validity_reason = if_else(
                processing_state == "measured", "",
                "diagnosis rows are in scope but none has a usable ICD-10 code"),
            n_scope_rows,
            n_usable,
            n_unusable,
            n_matching_rows)

    evidence <- observations %>%
        filter(selected_evidence) %>%
        transmute(
            task_id, field, source, source_row_id,
            evidence_ref = source_row_id,
            evidence_summary = sprintf(
                "%s (%s to %s)", diag, DATENT,
                ifelse(is.na(DATSORT), "missing", as.character(DATSORT))),
            PATID, EVTID, ELTID, diag, DATENT, DATSORT)

    rule <- sprintf(
        "same_subject; interval_overlap[%d,%+d]; ICD-10 prefixes %s; missing_DATSORT=%s",
        as.integer(from_days), as.integer(to_days), paste(codes, collapse = ","),
        missing_datsort)
    derivation <- coverage %>%
        transmute(
            task_id,
            field = field,
            rule = rule,
            n_source_rows,
            n_scope_rows,
            n_usable,
            n_unusable,
            n_matching_rows,
            status = processing_state,
            error = NA_character_)

    .assert_evidence_resolves(evidence, observations, diag)
    list(
        coverage = coverage,
        values = values,
        evidence = evidence,
        observations = observations,
        derivation = derivation)
}

# --- whole-history ("ever") code presence ------------------------------------
# No anchor, no window: scope is the subject's ENTIRE available record. Sibling of
# measure_code_presence() for unanchored variables (e.g. diabetes_ever). present if any
# usable code matches the family anywhere in the record; absent if rows exist but none
# match; no_eligible_source if the subject has no rows. tasks need only task_id + PATID
# (no anchor_date). `codes`/`field`/`source` mirror measure_code_presence(); same output
# contract.
measure_code_presence_ever <- function(diag, tasks, codes,
                                       field = "code_presence", source = "diagnosis") {
    .require_columns(tasks, c("task_id", "PATID"), "tasks")
    .require_columns(
        diag,
        c("source_row_id", "PATID", "EVTID", "ELTID", "diag", "DATENT", "DATSORT"),
        "diagnosis rows")
    task_ids <- as.character(tasks$task_id)
    if (anyNA(task_ids) || any(!nzchar(task_ids)) || anyDuplicated(task_ids)) {
        stop("tasks$task_id must be non-missing and unique", call. = FALSE)
    }
    source_ids <- as.character(diag$source_row_id)
    if (anyNA(source_ids) || any(!nzchar(source_ids)) || anyDuplicated(source_ids)) {
        stop("diagnosis rows$source_row_id must be non-missing and unique",
             call. = FALSE)
    }

    diag <- diag %>% transmute(
        source_row_id = as.character(source_row_id),
        PATID = as.character(PATID), EVTID = as.character(EVTID),
        ELTID = as.character(ELTID), diag = as.character(diag),
        DATENT = .clinical_date(DATENT), DATSORT = .clinical_date(DATSORT))
    tkeys <- tasks %>%
        transmute(task_id = as.character(task_id), PATID = as.character(PATID))

    source_counts <- diag %>%
        filter(!is.na(PATID)) %>% count(PATID, name = "n_source_rows")
    observations <- diag %>%
        inner_join(tkeys, by = "PATID", relationship = "many-to-many") %>%
        mutate(
            field = field, source = source, in_scope = TRUE,
            usable = .usable_icd10_code(diag), invalid = !usable,
            is_target = usable & code_in_family(diag, codes),
            selected_evidence = is_target,
            scope_reason = "whole history (no window)",
            observation_reason = case_when(
                is_target ~ "ICD-10 code matches the declared family (whole history)",
                !usable ~ "malformed or missing ICD-10 code; excluded",
                TRUE ~ "diagnosis code outside the declared family"))

    counts <- observations %>%
        group_by(task_id) %>%
        summarise(n_scope_rows = n(), n_usable = sum(usable),
                  n_unusable = sum(invalid), n_matching_rows = sum(is_target),
                  .groups = "drop")
    coverage <- tkeys %>%
        left_join(source_counts, by = "PATID") %>%
        left_join(counts, by = "task_id") %>%
        mutate(
            across(c(n_source_rows, n_scope_rows, n_usable, n_unusable,
                     n_matching_rows), ~ coalesce(as.integer(.x), 0L)),
            processing_state = case_when(
                n_source_rows == 0L ~ "no_eligible_source",
                n_usable == 0L ~ "invalid",
                TRUE ~ "measured"))

    values <- coverage %>%
        filter(processing_state %in% c("measured", "invalid")) %>%
        mutate(normalized_value = case_when(
            processing_state == "invalid" ~ NA_character_,
            n_matching_rows > 0L ~ "present", TRUE ~ "absent")) %>%
        transmute(
            task_id, field = field, normalized_value,
            accepted_value = if_else(
                processing_state == "measured", normalized_value, NA_character_),
            field_validity = if_else(
                processing_state == "measured", "valid", "invalid"),
            validity_reason = if_else(
                processing_state == "measured", "",
                "diagnosis rows exist but none has a usable ICD-10 code"),
            n_scope_rows, n_usable, n_unusable, n_matching_rows)

    evidence <- observations %>%
        filter(selected_evidence) %>%
        transmute(
            task_id, field, source, source_row_id, evidence_ref = source_row_id,
            evidence_summary = sprintf(
                "%s (%s to %s)", diag, DATENT,
                ifelse(is.na(DATSORT), "missing", as.character(DATSORT))),
            PATID, EVTID, ELTID, diag, DATENT, DATSORT)

    derivation <- coverage %>%
        transmute(
            task_id, field = field,
            rule = sprintf("whole_history; ICD-10 prefixes %s",
                           paste(codes, collapse = ",")),
            n_source_rows, n_scope_rows, n_usable, n_unusable, n_matching_rows,
            status = processing_state, error = NA_character_)

    .assert_evidence_resolves(evidence, observations, diag)
    list(coverage = coverage, values = values, evidence = evidence,
         observations = observations, derivation = derivation)
}

# --- generic analyte value: max usable value in a point-window over biol --------
# Neutral lab/analyte executor: the generic core behind the clinically-named callers
# (hyperkalaemia, diabetes glucose) and the run_variable() lab branch. Per task it
# selects the MAXIMUM usable value of the declared analyte concept inside a point-
# window around the anchor, with full coverage / values / evidence / observation /
# derivation artifacts. `field` and `source` name the output rows. `threshold` is
# OPTIONAL: NA (a pure numeric max_value variable) applies NO present/absent
# interpretation and lets measurement_value carry the result; a supplied threshold
# (e.g. hyperkalaemia 5.0) marks value > threshold as "present".
#
# biol: normalized result rows
#   source_row_id, PATID, EVTID, ELTID, BIOL_ID, DATEXAM, analyte, value, value_raw.
# tasks: task_id, PATID, anchor_date.
measure_analyte_value <- function(biol, tasks, analytes, threshold = NA_real_,
                                  from_days = -7L, to_days = 7L,
                                  field = "analyte_value", source = "biology") {
    .validate_structured_inputs(
        tasks, biol,
        c("source_row_id", "PATID", "EVTID", "ELTID", "BIOL_ID", "DATEXAM",
          "analyte", "value", "value_raw"),
        "biology rows")

    biol <- biol %>% transmute(
        source_row_id = as.character(source_row_id),
        PATID = as.character(PATID),
        EVTID = as.character(EVTID),
        ELTID = as.character(ELTID),
        BIOL_ID = as.character(BIOL_ID),
        DATEXAM = .clinical_date(DATEXAM),
        analyte = as.character(analyte),
        value = suppressWarnings(as.numeric(value)),
        value_raw = as.character(value_raw))
    tkeys <- tasks %>% transmute(
        task_id = as.character(task_id),
        PATID = as.character(PATID),
        anchor_date = .clinical_date(anchor_date))
    target_analytes <- toupper(trimws(as.character(analytes)))

    source_counts <- biol %>%
        filter(!is.na(PATID)) %>%
        count(PATID, name = "n_source_rows")

    observations <- biol %>%
        inner_join(tkeys, by = "PATID", relationship = "many-to-many") %>%
        filter(.within_point(
            DATEXAM, anchor_date + from_days, anchor_date + to_days)) %>%
        mutate(
            field = field,
            source = source,
            in_scope = TRUE,
            is_target = !is.na(analyte) &
                toupper(trimws(analyte)) %in% target_analytes,
            usable = is_target & !is.na(value),
            invalid = is_target & !usable,
            above_threshold = usable & !is.na(threshold) & value > threshold,
            scope_reason = "point time inside the task window",
            observation_reason = case_when(
                !is_target ~ "analyte outside the declared concept",
                !usable ~ "value is unparseable and excluded",
                is.na(threshold) ~ "usable value (no threshold applied)",
                above_threshold ~ "usable value above the strict threshold",
                TRUE ~ "usable value at or below the strict threshold"),
            # Non-target rows establish source/scope coverage; their unrelated
            # result values are unnecessary in persisted structured artifacts.
            value_raw = if_else(is_target, value_raw, NA_character_),
            value = if_else(is_target, value, NA_real_))

    selected <- observations %>%
        filter(usable) %>%
        arrange(task_id, desc(value), DATEXAM, source_row_id) %>%
        group_by(task_id) %>%
        slice_head(n = 1L) %>%
        ungroup() %>%
        transmute(
            task_id,
            source_row_id,
            measurement_value = value,
            measurement_time = DATEXAM,
            selected_evidence = TRUE)
    observations <- observations %>%
        left_join(
            select(selected, task_id, source_row_id, selected_evidence),
            by = c("task_id", "source_row_id")) %>%
        mutate(selected_evidence = coalesce(selected_evidence, FALSE))

    counts <- observations %>%
        group_by(task_id) %>%
        summarise(
            n_scope_rows = n(),
            n_candidate_rows = sum(is_target),
            n_usable = sum(usable),
            n_unusable = sum(invalid),
            n_above = sum(above_threshold),
            .groups = "drop")

    coverage <- tkeys %>%
        left_join(source_counts, by = "PATID") %>%
        left_join(counts, by = "task_id") %>%
        left_join(select(selected, task_id, measurement_value, measurement_time),
                  by = "task_id") %>%
        mutate(
            across(
                c(n_source_rows, n_scope_rows, n_candidate_rows, n_usable,
                  n_unusable, n_above),
                ~ coalesce(as.integer(.x), 0L)),
            processing_state = case_when(
                n_source_rows == 0L ~ "no_eligible_source",
                n_candidate_rows == 0L ~ "no_candidate",
                n_usable == 0L ~ "invalid",
                TRUE ~ "measured"))

    values <- coverage %>%
        filter(processing_state %in% c("measured", "invalid")) %>%
        mutate(normalized_value = case_when(
            processing_state == "invalid" ~ NA_character_,
            is.na(threshold) ~ NA_character_,
            measurement_value > threshold ~ "present",
            TRUE ~ "absent")) %>%
        transmute(
            task_id,
            field = field,
            normalized_value,
            accepted_value = if_else(
                processing_state == "measured", normalized_value, NA_character_),
            measurement_value,
            measurement_time,
            field_validity = if_else(
                processing_state == "measured", "valid", "invalid"),
            validity_reason = if_else(
                processing_state == "measured", "",
                "analyte rows are in scope but none has a parseable value"),
            n_scope_rows,
            n_candidate_rows,
            n_usable,
            n_unusable,
            n_above)

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

    threshold_clause <- if (is.na(threshold)) "" else
        sprintf("value > %s; ", format(threshold, trim = TRUE))
    rule <- sprintf(
        paste0(
            "same_subject; point_window[%d,%+d]; analyte=%s; %s",
            "maximum usable value selected (ties: DATEXAM, source_row_id); unit ignored"),
        as.integer(from_days), as.integer(to_days),
        paste(analytes, collapse = ","), threshold_clause)
    derivation <- coverage %>%
        transmute(
            task_id,
            field = field,
            rule = rule,
            n_source_rows,
            n_scope_rows,
            n_candidate_rows,
            n_usable,
            n_unusable,
            n_above,
            status = processing_state,
            error = NA_character_)

    .assert_evidence_resolves(evidence, observations, biol)
    list(
        coverage = coverage,
        values = values,
        evidence = evidence,
        observations = observations,
        derivation = derivation)
}

# One row per task/field with selected evidence collapsed for physician review.
build_structured_review_view <- function(values, evidence) {
    .require_columns(
        values,
        c("task_id", "field", "normalized_value", "accepted_value",
          "measurement_value", "measurement_time", "field_validity",
          "validity_reason"),
        "structured values")
    if (!nrow(values)) {
        return(values %>%
            mutate(
                n_evidence = integer(),
                source_row_ids = character(),
                evidence = character(),
                review_decision = character(),
                review_note = character()))
    }

    ev <- if (nrow(evidence)) {
        .require_columns(
            evidence,
            c("task_id", "field", "source_row_id", "evidence_summary"),
            "structured evidence")
        evidence %>%
            group_by(task_id, field) %>%
            summarise(
                n_evidence = n(),
                source_row_ids = paste(source_row_id, collapse = ";"),
                evidence = paste(evidence_summary, collapse = "\n"),
                .groups = "drop")
    } else {
        tibble::tibble(
            task_id = character(), field = character(), n_evidence = integer(),
            source_row_ids = character(), evidence = character())
    }

    values %>%
        left_join(ev, by = c("task_id", "field")) %>%
        mutate(
            n_evidence = coalesce(n_evidence, 0L),
            source_row_ids = coalesce(source_row_ids, ""),
            evidence = coalesce(evidence, ""),
            review_decision = "",
            review_note = "")
}
