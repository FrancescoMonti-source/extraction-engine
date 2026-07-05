# Disposable probe (NOT a shipped concept): does an activation-level selector
# override replace the concept's baseline selector in the EXECUTOR? DESIGN §14.3:
# use_channel(selector = ...) is a LOCAL override that must not mutate the concept.
#
# Discriminator: one subject whose only diabetes code is E13 -- inside the concept
# baseline icd10("^E1[0-4]") but OUTSIDE an override icd10("^E1[0-2]"). Same spec,
# same data, run twice: baseline hits (1), override misses (0). The contrast is the
# ONLY proof that the activation selector -- not the concept's -- drove the executor.
# (E13's 3rd char "3" is in [0-4] but not [0-2], regardless of dot normalization.)

co_tasks <- tibble::tibble(
    task_id = "T1::t", PATID = "T1", anchor_date = as.Date("2024-06-01"))

co_diag <- tibble::tibble(
    source_row_id = "diag:001", PATID = "T1", EVTID = "EV1", ELTID = "D1",
    diag = "E13.9",
    DATENT = as.Date("2024-05-20"), DATSORT = as.Date("2024-05-21"))

co_sources <- list(pmsi_diag = co_diag)

co_spec <- function(use) variable_spec(
    name = "diabetes_code_status",
    concept = diabetes_concept_spec(),
    output_one_row_per = "PATID",
    anchor = "anchor_date",
    window = c(-1825, 7),
    channels = list(pmsi_diag_e10_e14 = use),
    output = bin_output())          # single channel -> combine_channels = NULL (membership)

test_that("activation selector overrides the concept's baseline selector in the executor", {
    baseline <- run_variable(co_spec(use_channel()), co_tasks, co_sources)
    override <- run_variable(
        co_spec(use_channel(selector = icd10("^E1[0-2]"))), co_tasks, co_sources)

    base_val <- setNames(baseline$values$value, baseline$values$task_id)
    over_val <- setNames(override$values$value, override$values$task_id)

    expect_equal(base_val[["T1::t"]], 1L)   # E13 in the concept baseline E1[0-4]
    expect_equal(over_val[["T1::t"]], 0L)   # ...but the LOCAL override E1[0-2] excludes it
})
