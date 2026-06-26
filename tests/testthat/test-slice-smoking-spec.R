# Contract tests for slice 2: a NEUTRAL smoking concept + documented-status
# template -> categorical text variable. Synthetic data, deterministic fake model.
# Protects architecture boundaries (categorical output, single-channel assembly,
# abstention, invalid->needs_review, no_candidate, and D1 keep-and-flag), not
# clinical truth for smoking.

# Per-task snippet markers: prompt_smoking() does not echo the task id, so the fake
# keys on the (distinct) snippet_text it is shown.
sm_tasks <- tibble::tibble(
    task_id = paste0("T", 1:6, "::t"),
    PATID = paste0("S", 1:6),
    anchor_date = as.Date("2024-06-01"))

sm_docs <- list(
    coverage = tibble::tibble(
        task_id = sm_tasks$task_id,
        coverage_state = c("candidate", "candidate", "no_candidate",
                           "candidate", "candidate", "candidate")),
    candidates = tibble::tibble(
        task_id = c("T1::t", "T2::t", "T4::t", "T5::t", "T6::t"),
        snippet_id = "S001",
        hit_ref = c("D1::3", "D2::3", "D4::3", "D5::3", "D6::3"),
        ELTID = c("D1", "D2", "D4", "D5", "D6"),
        sentence = 3L,
        hit_text = "Tabac.",
        snippet_text = c("CASE_ACTIF", "CASE_INDET", "CASE_SEVRE_NOEV",
                         "CASE_REAL_PLUS_INVENTED", "CASE_ONLY_INVENTED"),
        RECDATE = as.Date("2024-05-15"),
        RECTYPE = "note"))

sm_sources <- list(documents = sm_docs)

sm_fake <- function(prompt, type, system_prompt) {
    if (grepl("CASE_ACTIF", prompt, fixed = TRUE)) {
        return(list(smoking_status = "actif", evidence_ids = list("S001"),
                    decision_note = "actif documente"))
    }
    if (grepl("CASE_INDET", prompt, fixed = TRUE)) {
        return(list(smoking_status = "indetermine", evidence_ids = list(),
                    decision_note = "preuves contradictoires"))
    }
    if (grepl("CASE_SEVRE_NOEV", prompt, fixed = TRUE)) {
        return(list(smoking_status = "sevre", evidence_ids = list(),
                    decision_note = "sans preuve citee"))
    }
    if (grepl("CASE_REAL_PLUS_INVENTED", prompt, fixed = TRUE)) {
        return(list(smoking_status = "actif", evidence_ids = list("S001", "S999"),
                    decision_note = "un id reel + un invente"))
    }
    if (grepl("CASE_ONLY_INVENTED", prompt, fixed = TRUE)) {
        return(list(smoking_status = "actif", evidence_ids = list("S999"),
                    decision_note = "seulement un id invente"))
    }
    list(smoking_status = "indetermine", evidence_ids = list(), decision_note = "")
}

smoking_periop <- function() {
    variable_spec(
        template = documented_smoking_status_periop_template(),
        name = "tabac_statut_periop", unit = "transplant", anchor = "anchor_date")
}

# Why: the concept must stay neutral -- it declares only where smoking text lives.
# "Documented current status" is a template/activation choice (the categorical
# answer schema, output, and collapse), so the concept could later feed a different
# smoking observation (pack-years, lifetime) without changing.
test_that("smoking concept is neutral; documented status lives in the template", {
    concept <- smoking_concept_spec()
    expect_equal(concept$name, "smoking")
    expect_setequal(names(concept$channels), "text_smoking_mentions")
    expect_null(concept$channels$text_smoking_mentions$extractor)   # neutral concept

    smk <- smoking_periop()
    expect_equal(smk$template, "documented_smoking_status_periop_template")
    expect_false(is.null(smk$channels$text_smoking_mentions$extractor))  # activation owns it
    expect_equal(smk$output$kind, "categorical")
    expect_setequal(smk$output$levels, SMOKING_STATUSES)
    expect_null(smk$combine)        # single channel: categorical output drives assembly

})

# Why: single-channel categorical assembly (combine = NULL, output = categorical)
# must carry a CATEGORICAL value and keep the three non-positive outcomes distinct --
# indetermine (model judged evidence inconclusive) is a real ascertained value, while
# no_candidate (nothing retrieved) and invalid (definitive without grounding) are not.
test_that("categorical output returns the status and distinct absence states", {
    run <- run_variable(smoking_periop(), sm_tasks, sm_sources,
                        caller = sm_fake, model_name = "fake")

    value <- setNames(run$values$value, run$values$task_id)
    cov <- setNames(run$values$channel_coverage, run$values$task_id)
    nr <- setNames(run$values$needs_review, run$values$task_id)

    expect_equal(value[["T1::t"]], "actif")        # documented status transcribed
    expect_equal(cov[["T1::t"]], "complete")
    expect_equal(value[["T2::t"]], "indetermine")  # abstention is a VALID ascertained value
    expect_false(nr[["T2::t"]])
    expect_true(is.na(value[["T3::t"]]))            # no_candidate -> not ascertained
    expect_equal(cov[["T3::t"]], "partial")
    expect_true(is.na(value[["T4::t"]]))            # definitive without evidence -> invalid
    expect_true(nr[["T4::t"]])

    ss <- run$channel_status
    expect_equal(ss$status[ss$task_id == "T1::t"], "complete")
    expect_equal(ss$status[ss$task_id == "T3::t"], "unavailable")
    expect_equal(ss$status[ss$task_id == "T4::t"], "invalid")

    # T1's value is grounded by its real evidence sentence.
    t1_ev <- run$evidence[run$evidence$task_id == "T1::t", ]
    expect_equal(t1_ev$evidence_ref, "D1::3")
    expect_equal(t1_ev$source, "documents")
})

# Why: D1 keep-and-flag (owner-ratified). A status grounded by >=1 real id is kept
# even if the model also cites an unsupplied id -- surfaced as a structured
# citation_warning, NOT silently dropped and NOT buried in free text. A status
# grounded ONLY by an invented id has no real grounding and is still rejected. The
# invented id never materializes as evidence.
test_that("D1: invented citation is kept-and-flagged, not fail-closed", {
    run <- run_variable(smoking_periop(), sm_tasks, sm_sources,
                        caller = sm_fake, model_name = "fake")
    value <- setNames(run$values$value, run$values$task_id)
    cw <- setNames(run$values$citation_warning, run$values$task_id)
    nr <- setNames(run$values$needs_review, run$values$task_id)

    # T5: one real id + one invented -> value KEPT, flagged, not flagged for review.
    expect_equal(value[["T5::t"]], "actif")
    expect_true(cw[["T5::t"]])
    expect_false(nr[["T5::t"]])
    # Only the real id materializes as evidence; the invented one never does.
    t5_ev <- run$evidence[run$evidence$task_id == "T5::t", ]
    expect_equal(t5_ev$evidence_ref, "D5::3")
    expect_false("S999" %in% run$evidence$source_row_id)

    # T6: only an invented id -> no real grounding -> invalid + flagged, no value.
    expect_true(is.na(value[["T6::t"]]))
    expect_true(cw[["T6::t"]])
    expect_true(nr[["T6::t"]])
    expect_equal(nrow(run$evidence[run$evidence$task_id == "T6::t", ]), 0L)

    # No warning on the clean cases.
    expect_false(cw[["T1::t"]])
})
