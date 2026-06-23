# Contract tests for the integrated baseline. No provider calls, no patient data;
# the model is an injected fake (signature: function(prompt, type, system_prompt)).

make_corpus <- function(eltids, texts) {
    corpustools::create_tcorpus(
        data.frame(ELTID = eltids, RECTXT = texts, stringsAsFactors = FALSE),
        text_columns = "RECTXT", doc_column = "ELTID",
        split_sentences = TRUE, remember_spaces = FALSE, verbose = FALSE)
}

empty_anastomoses_result <- function() {
    res <- setNames(
        replicate(length(ANASTOMOSES_FIELDS),
                  list(status = "not_documented", evidence_ids = list()), simplify = FALSE),
        names(ANASTOMOSES_FIELDS))
    res[[ANASTOMOSES_SUMMARY]] <- "resume"
    res
}

ana_tasks <- function() tibble::tibble(task_id = "P1::2025-03-10::EV1", PATID = "P1",
                                       EVTID = "EV1", anchor_date = as.Date("2025-03-10"))

test_that("retrieval is scoped to the resolved eligibility relation (event scope)", {
    docs_index <- tibble::tibble(
        ELTID = c("E1", "E2", "E3"), PATID = c("P1", "P1", "P2"),
        EVTID = c("EV1", "OTHER", "EV1"), RECDATE = as.Date("2025-03-10"), RECTYPE = "CRO")
    tasks <- ana_tasks()
    elig <- anastomoses_eligibility(tasks, docs_index)
    expect_setequal(elig$ELTID, "E1")
    corpus <- make_corpus(c("E1", "E2", "E3"),
        c("Anastomose arterielle termino-laterale sur artere iliaque externe.",
          "Anastomose veineuse ailleurs.", "Technique de Gregoir ailleurs."))
    r <- retrieve(corpus, tasks, elig, ANASTOMOSES_QUERY)
    expect_true(nrow(r$candidates) >= 1L)
    expect_true(all(r$candidates$ELTID == "E1"))
    expect_equal(r$coverage$n_eligible_documents, 1L)
})

test_that("smoking scope is the date window (patient-based), not the event", {
    docs_index <- tibble::tibble(
        ELTID = c("E1", "E2", "E3"), PATID = "P1", EVTID = c("EV1", "EV1", "EVother"),
        RECDATE = as.Date(c("2025-03-09", "2020-01-01", "2025-03-08")), RECTYPE = "note")
    tasks <- tibble::tibble(task_id = "P1::2025-03-10::EV1", PATID = "P1",
                            EVTID = "EV1", anchor_date = as.Date("2025-03-10"))
    elig <- smoking_eligibility(tasks, docs_index)
    expect_setequal(elig$ELTID, c("E1", "E3"))
})

test_that("a snippet ID maps to the exact model-visible snippet it was given", {
    docs_index <- tibble::tibble(ELTID = "E1", PATID = "P1", EVTID = "EV1",
                                 RECDATE = as.Date("2025-03-10"), RECTYPE = "CRO")
    tasks <- ana_tasks(); elig <- anastomoses_eligibility(tasks, docs_index)
    corpus <- make_corpus("E1", "Avant le geste. Anastomose arterielle termino-laterale. Apres le geste.")
    r <- retrieve(corpus, tasks, elig, ANASTOMOSES_QUERY)
    sid <- r$candidates$snippet_id[1]; snip <- r$candidates$snippet_text[1]
    expect_match(snip, "Anastomose arterielle termino-laterale")
    expect_match(snip, "Avant le geste"); expect_match(snip, "Apres le geste")

    fake <- function(prompt, type, system_prompt) {
        res <- empty_anastomoses_result()
        res$transplantation_type_anastomose_arterielle <-
            list(status = "documented", value = "termino-laterale", evidence_ids = list(sid))
        res
    }
    run <- run_extraction(r$coverage, r$candidates, anastomoses_definition(), fake, "fake")
    art <- run$evidence[run$evidence$field == "transplantation_type_anastomose_arterielle", ]
    expect_equal(art$snippet_id, sid)
    expect_equal(art$snippet_text, snip)
})

test_that("no_candidate tasks skip the model and stay coverage-only", {
    coverage <- tibble::tibble(task_id = "T", coverage_state = "no_candidate")
    called <- 0L
    fake <- function(prompt, type, system_prompt) { called <<- called + 1L; stop("must not call") }
    run <- run_extraction(coverage, tibble::tibble(), anastomoses_definition(), fake, "fake")
    expect_equal(called, 0L)
    expect_equal(nrow(run$values), 0L)
    expect_equal(run$coverage$processing_state, "no_candidate")
})

