# Contract tests for slice 3: a multi-field text concept. ONE extraction task ->
# SEVERAL output fields, with FIELD-LEVEL acceptance (a valid grounded field survives an
# invalid sibling) and the task flagged for review iff any field is invalid or the
# call failed. Synthetic data, deterministic fake model. Architecture boundaries,
# not clinical truth.

ana_tasks <- tibble::tibble(
    grain_id = paste0("A", 1:3, "::t"),
    PATID = paste0("R", 1:3),
    EVTID = paste0("E", 1:3),
    anchor_date = as.Date("2024-03-10"))

# prompt_anastomoses() echoes anchor_date and the snippet block (not the task id),
# so the fake keys on the distinct snippet_text and coverage carries anchor_date.
ana_docs <- list(
    coverage = tibble::tibble(
        grain_id = ana_tasks$grain_id,
        coverage_state = c("candidate", "no_candidate", "candidate"),
        anchor_date = as.Date("2024-03-10")),
    candidates = tibble::tibble(
        grain_id = c("A1::t", "A3::t"),
        snippet_id = "S001",
        hit_ref = c("OP1::2", "OP3::2"),
        ELTID = c("OP1", "OP3"),
        EVTID = ana_tasks$EVTID[c(1, 3)],
        sentence = 2L,
        hit_text = "Anastomose arterielle termino-laterale.",
        snippet_text = c("CASE_A1_MULTI", "CASE_A3_ERROR"),
        RECDATE = as.Date("2024-03-09"),
        RECTYPE = "CRO"))

ana_sources <- list(documents = ana_docs)

ana_fake <- function(prompt, type, system_prompt) {
    if (grepl("CASE_A3_ERROR", prompt, fixed = TRUE)) {
        stop("synthetic operative-report extraction failure")
    }
    # A1: all fields default to not_documented (valid, no value), then override.
    res <- setNames(
        lapply(names(ANASTOMOSES_FIELDS),
               function(f) list(status = "not_documented", evidence_ids = list())),
        names(ANASTOMOSES_FIELDS))
    res$transplantation_type_anastomose_arterielle <-          # valid string
        list(status = "documented", value = "termino-laterale",
             evidence_ids = list("S001"))
    res$transplantation_duree_anastomose_veineuse <-           # valid integer
        list(status = "documented", value = 18L, evidence_ids = list("S001"))
    res$transplantation_type_anastomose_ureterale <-           # INVALID: documented w/o evidence
        list(status = "documented", value = "Gregoir", evidence_ids = list())
    res[[ANASTOMOSES_SUMMARY]] <- "resume des anastomoses retenues"
    res
}

anastomoses_var <- function() {
    recipient_anastomoses(
        name = "recipient_anastomoses", anchor = "anchor_date")
}

# Why: one task yields several fields, and acceptance is FIELD-LEVEL -- a valid
# grounded field keeps its value even when a sibling field is invalid, while the
# task is still flagged for review.
test_that("struct output keeps valid fields and flags the task on an invalid sibling", {
    run <- run_variable(anastomoses_var(), ana_tasks, ana_sources,
                        chat = fake_chat(ana_fake))

    a1 <- run$values[run$values$grain_id == "A1::t", ]
    val <- setNames(a1$value, a1$field)
    validity <- setNames(a1$field_validity, a1$field)

    expect_equal(val[["transplantation_type_anastomose_arterielle"]], "termino-laterale")
    expect_equal(validity[["transplantation_type_anastomose_arterielle"]], "valid")
    expect_equal(validity[["transplantation_type_anastomose_ureterale"]], "invalid")
    expect_true(is.na(val[["transplantation_type_anastomose_ureterale"]]))   # invalid not accepted

    # Per-task channel status: the call produced fields; one invalid -> needs_review.
    ss1 <- run$channel_status[run$channel_status$grain_id == "A1::t", ]
    expect_equal(ss1$status, "complete")
    expect_true(ss1$needs_review)

    # Evidence is per field; the invalid (un-evidenced) field materializes none.
    ev1 <- run$evidence[run$evidence$grain_id == "A1::t", ]
    art_ev <- ev1[ev1$field == "transplantation_type_anastomose_arterielle", ]
    expect_equal(art_ev$evidence_ref, "OP1::2")
    expect_equal(nrow(ev1[ev1$field == "transplantation_type_anastomose_ureterale", ]), 0L)
})

# Why: no_candidate and a failed call must stay distinct from extracted fields, and
# a failed task must be flagged for review (not silently absent).
test_that("struct output distinguishes no_candidate and a failed call", {
    run <- run_variable(anastomoses_var(), ana_tasks, ana_sources,
                        chat = fake_chat(ana_fake))

    ss <- run$channel_status
    a2 <- ss[ss$grain_id == "A2::t", ]
    expect_equal(a2$status, "unavailable")        # no_candidate
    expect_false(a2$needs_review)

    a3 <- ss[ss$grain_id == "A3::t", ]
    expect_equal(a3$status, "error")              # model errored
    expect_true(a3$needs_review)
})

test_that("struct field-contract failures are isolated per task", {
    # Output contract + failure isolation: extra and missing field sets become
    # processing errors without aborting or discarding a valid sibling task.
    variable <- resolve_variable_spec(anastomoses_var())
    fields <- names(ANASTOMOSES_FIELDS)
    result <- list(
        coverage = tibble::tibble(
            task_id = c("bad_field", "empty", "good"),
            processing_state = "valid"),
        values = dplyr::bind_rows(
            tibble::tibble(
                task_id = "bad_field", field = "undeclared_field",
                accepted_value = "x", field_validity = "valid",
                citation_warning = FALSE, validity_reason = "",
                task_summary = NA_character_),
            tibble::tibble(
                task_id = "good", field = fields,
                accepted_value = NA_character_, field_validity = "valid",
                citation_warning = FALSE, validity_reason = "",
                task_summary = NA_character_)),
        evidence = tibble::tibble())
    tasks <- tibble::tibble(task_id = c("bad_field", "empty", "good"))

    corrected <- .enforce_struct_output_contract(variable, tasks, result)
    state <- setNames(corrected$coverage$processing_state,
                      corrected$coverage$task_id)

    expect_equal(state[["bad_field"]], "processing_error")
    expect_equal(state[["empty"]], "processing_error")
    expect_equal(state[["good"]], "valid")
    expect_equal(unique(corrected$values$task_id), "good")

    out <- .multi_field_variable(
        variable, tasks, "text_operative_report", corrected)
    status <- setNames(out$channel_status$status, out$channel_status$task_id)
    expect_equal(status[["bad_field"]], "error")
    expect_equal(status[["empty"]], "error")
    expect_equal(status[["good"]], "complete")
    expect_equal(nrow(out$values), length(fields))
})

test_that("a missing required summary remains visible for review", {
    # Failure-observability contract: task-level invalidity must not disappear
    # merely because every individual field parsed as valid.
    variable <- resolve_variable_spec(anastomoses_var())
    fields <- names(ANASTOMOSES_FIELDS)
    result <- list(
        coverage = tibble::tibble(task_id = "task", processing_state = "invalid"),
        values = tibble::tibble(
            task_id = rep("task", length(fields)), field = fields,
            accepted_value = NA_character_, field_validity = "valid",
            citation_warning = FALSE, validity_reason = "",
            task_summary = NA_character_),
        evidence = tibble::tibble())

    result <- .enforce_struct_output_contract(
        variable, tibble::tibble(task_id = "task"), result)
    out <- .multi_field_variable(
        variable, tibble::tibble(task_id = "task"),
        "text_operative_report", result)

    expect_true(out$channel_status$needs_review)
})
