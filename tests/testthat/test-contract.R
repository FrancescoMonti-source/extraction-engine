# Four black-box CONTRACT tests for the synthesis baseline. No provider calls, no
# patient data. They pin the shared observable contract so two implementations
# cannot silently diverge. The model is injected as a fake.

make_corpus <- function(eltids, texts) {
    corpustools::create_tcorpus(
        data.frame(ELTID = eltids, RECTXT = texts, stringsAsFactors = FALSE),
        text_columns = "RECTXT", doc_column = "ELTID",
        split_sentences = TRUE, remember_spaces = FALSE, verbose = FALSE
    )
}

.not_documented <- function() list(status = "not_documented", evidence_ids = list())

empty_anastomoses_result <- function() {
    res <- setNames(
        replicate(length(ANASTOMOSES_FIELDS), .not_documented(), simplify = FALSE),
        names(ANASTOMOSES_FIELDS)
    )
    res[[ANASTOMOSES_SUMMARY]] <- "resume"
    res
}

test_that("retrieval is scoped to the resolved eligibility relation only", {
    docs_index <- tibble::tibble(
        ELTID = c("E1", "E2", "E3"), PATID = c("P1", "P1", "P2"),
        EVTID = c("EV1", "OTHER", "EV1"), RECDATE = as.Date("2025-03-10"),
        RECTYPE = "CRO"
    )
    tasks <- tibble::tibble(task_id = "P1::2025-03-10::EV1", PATID = "P1",
                            EVTID = "EV1", anchor_date = as.Date("2025-03-10"))
    elig <- anastomoses_eligibility(tasks, docs_index)
    # event scope: same PATID AND EVTID -> only E1 (E2 wrong event, E3 wrong patient)
    expect_setequal(elig$ELTID, "E1")

    corpus <- make_corpus(
        c("E1", "E2", "E3"),
        c("Anastomose arterielle termino-laterale sur artere iliaque externe.",
          "Anastomose veineuse documentee ailleurs.",
          "Technique de Gregoir ailleurs.")
    )
    r <- retrieve(corpus, tasks, elig, ANASTOMOSES_QUERY, neighbours = 1L, as_ascii = TRUE)
    expect_true(nrow(r$candidates) >= 1L)
    expect_true(all(r$candidates$ELTID == "E1"))           # never leaks other docs
    expect_equal(r$coverage$n_eligible_documents, 1L)
})

test_that("a snippet ID maps to the exact model-visible snippet it was given", {
    docs_index <- tibble::tibble(ELTID = "E1", PATID = "P1", EVTID = "EV1",
                                 RECDATE = as.Date("2025-03-10"), RECTYPE = "CRO")
    tasks <- tibble::tibble(task_id = "P1::2025-03-10::EV1", PATID = "P1",
                            EVTID = "EV1", anchor_date = as.Date("2025-03-10"))
    elig <- anastomoses_eligibility(tasks, docs_index)
    corpus <- make_corpus("E1", "Avant le geste. Anastomose arterielle termino-laterale. Apres le geste.")
    r <- retrieve(corpus, tasks, elig, ANASTOMOSES_QUERY, neighbours = 1L, as_ascii = TRUE)

    cand <- r$candidates
    sid  <- cand$snippet_id[1]
    snip <- cand$snippet_text[1]
    expect_match(snip, "[Aa]nastomose arterielle termino-laterale", fixed = FALSE)
    expect_match(snip, "Avant le geste"); expect_match(snip, "Apres le geste")

    fake <- function(prompt, type) {
        res <- empty_anastomoses_result()
        res$transplantation_type_anastomose_arterielle <-
            list(status = "documented", value = "termino-laterale", evidence_ids = list(sid))
        res
    }
    run <- run_extraction(r$coverage, cand, fake, "fake",
                          type_anastomoses, prompt_anastomoses, parse_anastomoses)
    art <- run$evidence[run$evidence$field == "transplantation_type_anastomose_arterielle", ]
    expect_equal(art$snippet_id, sid)
    expect_equal(art$snippet_text, snip)   # the cited ID resolves to the EXACT snippet shown
})

test_that("no_candidate tasks skip the model and stay coverage-only", {
    coverage <- tibble::tibble(
        task_id = "T", coverage_state = "no_candidate",
        n_eligible_documents = 1L, n_searchable_documents = 0L, n_candidates = 0L
    )
    called <- 0L
    fake <- function(prompt, type) { called <<- called + 1L; stop("must not be called") }
    run <- run_extraction(coverage, tibble::tibble(), fake, "fake",
                          type_anastomoses, prompt_anastomoses, parse_anastomoses)
    expect_equal(called, 0L)
    expect_equal(nrow(run$values), 0L)
    expect_equal(run$coverage$processing_state, "no_candidate")
})

test_that("each field's evidence contains only that field's cited snippets", {
    docs_index <- tibble::tibble(ELTID = "E1", PATID = "P1", EVTID = "EV1",
                                 RECDATE = as.Date("2025-03-10"), RECTYPE = "CRO")
    tasks <- tibble::tibble(task_id = "P1::2025-03-10::EV1", PATID = "P1",
                            EVTID = "EV1", anchor_date = as.Date("2025-03-10"))
    elig <- anastomoses_eligibility(tasks, docs_index)
    corpus <- make_corpus("E1", "Anastomose arterielle termino-laterale. Technique de Gregoir.")
    r <- retrieve(corpus, tasks, elig, ANASTOMOSES_QUERY, neighbours = 1L, as_ascii = TRUE)
    sids <- r$candidates$snippet_id

    fake <- function(prompt, type) {
        res <- empty_anastomoses_result()
        res$transplantation_type_anastomose_arterielle <-
            list(status = "documented", value = "termino-laterale", evidence_ids = list(sids[1]))
        res$transplantation_type_anastomose_ureterale <-
            list(status = "documented", value = "Gregoir", evidence_ids = list(sids[length(sids)]))
        res
    }
    run <- run_extraction(r$coverage, r$candidates, fake, "fake",
                          type_anastomoses, prompt_anastomoses, parse_anastomoses)
    art <- run$evidence[run$evidence$field == "transplantation_type_anastomose_arterielle", ]
    ure <- run$evidence[run$evidence$field == "transplantation_type_anastomose_ureterale", ]
    ven <- run$evidence[run$evidence$field == "transplantation_duree_anastomose_veineuse", ]
    expect_setequal(art$snippet_id, sids[1])
    expect_setequal(ure$snippet_id, sids[length(sids)])
    expect_equal(nrow(ven), 0L)                # not_documented field carries no evidence
})
