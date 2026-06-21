# =============================================================================
# adapter_anastomoses.R — D0840 recipient transplant-anastomosis project adapter
# Owns task construction and scope. Scope is EVENT membership (PATID + EVTID),
# not a temporal window. Produces the generic (task_id, ELTID, ...) eligibility
# relation the engine consumes; the engine stays clinical-agnostic.
# =============================================================================

suppressWarnings(suppressMessages(library(dplyr)))

# Free retrieval-query design (broad recall; the model + evidence do precision).
ANASTOMOSES_QUERY <- paste(
    "anastom*", "gregoir*", "ureter*", "reimplant*",
    "<veine iliaque>", "<artere iliaque>",
    sep = " OR "
)

# Recipient-only tasks; reads ONLY the three non-identifier columns.
anastomoses_load_tasks <- function(chirurgie_path) {
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
        stop("anastomoses: task_id must be unique.", call. = FALSE)
    }
    tasks
}

# Eligibility = recipient's documents from the SAME surgical event (PATID+EVTID).
anastomoses_eligibility <- function(tasks, docs_index) {
    docs_index %>%
        inner_join(
            distinct(tasks, task_id, PATID, EVTID, anchor_date),
            by = c("PATID", "EVTID"), relationship = "many-to-many"
        ) %>%
        transmute(task_id, ELTID, RECDATE, RECTYPE, anchor_date)
}