test_that("each field's evidence contains only that field's cited snippets", {
    docs_index <- tibble::tibble(ELTID = "E1", PATID = "P1", EVTID = "EV1",
                                 RECDATE = as.Date("2025-03-10"), RECTYPE = "CRO")
    tasks <- ana_tasks(); elig <- anastomoses_eligibility(tasks, docs_index)
    corpus <- make_corpus("E1", "Anastomose arterielle termino-laterale. Technique de Gregoir.")
    r <- retrieve(corpus, tasks, elig, ANASTOMOSES_QUERY)
    sids <- r$candidates$snippet_id
    fake <- function(prompt, type, system_prompt) {
        res <- empty_anastomoses_result()
        res$transplantation_type_anastomose_arterielle <-
            list(status = "documented", value = "termino-laterale", evidence_ids = list(sids[1]))
        res$transplantation_type_anastomose_ureterale <-
            list(status = "documented", value = "Gregoir", evidence_ids = list(sids[length(sids)]))
        res
    }
    run <- run_extraction(r$coverage, r$candidates, anastomoses_definition(), fake, "fake")
    art <- run$evidence[run$evidence$field == "transplantation_type_anastomose_arterielle", ]
    ure <- run$evidence[run$evidence$field == "transplantation_type_anastomose_ureterale", ]
    ven <- run$evidence[run$evidence$field == "transplantation_duree_anastomose_veineuse", ]
    expect_setequal(art$snippet_id, sids[1])
    expect_setequal(ure$snippet_id, sids[length(sids)])
    expect_equal(nrow(ven), 0L)
})

test_that("smoking needs evidence for a definitive status but not for indetermine", {
    v1 <- parse_smoking(list(smoking_status = "sevre", evidence_ids = list(), decision_note = "x"), "S001")
    expect_equal(v1$fields$field_validity, "invalid")
    v2 <- parse_smoking(list(smoking_status = "indetermine", evidence_ids = list(), decision_note = "x"), "S001")
    expect_equal(v2$fields$field_validity, "valid")          # abstention may cite nothing
    v3 <- parse_smoking(list(smoking_status = "actif", evidence_ids = list("S001"), decision_note = "x"), "S001")
    expect_equal(v3$fields$field_validity, "valid")
})

test_that("a parse error isolates one task without aborting the batch", {
    boom_def <- new_task_definition(
        name = "boom", system_prompt = "",
        type_builder = function(ids) ellmer::type_object(x = ellmer::type_string()),
        prompt_builder = function(task, cands) task$task_id[[1]],
        parser = function(result, ids) {
            if (isTRUE(result$boom)) stop("kaboom")
            list(fields = tibble::tibble(field = "x", status = "documented",
                 normalized_value = "v", evidence_ids = list(ids[1]),
                 field_validity = "valid", validity_reason = ""), summary = NA_character_)
        })
    coverage <- tibble::tibble(task_id = c("T1", "T2"), coverage_state = "candidate")
    candidates <- tibble::tibble(
        task_id = c("T1", "T2"), snippet_id = c("S001", "S001"),
        hit_ref = "E::1", ELTID = "E", sentence = 1L, hit_text = "t",
        snippet_text = "t", RECDATE = as.Date("2025-01-01"), RECTYPE = "n")
    fake <- function(prompt, type, system_prompt) list(boom = identical(prompt, "T1"))
    run <- run_extraction(coverage, candidates, boom_def, fake, "fake")  # must not throw
    expect_equal(nrow(run$attempts), 2L)
    expect_equal(run$values$task_id, "T2")                  # T1 dropped, T2 survived
    ps <- run$coverage$processing_state[match(c("T1", "T2"), run$coverage$task_id)]
    expect_equal(ps, c("processing_error", "valid"))
})

test_that("acceptance is field-level: a valid field survives an invalid sibling", {
    docs_index <- tibble::tibble(ELTID = "E1", PATID = "P1", EVTID = "EV1",
                                 RECDATE = as.Date("2025-03-10"), RECTYPE = "CRO")
    tasks <- ana_tasks(); elig <- anastomoses_eligibility(tasks, docs_index)
    corpus <- make_corpus("E1", "Anastomose arterielle termino-laterale. Technique de Gregoir.")
    r <- retrieve(corpus, tasks, elig, ANASTOMOSES_QUERY)
    sids <- r$candidates$snippet_id
    fake <- function(prompt, type, system_prompt) {
        res <- empty_anastomoses_result()
        res$transplantation_type_anastomose_arterielle <-           # valid (has evidence)
            list(status = "documented", value = "termino-laterale", evidence_ids = list(sids[1]))
        res$transplantation_type_anastomose_ureterale <-            # invalid (documented, no evidence)
            list(status = "documented", value = "Gregoir", evidence_ids = list())
        res
    }
    run <- run_extraction(r$coverage, r$candidates, anastomoses_definition(), fake, "fake")
    v <- run$values
    art <- v[v$field == "transplantation_type_anastomose_arterielle", ]
    ure <- v[v$field == "transplantation_type_anastomose_ureterale", ]
    expect_equal(art$field_validity, "valid")
    expect_equal(art$accepted_value, "termino-laterale")    # accepted despite sibling invalid
    expect_equal(ure$field_validity, "invalid")
    expect_true(is.na(ure$accepted_value))                  # invalid field not accepted
    expect_equal(unique(v$task_validity), "invalid")        # task flagged because a field is invalid
})

