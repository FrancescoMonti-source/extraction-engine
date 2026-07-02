# Disposable probe (NOT a shipped concept): can the engine COUNT CCAM acts per STAY?
# Two axes at once, both generic: (1) stay-grain scoping -- a structured executor must
# scope evidence to the TASK's own stay (EVTID), not just the subject (PATID); DESIGN §7
# names this the current executor-wiring gap ("EVTID is invariant across HDW rows"). (2)
# a numeric COUNT over a structured membership channel = the executor returning CANDIDATE
# rows + a plain-function reducer `function(x) length(x)` (no bespoke count operator).
#
# Grain comes from the TASK UNIVERSE (DESIGN §7: "one output row per unit in the supplied
# task universe"): one task per stay, carrying its EVTID. The variable is event-scoped
# (window = NULL): "acts in the stay" = act rows sharing the task's EVTID, no date window.
#
# Discriminator: patient P1 has TWO stays. EV1 has 2 matching acts (JAFA001) + 1 decoy
# (HGPC015, wrong code); EV2 has 1 matching act. Correct stay-scoping -> EV1 counts 2,
# EV2 counts 1. A PATID-only join (the gap) would let each stay see ALL of P1's matches
# (2 + 1 = 3) -> both would be 3. So EV1 == 2 and EV2 == 1 is the proof of EVTID scoping;
# the decoy proves the count is matching-and-in-stay, not just every row in the stay.

es_acts <- tibble::tibble(
    source_row_id = sprintf("acte:%03d", 1:4),
    PATID = "P1",
    EVTID = c("EV1", "EV1", "EV1", "EV2"),
    ELTID = c("L1", "L2", "L3", "L4"),
    CODEACTE = c("JAFA001", "JAFA001", "HGPC015", "JAFA001"),
    DATEACTE = as.Date("2024-05-25"))          # date irrelevant: event-scoped, window = NULL

es_tasks <- tibble::tibble(                      # STAY grain: one task per (PATID, EVTID)
    task_id = c("P1::EV1", "P1::EV2"),
    PATID = "P1",
    EVTID = c("EV1", "EV2"))

es_concept <- concept_spec(
    name = "ccam_acts",
    channels = list(
        stay_acts = act_channel(
            source = "pmsi_actes",
            selector = ccam("JAFA001", match = "exact"),
            required_roles = c("subject_id", "event_id", "date", "code",
                               "source_item_id"),
            linkage = "subject")))

es_spec <- variable_spec(
    name = "n_ccam_acts_in_stay",
    concept = es_concept,
    output_one_row_per = "EVTID",                # stay grain: one output row per (PATID, EVTID)
    anchor = NULL,
    window = NULL,                               # event-scoped: same EVTID, no date window
    channels = list(stay_acts = use_channel(reducer = function(x) length(x))),
    output = num_output())

test_that("structured executor counts acts scoped to the task's own stay (EVTID)", {
    run <- run_variable(es_spec, es_tasks, list(pmsi_actes = es_acts))
    value <- setNames(run$values$value, run$values$task_id)

    expect_equal(value[["P1::EV1"]], 2)   # 2 JAFA001 in EV1; NOT EV2's act, NOT the decoy
    expect_equal(value[["P1::EV2"]], 1)   # 1 JAFA001 in EV2; NOT EV1's two acts
})
