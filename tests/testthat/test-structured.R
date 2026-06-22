# Contract tests for the deterministic structured path. Synthetic data only.

structured_tasks <- function(ids) {
    tibble::tibble(
        task_id = paste0(ids, "::t"),
        PATID = ids,
        anchor_date = as.Date("2025-03-10"))
}

diag_rows <- function(PATID, diag, DATENT, DATSORT,
                      EVTID = paste0("EV", seq_along(PATID)),
                      ELTID = paste0("EL", seq_along(PATID))) {
    tibble::tibble(
        source_row_id = sprintf("diag:%03d", seq_along(PATID)),
        PATID, EVTID, ELTID, diag,
        DATENT = as.Date(DATENT),
        DATSORT = as.Date(DATSORT))
}

biol_rows <- function(PATID, analyte, value_raw, DATEXAM,
                      EVTID = paste0("EV", seq_along(PATID)),
                      ELTID = paste0("EL", seq_along(PATID)),
                      BIOL_ID = paste0("B", seq_along(PATID))) {
    tibble::tibble(
        source_row_id = sprintf("biol:%03d", seq_along(PATID)),
        PATID, EVTID, ELTID, BIOL_ID,
        DATEXAM = as.Date(DATEXAM),
        analyte,
        value_raw = as.character(value_raw),
        value = suppressWarnings(as.numeric(value_raw)))
}

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

test_that("diabetes covers scope, malformed rows, and missing-end policy", {
    lower <- as.Date("2025-03-10") - 1825L
    diag <- diag_rows(
        PATID = c("P1", "P2", "P3", "P5", "P6", "P7", "P7"),
        diag = c("E11.9", "I10", "E10", "E14", NA, "", "I10"),
        DATENT = c(lower - 2L, as.Date("2025-03-05"), as.Date("2010-01-01"),
                   as.Date("2025-03-09"), as.Date("2025-03-09"),
                   as.Date("2025-03-09"), as.Date("2025-03-09")),
        DATSORT = c(lower, as.Date("2025-03-06"), as.Date("2010-01-05"),
                    as.Date(NA), as.Date("2025-03-10"),
                    as.Date("2025-03-10"), as.Date("2025-03-10")))
    tasks <- structured_tasks(paste0("P", 1:7))
    run <- measure_diabetes(diag, tasks)

    states <- setNames(run$coverage$processing_state, run$coverage$task_id)
    expect_equal(
        unname(states[tasks$task_id]),
        c("measured", "measured", "no_candidate", "no_eligible_source",
          "measured", "invalid", "measured"))

    values <- setNames(run$values$accepted_value, run$values$task_id)
    expect_equal(values[["P1::t"]], "present")
    expect_equal(values[["P2::t"]], "absent")
    expect_equal(values[["P5::t"]], "present")
    expect_true(is.na(values[["P6::t"]]))
    expect_equal(values[["P7::t"]], "absent")

    expect_setequal(run$evidence$task_id, c("P1::t", "P5::t"))
    expect_equal(nrow(run$derivation), nrow(tasks))
    expect_equal(
        run$derivation$status[run$derivation$task_id == "P4::t"],
        "no_eligible_source")
    expect_true(any(
        run$observations$task_id == "P7::t" & run$observations$invalid))
    expect_match(
        run$derivation$rule[1], "missing_DATSORT=use_start", fixed = TRUE)

    excluded <- measure_diabetes(diag, tasks, missing_datsort = "exclude")
    expect_equal(
        excluded$coverage$processing_state[
            excluded$coverage$task_id == "P5::t"],
        "no_candidate")
    expect_match(
        excluded$derivation$rule[1], "missing_DATSORT=exclude", fixed = TRUE)
})

test_that("hyperkalaemia separates source, concept, usability, and value states", {
    biol <- biol_rows(
        PATID = c("P1", "P1", "P2", "P3", "P5", "P6", "P6", "P7", "P7", "P8"),
        analyte = c("K.K", "K.K", "K.K", "NA.NA", "K.K",
                    "K.K", "K.K", "K.K", "K.K", "K.K"),
        value_raw = c("5.6", "5.2", "5.0", "140", "hemolyse",
                      "hemolyse", "5.4", "4.8", "4.9", "6.0"),
        DATEXAM = c("2025-03-11", "2025-03-09", "2025-03-10", "2025-03-10",
                    "2025-03-10", "2025-03-09", "2025-03-11", "2025-03-09",
                    "2025-03-11", "2024-01-01"))
    tasks <- structured_tasks(paste0("P", 1:8))
    run <- measure_hyperkalaemia(biol, tasks)

    states <- setNames(run$coverage$processing_state, run$coverage$task_id)
    expect_equal(
        unname(states[tasks$task_id]),
        c("measured", "measured", "no_candidate", "no_eligible_source",
          "invalid", "measured", "measured", "no_candidate"))

    values <- setNames(run$values$accepted_value, run$values$task_id)
    expect_equal(values[["P1::t"]], "present")
    expect_equal(values[["P2::t"]], "absent") # strict threshold: 5.0 is absent
    expect_true(is.na(values[["P5::t"]]))
    expect_equal(values[["P6::t"]], "present") # malformed sibling row is excluded
    expect_equal(values[["P7::t"]], "absent")

    evidence_counts <- table(run$evidence$task_id)
    expect_true(all(evidence_counts == 1L))
    evidence_values <- setNames(run$evidence$value, run$evidence$task_id)
    expect_equal(evidence_values[["P1::t"]], 5.6)
    expect_equal(evidence_values[["P2::t"]], 5.0)
    expect_equal(evidence_values[["P6::t"]], 5.4)
    expect_equal(evidence_values[["P7::t"]], 4.9)
    expect_true(any(
        run$observations$task_id == "P6::t" & run$observations$invalid))
    expect_equal(nrow(run$derivation), nrow(tasks))
})

test_that("structured provenance resolves once and review uses concise evidence", {
    biol <- biol_rows(
        PATID = c("P1", "P1"), analyte = "K.K",
        value_raw = c("5.1", "5.7"),
        DATEXAM = c("2025-03-09", "2025-03-11"))
    tasks <- structured_tasks("P1")
    run <- measure_hyperkalaemia(biol, tasks)
    review <- build_structured_review_view(run$values, run$evidence)

    expect_equal(nrow(run$evidence), 1L)
    expect_equal(review$n_evidence, 1L)
    expect_equal(review$accepted_value, "present")
    expect_match(review$evidence, "5.7", fixed = TRUE)
    expect_equal(review$review_decision, "")

    duplicated <- dplyr::bind_rows(biol, biol[1, ])
    expect_error(
        measure_hyperkalaemia(duplicated, tasks),
        "source_row_id must be non-missing and unique")
})

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