test_that("a cited snippet ID that was never supplied fails the field closed", {
    docs_index <- tibble::tibble(ELTID = "E1", PATID = "P1", EVTID = "EV1",
                                 RECDATE = as.Date("2025-03-10"), RECTYPE = "CRO")
    tasks <- ana_tasks(); elig <- anastomoses_eligibility(tasks, docs_index)
    corpus <- make_corpus("E1", "Anastomose arterielle termino-laterale. Technique de Gregoir.")
    r <- retrieve(corpus, tasks, elig, ANASTOMOSES_QUERY)
    sids <- r$candidates$snippet_id
    fake <- function(prompt, type, system_prompt) {
        res <- empty_anastomoses_result()
        res$transplantation_type_anastomose_arterielle <-
            list(status = "documented", value = "termino-laterale",
                 evidence_ids = list(sids[1], "S999"))   # one real + one fabricated ID
        res
    }
    run <- run_extraction(r$coverage, r$candidates, anastomoses_definition(), fake, "fake")
    v <- run$values[run$values$field == "transplantation_type_anastomose_arterielle", ]
    expect_equal(v$field_validity, "invalid")              # fail closed, not silently dropped
    expect_match(v$validity_reason, "unsupplied")
    ev <- run$evidence[run$evidence$field == "transplantation_type_anastomose_arterielle", ]
    expect_true(sids[1] %in% ev$snippet_id)                # real ID still resolves
    expect_false("S999" %in% ev$snippet_id)                # fabricated ID never materializes
})

test_that("bounded response schemas preserve dynamic evidence enums", {
    smoking <- type_smoking("S001")
    anastomoses <- type_anastomoses(c("S001", "S002"))

    expect_s3_class(smoking, "ellmer::TypeJsonSchema")
    expect_equal(smoking@json$properties$evidence_ids$maxItems,
                 SMOKING_EVIDENCE_MAX_ITEMS)
    expect_equal(unlist(smoking@json$properties$evidence_ids$items$enum), "S001")
    expect_equal(smoking@json$properties$decision_note$maxLength,
                 SMOKING_NOTE_MAX_LEN)

    arterial <- anastomoses@json$properties$transplantation_type_anastomose_arterielle
    expect_s3_class(anastomoses, "ellmer::TypeJsonSchema")
    expect_equal(arterial$properties$evidence_ids$maxItems,
                 ANASTOMOSES_EVIDENCE_MAX_ITEMS)
    expect_equal(unlist(arterial$properties$evidence_ids$items$enum),
                 c("S001", "S002"))
    expect_equal(arterial$properties$value$maxLength, ANASTOMOSES_LABEL_MAX_LEN)
})

test_that("a failed call records partial output and inferred stop reason", {
    coverage <- tibble::tibble(
        task_id = "T1", coverage_state = "candidate",
        anchor_date = as.Date("2025-01-01"))
    candidates <- tibble::tibble(
        task_id = "T1", snippet_id = "S001", hit_ref = "E::1", ELTID = "E",
        sentence = 1L, hit_text = "t", snippet_text = "t",
        RECDATE = as.Date("2025-01-01"), RECTYPE = "n")
    # caller fails the way make_ollama_caller re-raises a truncation
    fake <- function(prompt, type, system_prompt) {
        rlang::abort("parse error: premature EOF", class = "engine_call_error",
                     partial_response = '{ "x":', output_tokens = 1024,
                     inferred_finish_reason = "length")
    }
    run <- run_extraction(coverage, candidates, anastomoses_definition(), fake, "fake")
    a <- run$attempts
    expect_equal(a$attempt_status, "error")
    expect_equal(a$n_tries, 1L)                            # EOF is deterministic, not retried
    expect_equal(a$inferred_finish_reason, "length")
    expect_equal(a$output_tokens, 1024)
    expect_match(a$partial_response, "\\{")                # partial output captured
    expect_equal(run$coverage$processing_state, "model_error")
})

test_that("build_review_view surfaces failed tasks as explicit review rows", {
    values <- tibble::tibble(
        task_id = "T2", field = "x", status = "documented", normalized_value = "v",
        accepted_value = "v", field_validity = "valid", validity_reason = "",
        task_validity = "valid", task_validity_reason = "", task_summary = NA_character_)
    evidence <- tibble::tibble(
        task_id = "T2", field = "x", snippet_id = "S001", hit_ref = "E::1",
        ELTID = "E", snippet_text = "t")
    coverage <- tibble::tibble(task_id = c("T1", "T2"),
                               processing_state = c("model_error", "valid"))
    attempts <- tibble::tibble(task_id = "T1", error = "premature EOF")
    review <- build_review_view(values, evidence, coverage, attempts)
    t1 <- review[review$task_id == "T1", ]
    expect_equal(nrow(t1), 1L)                             # failed task is visible
    expect_equal(t1$status, "model_error")
    expect_equal(t1$validity_reason, "premature EOF")
    expect_true("T2" %in% review$task_id)                  # the valid task is still present
})
