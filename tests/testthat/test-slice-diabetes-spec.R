# Contract tests for the first executable concept/channel/template/spec slice.
# Synthetic data only. These tests protect architecture boundaries, not clinical
# truth for diabetes.

spec_tasks <- tibble::tibble(
    task_id = paste0("P", 1:4, "::t"),
    PATID = paste0("P", 1:4),
    anchor_date = as.Date("2024-06-01"))

spec_diag <- tibble::tibble(
    source_row_id = sprintf("diag:%03d", 1:3),
    PATID = c("P1", "P2", "P3"),
    EVTID = c("EV1", "EV2", "EV3"),
    ELTID = c("D1", "D2", "D3"),
    diag = c("I10", "E11.9", "I10"),
    DATENT = as.Date(c("2024-05-20", "2024-05-20", "2024-05-20")),
    DATSORT = as.Date(c("2024-05-21", "2024-05-21", "2024-05-21")))

spec_docs <- list(
    coverage = tibble::tibble(
        task_id = spec_tasks$task_id,
        coverage_state = c("candidate", "no_candidate", "no_candidate", "no_candidate")),
    candidates = tibble::tibble(
        task_id = "P1::t",
        snippet_id = "S001",
        hit_ref = "DOC1::3",
        ELTID = "DOC1",
        sentence = 3L,
        hit_text = "Patient diabetique.",
        snippet_text = "Patient diabetique sous metformine.",
        RECDATE = as.Date("2024-05-15"),
        RECTYPE = "note"))

spec_biol <- tibble::tibble(
    source_row_id = sprintf("biol:%03d", 1:5),
    PATID = c("P1", "P1", "P2", "P3", "P3"),
    EVTID = paste0("EV", 1:5),
    ELTID = paste0("L", 1:5),
    BIOL_ID = paste0("B", 1:5),
    DATEXAM = as.Date(c("2024-06-01", "2024-06-02", "2024-06-06",
                        "2024-06-02", "2024-06-03")),
    analyte = c("GLU.GLU", "GLU.GLU", "GLU.GLU", "NA.NA", "GLU.GLU"),
    value_raw = c("6.1", "9.4", "8.0", "140", "7.2"),
    value = c(6.1, 9.4, 8.0, 140, 7.2))

spec_sources <- list(
    documents = spec_docs,
    pmsi_diag = spec_diag,
    biology = spec_biol)

# Why: variable_spec may be written directly when no concept-specific template is
# justified. The reduction is a PLAIN FUNCTION on the payload values, declared on
# the OUTPUT (num_output(reduce =), DESIGN §8; values_from defaults to the sole
# channel) -- the executor scopes the window and reduce collapses it, so max is
# just base max(). Evidence = every in-window candidate row (the inputs reduce
# saw), not only the argmax.
test_that("direct glucose variable_spec reduces the channel with a plain function", {
    concept <- diabetes_concept_spec()
    direct <- variable_spec(
        name = "perioperative_max_glucose",
        concept = concept,
        output_one_row_per = "PATID",
        anchor = "anchor_date",
        window = c(0, 2),
        channels = list(glucose_measurements = use_channel()),
        output = num_output(reduce = function(x) max(x, na.rm = TRUE)))

    expect_null(direct$template)
    expect_setequal(names(direct$channels), "glucose_measurements")

    run <- run_variable(direct, spec_tasks, spec_sources)
    expect_equal(run$selected_channels$channel, "glucose_measurements")

    values <- setNames(run$values$value, run$values$task_id)
    expect_equal(values[["P1::t"]], 9.4)      # max(6.1, 9.4) via the plain reduce
    expect_true(is.na(values[["P2::t"]]))     # glucose exists, but outside window

    # Both in-window glucose rows for P1 are candidates -> both are evidence.
    ev <- run$evidence[run$evidence$task_id == "P1::t", ]
    expect_setequal(ev$evidence_ref, c("biol:001", "biol:002"))
    expect_true(all(ev$channel == "glucose_measurements"))
    expect_true(all(ev$source == "biology"))
})

# Why: the generic run_variable() spine must be CONCEPT-AGNOSTIC -- each channel's own
# selector drives a neutral executor, never a clinically-fixed one. Behavioural proof
# (replaces a former deparse(body()) source-text assertion): a code channel for a
# NON-diabetes family (ESRD, N18) detects N18 and reads a diabetes code as ABSENT. If
# the code branch still called measure_diabetes() (hard-wired to E10-E14), the diabetes
# row would wrongly read present. The lab branch's neutrality is proved analogously by
# the perioperative_max_glucose test above (a non-potassium analyte is measured).
test_that("run_variable's spine is concept-agnostic: the channel selector drives the executor", {
    esrd_concept <- concept_spec(
        name = "esrd",
        channels = list(
            esrd_code = code_channel(
                source = "pmsi_diag", selector = icd10("N18"),
                required_roles = c("subject_id", "event_id", "event_start",
                                   "event_end", "code", "source_item_id"),
                linkage = "subject")))
    esrd_var <- variable_spec(
        name = "esrd_status", concept = esrd_concept, output_one_row_per = "PATID",
        anchor = "anchor_date",
        window = c(-1825, 7),
        channels = list(esrd_code = use_channel()),
        output = bin_output())          # single channel -> combine_channels = NULL (membership)

    tasks <- tibble::tibble(
        task_id = c("N1::t", "N2::t"), PATID = c("N1", "N2"),
        anchor_date = as.Date("2024-06-01"))
    diag <- tibble::tibble(
        source_row_id = c("d1", "d2"), PATID = c("N1", "N2"),
        EVTID = c("E1", "E2"), ELTID = c("L1", "L2"),
        diag = c("N18.6", "E11.9"),    # N1 has ESRD; N2 has a DIABETES code (not ESRD)
        DATENT = as.Date("2024-05-20"), DATSORT = as.Date("2024-05-21"))

    run <- run_variable(esrd_var, tasks, list(pmsi_diag = diag))
    value <- setNames(run$values$value, run$values$task_id)
    expect_equal(value[["N1::t"]], 1L)   # N18 detected via the channel's OWN selector
    expect_equal(value[["N2::t"]], 0L)   # a diabetes code is ABSENT for an ESRD variable
})
