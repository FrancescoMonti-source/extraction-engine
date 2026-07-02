# Disposable probe (NOT a shipped concept): can the LAB executor scope evidence to the
# TASK's own stay (EVTID), not just the subject (PATID)? This closes the last piece of
# the DESIGN §7 structured event/stay gap ("EVTID is invariant across HDW rows") -- the
# code/act executor already scopes by grain_keys; this brings the lab executor to parity.
# §565 names the shape: "a glucose result during the same stay". Event-scoped (window =
# NULL): the variable asks about rows sharing the task's EVTID, with no date window.
#
# Discriminator: patient P1 has TWO stays. EV1 holds glucose 15 + 9; EV2 holds glucose 7.
# With EVTID scoping, max glucose is EV1 = 15, EV2 = 7. A PATID-only join (the gap) would
# let each stay see ALL of P1's glucose (15, 9, 7) -> both would be 15. So EV1 == 15 and
# EV2 == 7 is the proof of stay scoping. The membership face is exercised in parallel: a
# gt = 10 hit is present in EV1 (15 > 10) but absent in EV2 (7 not > 10).

sg_biol <- tibble::tibble(
    source_row_id = sprintf("biol:%03d", 1:3),
    PATID = "P1",
    EVTID = c("EV1", "EV1", "EV2"),
    ELTID = c("L1", "L2", "L3"),
    BIOL_ID = c("B1", "B2", "B3"),
    DATEXAM = as.Date("2024-05-25"),          # date irrelevant: event-scoped, window = NULL
    analyte = "GLU.GLU",
    value_raw = c("15", "9", "7"),
    value = c(15, 9, 7))

sg_tasks <- tibble::tibble(                      # STAY grain: one task per (PATID, EVTID)
    task_id = c("P1::EV1", "P1::EV2"),
    PATID = "P1",
    EVTID = c("EV1", "EV2"))

sg_concept <- function() concept_spec(
    name = "glycaemia",
    channels = list(
        glucose = lab_channel(
            source = "biology",
            selector = analyte("GLU.GLU"),
            required_roles = c("subject_id", "event_id", "point_date", "value_num",
                               "value_str", "analyte", "source_item_id",
                               "source_result_id"),
            linkage = "subject")))

test_that("the lab executor reduces glucose scoped to the task's own stay (EVTID)", {
    spec <- variable_spec(
        name = "max_glucose_in_stay", concept = sg_concept(),
        output_one_row_per = "EVTID",            # stay grain: one output row per (PATID, EVTID)
        anchor = NULL, window = NULL,            # event-scoped: same EVTID, no date window
        channels = list(glucose = use_channel(reducer = function(x) max(x, na.rm = TRUE))),
        output = num_output())

    run <- run_variable(spec, sg_tasks, list(biology = sg_biol))
    value <- setNames(run$values$value, run$values$task_id)

    expect_equal(value[["P1::EV1"]], 15)   # max(15, 9) in EV1; NOT EV2's 7
    expect_equal(value[["P1::EV2"]], 7)    # only EV2's 7; NOT EV1's 15/9

    # Evidence stays within the stay: EV1's number was reduced from EV1's rows only.
    ev1 <- run$evidence[run$evidence$task_id == "P1::EV1", ]
    expect_setequal(ev1$evidence_ref, c("biol:001", "biol:002"))
})

test_that("a thresholded lab membership hit is scoped to the stay", {
    spec <- variable_spec(
        name = "hyperglycaemia_in_stay", concept = sg_concept(),
        output_one_row_per = "EVTID", anchor = NULL, window = NULL,
        channels = list(glucose = use_channel(selector = analyte_value("GLU.GLU", gt = 10))),
        output = bin_output())

    run <- run_variable(spec, sg_tasks, list(biology = sg_biol))
    value <- setNames(run$values$value, run$values$task_id)

    expect_equal(value[["P1::EV1"]], 1L)   # 15 > 10 in EV1
    expect_equal(value[["P1::EV2"]], 0L)   # EV2 has only 7: measured, below cutoff
})
