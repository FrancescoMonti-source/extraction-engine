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
    expect_s3_class(concept, "ee_concept_spec")
    expect_equal(attr(concept, "api_status"), "experimental")
    expect_setequal(
        names(concept$channels),
        c("pmsi_diag_e10_e14", "text_diabetes_mentions", "glucose_measurements"))

    tmpl <- diabetes_baseline_status_template(concept)
    baseline <- variable_spec(
        template = tmpl,
        name = "diabete_pre_greffe",
        unit = "transplant",
        anchor = "anchor_date")

    expect_s3_class(baseline, "ee_variable_spec")
    expect_equal(baseline$template, "diabetes_baseline_status_template")
    expect_setequal(
        names(baseline$channels),
        c("pmsi_diag_e10_e14", "text_diabetes_mentions"))
    expect_false("glucose_measurements" %in% names(baseline$channels))
})

# Why: #4 factored the per-concept template build() -- it was identical across the four
# concepts -- into a shared default builder, so a template may omit build=. The default
# must produce the same executable variable_spec, and an explicit build= must still be
# honoured for a template that ever needs a different assembly.
test_that("variable_template build= defaults to the shared builder and still accepts an override", {
    concept <- diabetes_concept_spec()

    # Omitted build: the default 1:1 builder assembles a working spec.
    tmpl <- diabetes_baseline_status_template(concept)
    expect_true(is.function(tmpl$build))
    spec <- variable_spec(template = tmpl, name = "diabete_pre_greffe",
                          unit = "transplant", anchor = "anchor_date")
    expect_s3_class(spec, "ee_variable_spec")
    expect_equal(spec$combine$kind, "any_positive")
    expect_setequal(names(spec$channels),
                    c("pmsi_diag_e10_e14", "text_diabetes_mentions"))

    # Explicit build= escape hatch: a template can still supply its own assembly.
    custom <- variable_template(
        name = "custom_tmpl", concept = concept, defaults = list(unit = "x"),
        build = function(params) structure(list(tag = "custom", unit = params$unit),
                                           class = "ee_variable_spec"))
    out <- variable_spec(template = custom, name = "v")
    expect_equal(out$tag, "custom")
    expect_equal(out$unit, "x")     # default param flows into the custom build
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
    channel_coverage <- setNames(run$values$channel_coverage, run$values$task_id)
    expect_equal(values[["P1::t"]], 1L)       # text channel
    expect_equal(values[["P2::t"]], 1L)       # PMSI channel
    expect_true(is.na(values[["P3::t"]]))     # text no_candidate remains partial
    expect_equal(channel_coverage[["P1::t"]], "complete")
    expect_equal(channel_coverage[["P2::t"]], "partial")

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
        output = number_output(),
        absence_policy = missing_if_no_measurement())

    expect_null(direct$template)
    expect_setequal(names(direct$channels), "glucose_measurements")

    run <- run_variable(direct, spec_tasks, spec_sources)
    expect_equal(run$selected_channels$channel, "glucose_measurements")

    values <- setNames(run$values$value, run$values$task_id)
    expect_equal(values[["P1::t"]], 9.4)
    expect_true(is.na(values[["P2::t"]]))     # glucose exists, but outside window
    expect_equal(values[["P3::t"]], 7.2)

    ev <- run$evidence[run$evidence$task_id == "P1::t", ]
    expect_equal(ev$channel, "glucose_measurements")
    expect_equal(ev$source, "biology")
    expect_equal(ev$evidence_ref, "biol:002")

    status <- run$channel_status[run$channel_status$task_id == "P1::t", ]
    expect_equal(status$status, "complete")
    expect_true(status$hit)
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
                native_grain = "diagnosis_row",
                required_roles = c("subject", "event", "interval_start",
                                   "interval_end", "code", "native_ref"),
                linkage = "subject")))
    esrd_var <- variable_spec(
        name = "esrd_status", concept = esrd_concept, unit = "patient",
        anchor = "anchor_date",
        window = before_anchor(days = 1825L, grace_days = 7L),
        channels = list(esrd_code = use_channel()),
        output = binary_output(), combine = any_positive(),
        absence_policy = open_world())

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

# ---------------------------------------------------------------------------
# Slice 1b: close the any_positive() combine gap on the SAME variable
# (diabete_pre_greffe, PMSI + text, any_positive). Same concept, no new clinical
# complexity -- this only proves the COMBINE is genuinely wired through
# run_variable(): both-positive, one-positive-one-absent, and all-complete-negative.
# ---------------------------------------------------------------------------

