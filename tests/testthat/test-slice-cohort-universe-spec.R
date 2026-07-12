# The cohort intake (owner-settled 2026-07-05): the row universe is DECLARED --
# laid down with the data as sources$cohort (the 99% path: the engine runs
# downstream of a human-validated cohort) or passed explicitly as the override.
# It is never inferred from data rows: a validated patient with no rows in any
# loaded source must get his NA/partial row, not silently vanish from the
# denominator ("that patient shouldn't vanish, he should just have NA
# everywhere"). A bare vector of PATIDs (a spreadsheet column) is a valid
# patient-grain cohort; grain_id derives from the grain keys when absent.
# cohort_from_sources() is the EXPLICIT union-of-frames escape for exploration.

cu_acts <- tibble::tibble(
    source_row_id = c("a1", "a2"),
    PATID    = c("C1", "C1"),
    EVTID    = c("V1", "V2"),
    ELTID    = c("K1", "K2"),
    CODEACTE = "JVJF004",
    DATEACTE = as.Date(c("2024-02-01", "2024-03-01")))

cu_concept <- concept_spec(
    name = "any_dialysis_act",
    channels = list(dialysis_act = act_channel(
        source = "pmsi_actes",
        selector = ccam("JVJF004", match = "exact"),
        linkage = "subject")))

cu_spec <- variable_spec(
    name = "ever_dialysis_act",
    concept = cu_concept,
    output_one_row_per = "PATID",
    channels = c("dialysis_act"),
    output = bin_output())

test_that("the universe comes from sources$cohort; the row-less patient keeps his NA row", {
    # C3 is VALIDATED but has no rows in any loaded source -- the case that
    # settled the design: he must not vanish, he must be NA/partial.
    sources <- list(cohort = tibble::tibble(PATID = c("C1", "C2", "C3")),
                    pmsi_actes = cu_acts)
    run <- run_variable(cu_spec, sources = sources)
    value <- setNames(run$values$value, run$values$grain_id)
    coverage <- setNames(run$values$channel_coverage, run$values$grain_id)

    expect_equal(nrow(run$values), 3L)      # the denominator is the cohort
    expect_equal(value[["C1"]], 1L)          # grain_id derived from PATID
    expect_equal(value[["C3"]], 0L)          # bin encodes non-membership as 0...
    expect_equal(coverage[["C3"]], "partial") # ...with the silence in coverage
})

test_that("a bare vector of PATIDs is a valid patient-grain cohort", {
    sources <- list(cohort = c("C1", "C2"), pmsi_actes = cu_acts)
    run <- run_variable(cu_spec, sources = sources)
    expect_equal(setNames(run$values$value, run$values$grain_id),
                 c(C1 = 1L, C2 = 0L))
})

test_that("an explicit cohort narrows past sources$cohort (inclusion chaining)", {
    sources <- list(cohort = c("C1", "C2", "C3"), pmsi_actes = cu_acts)
    run <- run_variable(cu_spec, cohort = c("C1"), sources = sources)
    expect_equal(run$values$grain_id, "C1")
})

test_that("the variable projects one PATID-EVTID cohort to its declared output grain", {
    cohort <- tibble::tibble(
        PATID = c("C1", "C1", "C2"),
        EVTID = c("V1", "V2", "V3"))

    patient_run <- run_variable(
        cu_spec, cohort = cohort, sources = list(pmsi_actes = cu_acts))
    expect_equal(patient_run$values$grain_id, c("C1", "C2"))

    stay_spec <- variable_spec(
        name = "dialysis_act_by_stay", concept = cu_concept,
        output_one_row_per = "EVTID",
        channels = "dialysis_act", output = bin_output())
    stay_run <- run_variable(
        stay_spec, cohort = cohort, sources = list(pmsi_actes = cu_acts))
    expect_equal(stay_run$values$grain_id,
                 c("C1::V1", "C1::V2", "C2::V3"))
})

test_that("no cohort anywhere is a loud error, never a data-derived universe", {
    expect_error(run_variable(cu_spec, sources = list(pmsi_actes = cu_acts)),
                 "No cohort")
})
