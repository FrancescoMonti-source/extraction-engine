# Contract tests for the deterministic structured path. Synthetic data only.

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
    expect_equal(nrow(biol), 2L) # concept filtering belongs in the measurement rule
})