cg_tasks <- tibble::tibble(
    task_id = paste0("Q", 1:4, "::t"),
    PATID = paste0("Q", 1:4),
    anchor_date = as.Date("2024-06-01"))

# Q1,Q2 carry a diabetes code (positive); Q3,Q4 carry I10 (in-window, usable ->
# a COMPLETE negative, not "no PMSI data").
cg_diag <- tibble::tibble(
    source_row_id = sprintf("diag:%03d", 1:4),
    PATID = paste0("Q", 1:4),
    EVTID = paste0("EV", 1:4),
    ELTID = paste0("D", 1:4),
    diag = c("E11.9", "E11.9", "I10", "I10"),
    DATENT = as.Date("2024-05-20"),
    DATSORT = as.Date("2024-05-21"))

# Text candidates only for Q1 (-> documented) and Q4 (-> not_documented, a
# complete negative). Q2/Q3 are no_candidate, so the text channel is unavailable.
cg_docs <- list(
    coverage = tibble::tibble(
        task_id = cg_tasks$task_id,
        coverage_state = c("candidate", "no_candidate", "no_candidate", "candidate")),
    candidates = tibble::tibble(
        task_id = c("Q1::t", "Q4::t"),
        snippet_id = "S001",
        hit_ref = c("DOC_Q1::3", "DOC_Q4::3"),
        ELTID = c("DOC_Q1", "DOC_Q4"),
        sentence = 3L,
        hit_text = "Patient diabetique.",
        snippet_text = "Patient diabetique sous metformine.",
        RECDATE = as.Date("2024-05-15"),
        RECTYPE = "note"))

cg_sources <- list(documents = cg_docs, pmsi_diag = cg_diag)

cg_fake <- function(prompt, type, system_prompt) {
    if (grepl("Q1::t", prompt, fixed = TRUE)) {
        return(list(diabetes_status = "documented", evidence_ids = list("S001")))
    }
    list(diabetes_status = "not_documented", evidence_ids = list())   # Q4
}

# Why: any_positive() must be genuinely wired through run_variable() across the
# four combine outcomes, evidence from EVERY positive channel must survive, and
# ascertainment must stay complete-vs-partial (text no_candidate is not absence).
test_that("any_positive combine is wired through run_variable across the gap cases", {
    baseline <- variable_spec(
        template = diabetes_baseline_status_template(),
        name = "diabete_pre_greffe", unit = "transplant", anchor = "anchor_date")
    run <- run_variable(baseline, cg_tasks, cg_sources,
                        caller = cg_fake, model_name = "fake")

    values <- setNames(run$values$value, run$values$task_id)
    cov <- setNames(run$values$channel_coverage, run$values$task_id)

    expect_equal(values[["Q1::t"]], 1L)        # PMSI + text both positive
    expect_equal(values[["Q2::t"]], 1L)        # PMSI positive + text no_candidate
    expect_true(is.na(values[["Q3::t"]]))      # PMSI negative + text no_candidate -> not absence
    expect_equal(values[["Q4::t"]], 0L)        # both complete, no positive -> documented negative

    expect_equal(cov[["Q1::t"]], "complete")
    expect_equal(cov[["Q2::t"]], "partial")    # text channel not evaluable
    expect_equal(cov[["Q3::t"]], "partial")
    expect_equal(cov[["Q4::t"]], "complete")

    # Evidence from BOTH positive channels survives for Q1.
    q1_ev <- run$evidence[run$evidence$task_id == "Q1::t", ]
    expect_setequal(q1_ev$channel,
                    c("pmsi_diag_e10_e14", "text_diabetes_mentions"))
    ref <- setNames(q1_ev$evidence_ref, q1_ev$channel)
    expect_equal(ref[["pmsi_diag_e10_e14"]], "diag:001")
    expect_equal(ref[["text_diabetes_mentions"]], "DOC_Q1::3")

    # A documented negative (Q4) carries no positive evidence.
    expect_equal(nrow(run$evidence[run$evidence$task_id == "Q4::t", ]), 0L)

    # Per-channel status: Q1 both complete + positive; Q4 both complete + negative.
    q1_status <- run$channel_status[run$channel_status$task_id == "Q1::t", ]
    expect_true(all(q1_status$status == "complete"))
    expect_true(all(q1_status$hit))
    q4_status <- run$channel_status[run$channel_status$task_id == "Q4::t", ]
    expect_true(all(q4_status$status == "complete"))
    expect_true(all(!q4_status$hit))
})

