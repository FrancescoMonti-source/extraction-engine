# =============================================================================
# structured.R — deterministic (non-LLM) extraction path for STRUCTURED sources
# -----------------------------------------------------------------------------
# Mirrors the text path's four views but: evidence = selected source rows,
# measurement = a deterministic rule, NO corpus and NO model. Concrete helpers
# for the two contracted variables (diabetes / hyperkalaemia), not a generic
# framework. Coverage census is kept over ALL tasks, same discipline as the text
# path. Provenance points at the exact source rows.
# =============================================================================

suppressWarnings(suppressMessages(library(dplyr)))

# --- scope helpers (point / interval) ----------------------------------------
.within_point <- function(t, lo, hi) !is.na(t) & t >= lo & t <= hi
# interval [start,end] overlaps [lo,hi]; a missing end is treated as the start
# (admission-day point) -- an explicit, documented policy, never silent +Inf.
.overlaps_interval <- function(start, end, lo, hi) {
    end_eff <- dplyr::coalesce(end, start)
    !is.na(start) & start <= hi & end_eff >= lo
}

# ICD-10 family membership by code prefix (E11 matches E11, E11.9, E119, ...).
code_in_family <- function(codes, families) {
    norm <- function(x) toupper(gsub("[^A-Za-z0-9]", "", as.character(x)))
    fam <- norm(families)
    vapply(norm(codes), function(c) any(startsWith(c, fam)), logical(1))
}

# Build the coverage census + processing_state for a deterministic variable.
# patient_has_source: tibble(task_id, has_source); per_task counts: n_eligible, n_matched.
.structured_coverage <- function(tasks, has_source, counts) {
    tasks %>%
        left_join(has_source, by = "task_id") %>%
        left_join(counts, by = "task_id") %>%
        mutate(
            has_source = coalesce(has_source, FALSE),
            n_eligible = coalesce(as.integer(n_eligible), 0L),
            n_matched  = coalesce(as.integer(n_matched), 0L),
            processing_state = case_when(
                !has_source            ~ "no_eligible_source",
                n_eligible == 0L       ~ "no_candidate",
                TRUE                   ~ "measured"))
}

# --- diabetes: ICD-10 code presence over pmsi$diag (interval time) ------------
DIABETES_CODES <- c("E10", "E11", "E12", "E13", "E14")

# diag: pmsi$diag rows (PATID, EVTID, diag, DATENT, DATSORT).
# tasks: task_id, PATID, anchor_date.
measure_diabetes <- function(diag, tasks, codes = DIABETES_CODES,
                             from_days = -1825L, to_days = 7L) {
    diag <- diag %>% transmute(
        PATID = as.character(PATID), EVTID = as.character(EVTID),
        code = as.character(diag), DATENT = as.Date(DATENT), DATSORT = as.Date(DATSORT))
    tkeys <- distinct(tasks, task_id, PATID, anchor_date)

    has_source <- tkeys %>% transmute(task_id, has_source = PATID %in% unique(diag$PATID))

    elig <- diag %>%
        inner_join(tkeys, by = "PATID", relationship = "many-to-many") %>%
        filter(.overlaps_interval(DATENT, DATSORT, anchor_date + from_days, anchor_date + to_days)) %>%
        mutate(is_target = code_in_family(code, codes))

    counts <- elig %>% group_by(task_id) %>%
        summarise(n_eligible = n(), n_matched = sum(is_target), .groups = "drop")
    coverage <- .structured_coverage(tkeys, has_source, counts)

    values <- coverage %>%
        filter(processing_state == "measured") %>%
        transmute(task_id, field = "diabetes_status",
                  value = if_else(n_matched > 0L, "present", "absent"),
                  n_eligible, n_matched,
                  field_validity = "valid", validity_reason = "")

    evidence <- elig %>%
        filter(is_target) %>%
        semi_join(filter(values, value == "present"), by = "task_id") %>%
        transmute(task_id, field = "diabetes_status",
                  evidence_ref = sprintf("%s::%s", EVTID, code),
                  EVTID, code, DATENT, DATSORT)

    derivation <- values %>%
        transmute(task_id, field, rule = "icd10_code_presence",
                  n_eligible, n_matched, status = "measured", error = NA_character_)

    list(coverage = coverage, values = values, evidence = evidence, derivation = derivation)
}
