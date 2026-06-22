# Contract tests for the deterministic structured path. No provider, no patient
# data; synthetic pmsi$diag fixture.

diabetes_fixture <- function() {
    diag <- tibble::tibble(
        PATID  = c("P1", "P2", "P3"),
        EVTID  = c("EV1", "EV2", "EV3"),
        diag   = c("E11.9", "I10", "E11"),
        DATENT = as.Date(c("2025-03-01", "2025-03-05", "2010-01-01")),
        DATSORT = as.Date(c("2025-03-03", "2025-03-06", "2010-01-05")))
    tasks <- tibble::tibble(
        task_id = c("P1::t", "P2::t", "P3::t", "P4::t"),
        PATID   = c("P1", "P2", "P3", "P4"),
        anchor_date = as.Date("2025-03-10"))
    list(diag = diag, tasks = tasks)
}

test_that("code_in_family matches ICD-10 prefixes, not unrelated codes", {
    expect_true(code_in_family("E11.9", DIABETES_CODES))
    expect_true(code_in_family("E119", DIABETES_CODES))
    expect_true(code_in_family("E10", DIABETES_CODES))
    expect_false(code_in_family("I10", DIABETES_CODES))
    expect_false(code_in_family("E08", DIABETES_CODES))
})

test_that("diabetes: present / absent / no_candidate / no_eligible_source", {
    fx <- diabetes_fixture()
    r <- measure_diabetes(fx$diag, fx$tasks)
    ps <- r$coverage$processing_state[match(fx$tasks$task_id, r$coverage$task_id)]
    expect_equal(ps, c("measured", "measured", "no_candidate", "no_eligible_source"))

    expect_equal(r$values$value[r$values$task_id == "P1::t"], "present")
    expect_equal(r$values$value[r$values$task_id == "P2::t"], "absent")
    # provenance: present cites the diabetic row; absent cites nothing
    expect_true(any(grepl("^EV1::E11", r$evidence$evidence_ref)))
    expect_equal(nrow(r$evidence[r$evidence$task_id == "P2::t", ]), 0L)
})

test_that("interval scope respects the lookback window", {
    fx <- diabetes_fixture()
    # widen the window to include the 2010 stay -> P3 becomes measured/present
    r <- measure_diabetes(fx$diag, fx$tasks, from_days = -6000L, to_days = 7L)
    expect_equal(r$coverage$processing_state[r$coverage$task_id == "P3::t"], "measured")
    expect_equal(r$values$value[r$values$task_id == "P3::t"], "present")
})

test_that("a missing DATSORT is treated as the admission day (documented policy)", {
    diag <- tibble::tibble(PATID = "P1", EVTID = "EV1", diag = "E11",
                           DATENT = as.Date("2025-03-09"), DATSORT = as.Date(NA))
    tasks <- tibble::tibble(task_id = "P1::t", PATID = "P1", anchor_date = as.Date("2025-03-10"))
    r <- measure_diabetes(diag, tasks)            # DATENT in window -> measured/present
    expect_equal(r$coverage$processing_state, "measured")
    expect_equal(r$values$value, "present")
})
