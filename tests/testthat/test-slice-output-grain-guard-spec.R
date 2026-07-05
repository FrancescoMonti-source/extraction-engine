# The output_one_row_per guard (run_variable / .check_output_grain): the tasks frame
# must ACTUALLY be at the declared grain -- DESIGN §7, "the engine checks whether
# channels can be mechanically linked to the requested unit". This is the job that makes
# output_one_row_per more than a label. Two failure modes it must catch (disposable
# probe; reuses the diabetes code channel -- the point is the guard, not the concept):
#   - declaring a grain column the task frame does not carry (cannot link to that grain);
#   - repeating a grain unit (then output rows would not be 1:1 with the unit).

og_diag <- tibble::tibble(
    source_row_id = "d1", PATID = "P1", EVTID = "EV1", ELTID = "L1",
    diag = "E11.9", DATENT = as.Date("2024-05-20"), DATSORT = as.Date("2024-05-21"))

og_spec <- function(grain) variable_spec(
    name = "grain_guard_probe", concept = diabetes_concept_spec(),
    output_one_row_per = grain, anchor = "anchor_date",
    window = c(-1825, 7),
    channels = list(pmsi_diag_e10_e14 = use_channel()),
    output = bin_output())

test_that("output_one_row_per guard rejects a task frame not at the declared grain", {
    # stay grain declared, but tasks carry no EVTID column -> cannot link to the stay
    patient_tasks <- tibble::tibble(
        grain_id = "P1::t", PATID = "P1", anchor_date = as.Date("2024-06-01"))
    expect_error(
        run_variable(og_spec("EVTID"), patient_tasks, list(pmsi_diag = og_diag)),
        "EVTID")

    # patient grain declared, but the same PATID appears twice -> not 1:1 with the unit
    dup_tasks <- tibble::tibble(
        grain_id = c("P1::a", "P1::b"), PATID = c("P1", "P1"),
        anchor_date = as.Date("2024-06-01"))
    expect_error(
        run_variable(og_spec("PATID"), dup_tasks, list(pmsi_diag = og_diag)),
        "one task per")
})
