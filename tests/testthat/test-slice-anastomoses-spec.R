# Contract tests for slice 3: a multi-field text concept. ONE extraction task ->
# SEVERAL fields, with FIELD-LEVEL acceptance (a valid grounded field survives an
# invalid sibling) and the task flagged for review iff any field is invalid or the
# call failed. Synthetic data, deterministic fake model. Architecture boundaries,
# not clinical truth.

ana_tasks <- tibble::tibble(
    task_id = paste0("A", 1:3, "::t"),
    PATID = paste0("R", 1:3),
    EVTID = paste0("E", 1:3),
    anchor_date = as.Date("2024-03-10"))

# prompt_anastomoses() echoes anchor_date and the snippet block (not the task id),
# so the fake keys on the distinct snippet_text and coverage carries anchor_date.
ana_docs <- list(
    coverage = tibble::tibble(
        task_id = ana_tasks$task_id,
        coverage_state = c("candidate", "no_candidate", "candidate"),
        anchor_date = as.Date("2024-03-10")),
    candidates = tibble::tibble(
        task_id = c("A1::t", "A3::t"),
        snippet_id = "S001",
        hit_ref = c("OP1::2", "OP3::2"),
        ELTID = c("OP1", "OP3"),
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
    variable_spec(
        template = recipient_anastomoses_template(),
        name = "recipient_anastomoses", unit = "transplant", anchor = "anchor_date")
}

# Why: a multi-field concept must be expressible with no date window (it is
# event-scoped). The output is a SET of cohort columns collapsed by collect_fields.
test_that("anastomoses concept is multi-field, event-scoped, with no date window", {
    concept <- anastomoses_concept_spec()
    expect_equal(concept$name, "transplant_anastomoses")
    expect_setequal(concept$channels$text_operative_report$linkage,
                    c("subject", "event"))

    var <- anastomoses_var()
    expect_null(var$window)                       # event scope, not a date window
    expect_equal(var$combine$kind, "collect_fields")
    expect_equal(var$output$kind, "fields")
    expect_setequal(var$output$fields, names(ANASTOMOSES_FIELDS))
})

# Why: one task yields several fields, and acceptance is FIELD-LEVEL -- a valid
# grounded field keeps its value even when a sibling field is invalid, while the
# task is still flagged for review.
test_that("collect_fields keeps valid fields and flags the task on an invalid sibling", {
    run <- run_variable(anastomoses_var(), ana_tasks, ana_sources,
                        caller = ana_fake, model_name = "fake")

    a1 <- run$values[run$values$task_id == "A1::t", ]
    val <- setNames(a1$value, a1$field)
    validity <- setNames(a1$field_validity, a1$field)

    expect_equal(val[["transplantation_type_anastomose_arterielle"]], "termino-laterale")
    expect_equal(val[["transplantation_duree_anastomose_veineuse"]], "18")
    expect_equal(validity[["transplantation_type_anastomose_arterielle"]], "valid")
    expect_equal(validity[["transplantation_type_anastomose_ureterale"]], "invalid")
    expect_true(is.na(val[["transplantation_type_anastomose_ureterale"]]))   # invalid not accepted
    # a not_documented field is valid with no value (absence is not invalidity)
    expect_equal(validity[["transplantation_duree_anastomose_arterielle"]], "valid")
    expect_true(is.na(val[["transplantation_duree_anastomose_arterielle"]]))

    # Per-task channel status: the call produced fields; one invalid -> needs_review.
    ss1 <- run$channel_status[run$channel_status$task_id == "A1::t", ]
    expect_equal(ss1$status, "complete")
    expect_equal(ss1$n_fields, 5L)
    expect_equal(ss1$n_valid, 4L)
    expect_equal(ss1$n_invalid, 1L)
    expect_true(ss1$needs_review)

    # Evidence is per field; the invalid (un-evidenced) field materializes none.
    ev1 <- run$evidence[run$evidence$task_id == "A1::t", ]
    art_ev <- ev1[ev1$field == "transplantation_type_anastomose_arterielle", ]
    expect_equal(art_ev$evidence_ref, "OP1::2")
    expect_equal(nrow(ev1[ev1$field == "transplantation_type_anastomose_ureterale", ]), 0L)
})

# Why: no_candidate and a failed call must stay distinct from extracted fields, and
# a failed task must be flagged for review (not silently absent).
test_that("collect_fields distinguishes no_candidate and a failed call", {
    run <- run_variable(anastomoses_var(), ana_tasks, ana_sources,
                        caller = ana_fake, model_name = "fake")

    expect_equal(nrow(run$values[run$values$task_id == "A2::t", ]), 0L)  # no fields
    ss <- run$channel_status
    a2 <- ss[ss$task_id == "A2::t", ]
    expect_equal(a2$status, "unavailable")        # no_candidate
    expect_false(a2$needs_review)

    a3 <- ss[ss$task_id == "A3::t", ]
    expect_equal(a3$status, "error")              # model errored
    expect_true(a3$needs_review)
    expect_equal(nrow(run$values[run$values$task_id == "A3::t", ]), 0L)
})

# Why: D1 keep-and-flag is now consistent across text parsers (owner-ratified, #3).
# An anastomoses field grounded by >=1 real id is KEPT and flagged when the model also
# cites an unsupplied id -- no longer failed closed (the pre-#3 behaviour). The flag
# surfaces in the envelope: per-field on values, per-task on the channel status. The
# invented id never materializes as evidence.
test_that("collect_fields keeps-and-flags an invented citation (no longer fail-closed)", {
    cw_fake <- function(prompt, type, system_prompt) {
        res <- setNames(
            lapply(names(ANASTOMOSES_FIELDS),
                   function(f) list(status = "not_documented", evidence_ids = list())),
            names(ANASTOMOSES_FIELDS))
        res$transplantation_type_anastomose_arterielle <-      # one real + one fabricated id
            list(status = "documented", value = "termino-laterale",
                 evidence_ids = list("S001", "S999"))
        res[[ANASTOMOSES_SUMMARY]] <- "resume des anastomoses retenues"
        res
    }
    run <- run_variable(anastomoses_var(), ana_tasks[1, ], ana_sources,
                        caller = cw_fake, model_name = "fake")

    art <- run$values[run$values$task_id == "A1::t" &
                      run$values$field == "transplantation_type_anastomose_arterielle", ]
    expect_equal(art$value, "termino-laterale")    # kept, not dropped
    expect_equal(art$field_validity, "valid")
    expect_true(art$citation_warning)              # flagged per field

    ss1 <- run$channel_status[run$channel_status$task_id == "A1::t", ]
    expect_true(ss1$citation_warning)              # per-task flag surfaces in channel status
    expect_false(ss1$needs_review)                 # a flagged-but-valid field is not a review trigger

    # The real id grounds the value; the fabricated id never materializes as evidence.
    art_ev <- run$evidence[run$evidence$task_id == "A1::t" &
                           run$evidence$field == "transplantation_type_anastomose_arterielle", ]
    expect_equal(art_ev$evidence_ref, "OP1::2")
})

# Why: anastomoses is EVENT-scoped -- eligibility is the subject's documents from the
# SAME surgical event (PATID + EVTID), NOT a date window. run_variable() must retrieve
# from RAW operative-report documents end-to-end (the seam, previously fixtures-only):
# a same-patient document from a DIFFERENT event must be excluded even though it
# mentions anastomoses.
test_that("event-scoped anastomoses retrieves from raw docs by PATID+EVTID", {
    ev_tasks <- tibble::tibble(
        task_id = "RA::t", PATID = "RA", EVTID = "EVT1", anchor_date = as.Date("2024-03-10"))
    ev_docs_index <- tibble::tibble(
        ELTID   = c("CRO_IN", "CRO_OTHER"),
        PATID   = c("RA", "RA"),
        EVTID   = c("EVT1", "EVT9"),              # second doc: SAME patient, OTHER event
        RECDATE = as.Date(c("2024-03-10", "2019-01-01")),
        RECTYPE = "CRO")
    ev_corpus <- corpustools::create_tcorpus(
        data.frame(
            ELTID = c("CRO_IN", "CRO_OTHER"),
            RECTXT = c("Anastomose arterielle termino-laterale sur artere iliaque externe.",
                       "Anastomose arterielle d'une autre greffe anterieure."),
            stringsAsFactors = FALSE),
        text_columns = "RECTXT", doc_column = "ELTID",
        split_sentences = TRUE, remember_spaces = FALSE, verbose = FALSE)
    ev_sources <- list(documents = list(corpus = ev_corpus, docs_index = ev_docs_index))

    ev_fake <- function(prompt, type, system_prompt) {
        res <- setNames(
            lapply(names(ANASTOMOSES_FIELDS),
                   function(f) list(status = "not_documented", evidence_ids = list())),
            names(ANASTOMOSES_FIELDS))
        res$transplantation_type_anastomose_arterielle <-   # ground on the lone in-event snippet
            list(status = "documented", value = "termino-laterale", evidence_ids = list("S001"))
        res[[ANASTOMOSES_SUMMARY]] <- "resume"
        res
    }

    run <- run_variable(anastomoses_var(), ev_tasks, ev_sources,
                        caller = ev_fake, model_name = "fake")

    art <- run$values[run$values$field == "transplantation_type_anastomose_arterielle", ]
    expect_equal(art$value, "termino-laterale")          # extracted from the in-event report
    # Evidence grounds in the in-event document only; the other event never appears.
    expect_true(all(grepl("^CRO_IN::", run$evidence$evidence_ref)))
    expect_false(any(grepl("^CRO_OTHER", run$evidence$evidence_ref)))
})
