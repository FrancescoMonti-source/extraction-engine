# Whole-history ("ever") variant: the unanchored axis. anchor = none, window = none,
# scope = the subject's ENTIRE record. diabetes_ever contrasts with the windowed
# diabete_pre_greffe -- same concept + channel, different anchor/window choice at
# the variable level. Synthetic deterministic data.

# Tasks carry NO anchor_date -- whole-history variables have no anchor.
wh_tasks <- tibble::tibble(
    task_id = paste0("Q", 1:4),
    PATID = paste0("Q", 1:4))

# Q1: a diabetes code. Q2: a non-diabetes code (ascertained negative). Q3: NO rows.
# Q4: a diabetes code from 2005 -- old, but whole-history has no window, so it counts.
wh_diag <- tibble::tibble(
    source_row_id = sprintf("diag:%03d", 1:3),
    PATID = c("Q1", "Q2", "Q4"),
    EVTID = c("V1", "V2", "V4"),
    ELTID = c("L1", "L2", "L4"),
    diag = c("E11.9", "I10", "E10"),
    DATENT = as.Date(c("2023-01-01", "2023-01-01", "2005-06-01")),
    DATSORT = as.Date(c("2023-01-02", "2023-01-02", "2005-06-02")))

wh_sources <- list(pmsi_diag = wh_diag)

wh_variable <- function() {
    variable_spec(
        name = "diabetes_ever",
        concept = diabetes_concept_spec(),
        unit = "patient",
        anchor = NULL,                 # no anchor
        window = NULL,                 # whole history
        channels = list(pmsi_diag_e10_e14 = use_channel()),
        output = binary_output(),
        combine = any_positive(),
        absence_policy = open_world())
}

# Why: a whole-history variable must execute with no anchor and no date window,
# scoping the subject's entire record. A diabetes code anywhere -> present; a record
# with only non-diabetes codes -> ascertained negative; no rows -> not ascertained.
test_that("diabetes_ever scopes the whole history with no anchor/window", {
    var <- wh_variable()
    expect_null(var$window)
    expect_null(var$anchor)

    run <- run_variable(var, wh_tasks, wh_sources)   # no caller: structured only

    value <- setNames(run$values$value, run$values$task_id)
    asc <- setNames(run$values$ascertainment, run$values$task_id)

    expect_equal(value[["Q1"]], 1L)        # diabetes code present
    expect_equal(value[["Q2"]], 0L)        # only a non-diabetes code -> negative
    expect_true(is.na(value[["Q3"]]))      # no diagnosis rows -> not ascertained
    expect_equal(value[["Q4"]], 1L)        # 2005 code still counts (no window)

    expect_equal(asc[["Q1"]], "complete")
    expect_equal(asc[["Q2"]], "complete")
    expect_equal(asc[["Q3"]], "partial")
})

# Why: whole-history source contribution must stay transparent like the windowed
# OR path -- signal/negative/silent per channel, evidence for the positive.
test_that("diabetes_ever preserves source contribution", {
    run <- run_variable(wh_variable(), wh_tasks, wh_sources)
    ss <- run$source_status
    get <- function(tid, col) ss[[col]][ss$task_id == tid]

    expect_equal(get("Q1", "contribution"), "signal")
    expect_equal(get("Q1", "processing_state"), "measured")
    expect_equal(get("Q2", "contribution"), "negative")
    expect_equal(get("Q3", "contribution"), "silent")
    expect_equal(get("Q3", "processing_state"), "no_eligible_source")
    expect_equal(run$combine_rule, "any_positive")

    # The positive is grounded by its diagnosis row; the 2005 code grounds Q4.
    expect_equal(run$evidence$evidence_ref[run$evidence$task_id == "Q1"], "diag:001")
    expect_equal(run$evidence$evidence_ref[run$evidence$task_id == "Q4"], "diag:003")
})
