# Contract tests for low-level text execution invariants. No provider calls, no
# patient data; the model is an injected fake.

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

# Why: document timestamps arrive from EDSAN as Europe/Paris POSIXct values.
# A default UTC conversion changes the clinical date near local midnight, which can
# wrongly include or exclude a document from a variable-level date window.
test_that("document loading preserves the Europe/Paris clinical date", {
    docs_path <- tempfile(fileext = ".rds")
    on.exit(unlink(docs_path), add = TRUE)
    saveRDS(tibble::tibble(
        ELTID = "E1", PATID = "P1", EVTID = "EV1",
        RECDATE = as.POSIXct("2025-06-22 00:30:00", tz = "Europe/Paris"),
        RECTYPE = "note"), docs_path)

    docs <- load_docs_index(docs_path)

    expect_equal(docs$RECDATE, as.Date("2025-06-22"))
})

# Why: anastomosis evidence is defined by the exact transplant event, not merely
# by patient identity. This catches joins that leak documents from another stay or
# another patient into the model-visible candidate set.
test_that("retrieval is scoped to the resolved eligibility relation (event scope)", {
    docs_index <- tibble::tibble(
        ELTID = c("E1", "E2", "E3"), PATID = c("P1", "P1", "P2"),
        EVTID = c("EV1", "OTHER", "EV1"), RECDATE = as.Date("2025-03-10"), RECTYPE = "CRO")
    tasks <- ana_tasks()
    elig <- anastomoses_eligibility(tasks, docs_index)
    corpus <- make_corpus(c("E1", "E2", "E3"),
        c("Anastomose arterielle termino-laterale sur artere iliaque externe.",
          "Anastomose veineuse ailleurs.", "Technique de Gregoir ailleurs."))
    r <- retrieve(corpus, tasks, elig, ANASTOMOSES_QUERY)
    expect_true(all(r$candidates$ELTID == "E1"))
})

# Why: smoking uses an inner, variable-specific date window within the already
# prepared study data. It intentionally crosses EVTID boundaries for the same patient
# and must still exclude records outside that window.
test_that("smoking scope is the date window (patient-based), not the event", {
    docs_index <- tibble::tibble(
        ELTID = c("E1", "E2", "E3"), PATID = "P1", EVTID = c("EV1", "EV1", "EVother"),
        RECDATE = as.Date(c("2025-03-09", "2020-01-01", "2025-03-08")), RECTYPE = "note")
    tasks <- tibble::tibble(task_id = "P1::2025-03-10::EV1", PATID = "P1",
                            EVTID = "EV1", anchor_date = as.Date("2025-03-10"))
    elig <- smoking_eligibility(tasks, docs_index)
    expect_setequal(elig$ELTID, c("E1", "E3"))
})

# Why: model citations are task-local aliases, while review requires the exact
# snippet shown to the model. This prevents provenance joins from resolving an alias
# to only the hit sentence, a different snippet, or reconstructed text.
test_that("a snippet ID maps to the exact model-visible snippet it was given", {
    docs_index <- tibble::tibble(ELTID = "E1", PATID = "P1", EVTID = "EV1",
                                 RECDATE = as.Date("2025-03-10"), RECTYPE = "CRO")
    tasks <- ana_tasks(); elig <- anastomoses_eligibility(tasks, docs_index)
    corpus <- make_corpus("E1", "Avant le geste. Anastomose arterielle termino-laterale. Apres le geste.")
    r <- retrieve(corpus, tasks, elig, ANASTOMOSES_QUERY)
    sid <- r$candidates$snippet_id[1]; snip <- r$candidates$snippet_text[1]

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

# Why: no candidate means there is no evidence to measure, so calling a model would
# waste computation and could manufacture a value from an empty context. The task
# must remain represented in coverage without producing values.
test_that("no_candidate tasks skip the model and stay coverage-only", {
    coverage <- tibble::tibble(task_id = "T", coverage_state = "no_candidate")
    called <- 0L
    fake <- function(prompt, type, system_prompt) { called <<- called + 1L; stop("must not call") }
    run <- run_extraction(coverage, tibble::tibble(), anastomoses_definition(), fake, "fake")
    expect_equal(called, 0L)
    expect_equal(nrow(run$values), 0L)
    expect_equal(run$coverage$processing_state, "no_candidate")
})

# Why: a bundled response contains several independently judged fields. Evidence
# cited for one field must never appear under a sibling field during materialisation
# or physician review.
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

# Why: one malformed model result must not abort a cohort run or erase later tasks.
# This protects the per-task failure-isolation contract and the resulting complete
# processing census.
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
    expect_equal(run$values$task_id, "T2")                  # T1 dropped, T2 survived
    ps <- run$coverage$processing_state[match(c("T1", "T2"), run$coverage$task_id)]
    expect_equal(ps, c("processing_error", "valid"))
})
