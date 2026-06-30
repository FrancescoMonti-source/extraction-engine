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

spec_fake_docs <- function(prompt, type, system_prompt) {
    if (grepl("P1::t", prompt, fixed = TRUE)) {
        return(list(diabetes_status = "documented", evidence_ids = list("S001")))
    }
    list(diabetes_status = "not_documented", evidence_ids = list())
}

# Why: concept_spec should declare possible diabetes signal channels without using
# them by default. The baseline template is concept-specific and activates only
# the channels it needs, so glucose remains available for another variable.
test_that("diabetes concept and baseline template select channels explicitly", {
    concept <- diabetes_concept_spec()
    expect_setequal(
        names(concept$channels),
        c("pmsi_diag_e10_e14", "text_diabetes_mentions", "glucose_measurements"))

    tmpl <- diabetes_baseline_status_template(concept)
    baseline <- variable_spec(
        template = tmpl,
        name = "diabete_pre_greffe",
        unit = "transplant",
        anchor = "anchor_date")

    expect_equal(baseline$template, "diabetes_baseline_status_template")
    expect_setequal(
        names(baseline$channels),
        c("pmsi_diag_e10_e14", "text_diabetes_mentions"))
    expect_false("glucose_measurements" %in% names(baseline$channels))
})

# Why: the executable slice must preserve the formal boundary: selected channels
# resurface source-specific signals, variable_spec combines them, and output keeps
# final value, per-channel status, and evidence refs instead of hiding judgment.
test_that("baseline diabetes variable from template returns traceable output", {
    concept <- diabetes_concept_spec()
    baseline <- variable_spec(
        template = diabetes_baseline_status_template(concept),
        name = "diabete_pre_greffe",
        unit = "transplant",
        anchor = "anchor_date")

    run <- run_variable(
        baseline, spec_tasks, spec_sources,
        caller = spec_fake_docs, model_name = "fake")

    expect_equal(
        run$selected_channels$channel,
        c("pmsi_diag_e10_e14", "text_diabetes_mentions"))

    values <- setNames(run$values$value, run$values$task_id)
    expect_equal(values[["P1::t"]], 1L)       # text channel
    expect_equal(values[["P2::t"]], 1L)       # PMSI channel
    expect_equal(values[["P3::t"]], 0L)       # no observed hit -> 0; uncertainty rides on coverage

    p1_text <- run$channel_status[
        run$channel_status$task_id == "P1::t" &
            run$channel_status$channel == "text_diabetes_mentions", ]
    expect_equal(p1_text$status, "complete")
    expect_true(p1_text$hit)

    p2_ev <- run$evidence[
        run$evidence$task_id == "P2::t" &
            run$evidence$channel == "pmsi_diag_e10_e14", ]
    expect_equal(p2_ev$source, "pmsi_diag")
    expect_equal(p2_ev$evidence_ref, "diag:002")
})

# Why: variable_spec may be written directly when no concept-specific template is
# justified. Generic helpers like max_value() are operators inside that spec, not
# user-facing variable templates.
test_that("direct glucose variable_spec uses a helper without becoming a template", {
    concept <- diabetes_concept_spec()
    direct <- variable_spec(
        name = "perioperative_max_glucose",
        concept = concept,
        unit = "surgery",
        anchor = "anchor_date",
        window = days_after(0L, 2L),
        channels = list(
            glucose_measurements = use_channel(reducer = max_value())),
        output = num_output())

    expect_null(direct$template)
    expect_setequal(names(direct$channels), "glucose_measurements")

    run <- run_variable(direct, spec_tasks, spec_sources)
    expect_equal(run$selected_channels$channel, "glucose_measurements")

    values <- setNames(run$values$value, run$values$task_id)
    expect_equal(values[["P1::t"]], 9.4)
    expect_true(is.na(values[["P2::t"]]))     # glucose exists, but outside window

    ev <- run$evidence[run$evidence$task_id == "P1::t", ]
    expect_equal(ev$channel, "glucose_measurements")
    expect_equal(ev$source, "biology")
    expect_equal(ev$evidence_ref, "biol:002")
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
        name = "esrd_status", concept = esrd_concept, unit = "patient",
        anchor = "anchor_date",
        window = before_anchor(days = 1825L, grace_days = 7L),
        channels = list(esrd_code = use_channel()),
        output = bin_output())          # single channel -> combine = NULL (membership)

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
