# =============================================================================
# adapter_smoking.R — D0840 peri-operative smoking project adapter
# Exercises the DATE-WINDOW scope path (complement to anastomoses' event scope).
# Recipients only (D0840 is a testbed; donor/recipient role is study fidelity we
# don't need here). Produces the generic (task_id, ELTID, ...) eligibility table.
# =============================================================================

suppressWarnings(suppressMessages(library(dplyr)))

SMOKING_WIN_PRE  <- 365L
SMOKING_WIN_POST <- 7L

# Pinned round-2 smoking query (peri-op smoking terms + pack-year forms).
SMOKING_QUERY <- paste(
    "tabac*", "tabagi*", "fumeu*", "sevr*", "cigarette*", "paquet*",
    "<(0* OR 1* OR 2* OR 3* OR 4* OR 5* OR 6* OR 7* OR 8* OR 9*) PA>",
    "(0*PA OR 1*PA OR 2*PA OR 3*PA OR 4*PA OR 5*PA OR 6*PA OR 7*PA OR 8*PA OR 9*PA)",
    sep = " OR "
)

# Recipient surgery tasks; reads ONLY the three non-identifier columns.
smoking_load_tasks <- function(chirurgie_path) {
    ch <- read_workbook_columns(
        chirurgie_path, c("DATEACTE", "PATID_receveur", "EVTID_receveur")
    )
    tasks <- ch %>%
        transmute(
            PATID       = as.character(PATID_receveur),
            EVTID       = as.character(EVTID_receveur),
            anchor_date = clean_mixed_date(DATEACTE)
        ) %>%
        filter(!is.na(PATID), PATID != "", !is.na(EVTID), EVTID != "",
               !is.na(anchor_date)) %>%
        distinct() %>%
        mutate(task_id = sprintf("%s::%s::%s", PATID,
                                 format(anchor_date, "%Y-%m-%d"), EVTID)) %>%
        select(task_id, PATID, EVTID, anchor_date)
    if (anyDuplicated(tasks$task_id)) {
        stop("smoking: task_id must be unique.", call. = FALSE)
    }
    tasks
}

# Eligibility = the patient's documents within [anchor - 365, anchor + 7] days.
smoking_eligibility <- function(tasks, docs_index) {
    docs_index %>%
        inner_join(
            distinct(tasks, task_id, PATID, anchor_date),
            by = "PATID", relationship = "many-to-many"
        ) %>%
        filter(RECDATE >= anchor_date - SMOKING_WIN_PRE,
               RECDATE <= anchor_date + SMOKING_WIN_POST) %>%
        transmute(task_id, ELTID, RECDATE, RECTYPE, anchor_date)
}