# ---------------------------------------------------------------------------
# Multi-source resilience + window scoping through the spine. Re-pins the two
# invariants the retired pre-spine diabetes spike (test-multisource-diabetes.R)
# uniquely covered: a positive in one channel survives a model error in another,
# and out-of-window evidence does not establish a positive. The heterogeneous
# code+text any_positive matrix, the no_candidate-is-not-absence policy, and
# cross-channel provenance are already covered by the gap-cases test above.
# ---------------------------------------------------------------------------

ms_tasks <- tibble::tibble(
    task_id = c("R1::t", "R2::t"), PATID = c("R1", "R2"),
    anchor_date = as.Date("2024-06-01"))

# R1: in-window diabetes code (a hit). R2: diabetes code dated WELL before the
# 5-year window (must NOT count as a positive).
ms_diag <- tibble::tibble(
    source_row_id = c("diag:R1", "diag:R2"),
    PATID = c("R1", "R2"), EVTID = c("E1", "E2"), ELTID = c("D1", "D2"),
    diag = c("E11.9", "E11.9"),
    DATENT = c(as.Date("2024-05-20"), as.Date("2015-01-01")),
    DATSORT = c(as.Date("2024-05-21"), as.Date("2015-01-02")))

# R1 has a retrieved text candidate (the model will ERROR on it); R2 is no_candidate.
ms_docs <- list(
    coverage = tibble::tibble(
        task_id = ms_tasks$task_id, coverage_state = c("candidate", "no_candidate")),
    candidates = tibble::tibble(
        task_id = "R1::t", snippet_id = "S001", hit_ref = "DOC_R1::3",
        ELTID = "DOC_R1", sentence = 3L, hit_text = "diabete",
        snippet_text = "Patient diabetique.", RECDATE = as.Date("2024-05-15"),
        RECTYPE = "note"))

ms_sources <- list(documents = ms_docs, pmsi_diag = ms_diag)

# The text model fails (non-transient) on R1's task.
ms_fake <- function(prompt, type, system_prompt) {
    if (grepl("R1::t", prompt, fixed = TRUE)) stop("synthetic text model failure")
    list(diabetes_status = "not_documented", evidence_ids = list())   # R2
}

ms_baseline <- function() variable_spec(
    template = diabetes_baseline_status_template(),
    name = "diabete_pre_greffe", unit = "transplant", anchor = "anchor_date")

# Why: a positive in the code channel must survive a model error in the text channel
# (heterogeneous failure resilience); the result must flag partial coverage and keep
# the failed channel auditable -- never lose the code positive or hide the failure.
test_that("any_positive survives a text-channel model error and keeps code provenance", {
    run <- run_variable(ms_baseline(), ms_tasks, ms_sources,
                        caller = ms_fake, model_name = "fake")
    value <- setNames(run$values$value, run$values$task_id)
    cov <- setNames(run$values$channel_coverage, run$values$task_id)

    expect_equal(value[["R1::t"]], 1L)         # code positive survives the text error
    expect_equal(cov[["R1::t"]], "partial")    # ...and coverage flags the unevaluable text

    ss <- run$channel_status
    text_status <- ss$status[ss$task_id == "R1::t" &
                             ss$channel == "text_diabetes_mentions"]
    expect_equal(text_status, "error")          # the failure is auditable, not hidden

    # provenance: the code channel's evidence survives the text failure
    ev1 <- run$evidence[run$evidence$task_id == "R1::t", ]
    expect_equal(ev1$channel, "pmsi_diag_e10_e14")
    expect_equal(ev1$evidence_ref, "diag:R1")
})

# Why: evidence dated outside the variable's window must not establish a positive --
# the window is enforced end-to-end through the spine, not only in the executor unit.
test_that("out-of-window code does not count as a positive through the spine", {
    run <- run_variable(ms_baseline(), ms_tasks, ms_sources,
                        caller = ms_fake, model_name = "fake")
    value <- setNames(run$values$value, run$values$task_id)

    # R2: E11 dated 2015 is out of the 5-year window + text no_candidate -> not a hit
    expect_true(is.na(value[["R2::t"]]))
    code_contrib <- run$channel_status$contribution[
        run$channel_status$task_id == "R2::t" &
        run$channel_status$channel == "pmsi_diag_e10_e14"]
    expect_equal(code_contrib, "negative")      # out-of-window -> ascertained negative
})
