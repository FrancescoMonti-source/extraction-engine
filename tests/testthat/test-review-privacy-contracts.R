test_that("candidate-selection errors do not expose task identifiers", {
    # Console-privacy contract: diagnostics describe the failure class, not the
    # patient-derived task coordinate.
    sentinel <- "SENSITIVE_TASK_SENTINEL"
    rows <- tibble::tibble(task_id = sentinel, snippet_id = "S001")
    error <- tryCatch(
        .select_task_candidates(function(x) x[0, , drop = FALSE], rows, sentinel),
        error = identity)

    expect_s3_class(error, "error")
    expect_false(grepl(sentinel, conditionMessage(error), fixed = TRUE))
})

test_that("index-event errors report counts without patient identifiers", {
    # Console-privacy contract: even deterministic anchor failures may contain
    # only aggregate counts.
    sentinel <- "SENSITIVE_PATIENT_SENTINEL"
    rows <- tibble::tibble(
        source_row_id = c("diag:1", "diag:2"),
        PATID = sentinel, EVTID = c("event-1", "event-2"),
        ELTID = c("stay-1", "stay-2"), diag = "Z94",
        DATENT = as.POSIXct(c("2025-01-01", "2025-02-01"),
                           tz = "Europe/Paris"),
        DATSORT = as.POSIXct(c("2025-01-02", "2025-02-02"),
                            tz = "Europe/Paris"))
    variable <- list(
        anchor = index_event(
            "pmsi_diag", icd10("Z94", match = "exact"), at = "DATENT"),
        window = NULL, output_one_row_per = "PATID")
    tasks <- tibble::tibble(task_id = "task", PATID = sentinel)
    error <- tryCatch(
        .resolve_anchor(variable, tasks, list(pmsi_diag = rows)),
        error = identity)

    expect_s3_class(error, "error")
    expect_false(grepl(sentinel, conditionMessage(error), fixed = TRUE))
    expect_match(conditionMessage(error), "1 subject")
})
