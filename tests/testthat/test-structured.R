# Contract tests for the deterministic structured path. Synthetic data only.

structured_tasks <- function(ids) {
    tibble::tibble(
        task_id = paste0(ids, "::t"),
        PATID = ids,
        anchor_date = as.Date("2025-03-10"))
}

# Why: loaders are the boundary between prepared study files and deterministic
# measurement. They must preserve the hospital calendar date, native identifiers,
# and all source rows so concept filtering happens in the variable logic rather
# than silently changing source coverage during loading.
test_that("structured loaders preserve local dates and native provenance", {
    pmsi_path <- tempfile(fileext = ".rds")
    bio_path <- tempfile(fileext = ".rds")
    on.exit(unlink(c(pmsi_path, bio_path)), add = TRUE)
    local_time <- as.POSIXct("2025-06-22 00:30:00", tz = "Europe/Paris")

    saveRDS(list(diag = tibble::tibble(
        PATID = c("P1", "P1"), EVTID = c("E1", "E1"),
        ELTID = c("D1", "D2"), diag = c("E11.9", "I10"),
        DATENT = local_time, DATSORT = local_time)), pmsi_path)
    saveRDS(tibble::tibble(
        PATID = c("P1", "P1"), EVTID = c("E1", "E1"),
        ELTID = c("L1", "L2"), biol_ID = c("B1", "B2"),
        DATEXAM = local_time, TYPEANA = c("K.K", "NA.NA"),
        NUMRES = c("5.4", "140")), bio_path)

    diag <- load_pmsi_diag(pmsi_path)
    biol <- load_biol_results(bio_path)

    expect_equal(diag$DATENT, rep(as.Date("2025-06-22"), 2))
    expect_equal(biol$DATEXAM, rep(as.Date("2025-06-22"), 2))
    expect_equal(diag[c("PATID", "EVTID", "ELTID", "diag")],
                 tibble::tibble(PATID = c("P1", "P1"), EVTID = c("E1", "E1"),
                                ELTID = c("D1", "D2"), diag = c("E11.9", "I10")))
    expect_equal(biol$BIOL_ID, c("B1", "B2"))
    expect_equal(biol$analyte, c("K.K", "NA.NA"))
    expect_equal(nrow(biol), 2L) # concept filtering belongs in the measurement rule
    expect_equal(anyDuplicated(diag$source_row_id), 0L)
    expect_equal(anyDuplicated(biol$source_row_id), 0L)
})

# Why: a programming or input-shape failure can occur before per-row measurement.
# The production wrapper must preserve one failure record per requested output row
# instead of aborting without a derivation census.
test_that("production wrapper audits execution failures for every task", {
    tasks <- structured_tasks(c("P1", "P2"))
    broken <- function(source_rows, tasks) stop("synthetic execution failure")
    run <- run_structured_measurement(
        broken, tibble::tibble(), tasks, field = "broken_field")

    expect_true(all(run$coverage$processing_state == "processing_error"))
    expect_equal(nrow(run$derivation), nrow(tasks))
    expect_true(all(run$derivation$status == "processing_error"))
    expect_true(all(run$derivation$error == "synthetic execution failure"))
    expect_equal(nrow(run$values), 0L)
})
