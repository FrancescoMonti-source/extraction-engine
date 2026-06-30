# Real retrieval/eligibility wiring (tightly scoped to ONE subject-scoped text
# variable: smoking_status_periop). Proves run_variable() is a real entry point
# into retrieval: raw synthetic documents (corpus + docs_index) -> eligibility
# windowing -> retrieve() -> extraction -> final categorical values, with no
# manually supplied coverage/candidates.

rw_make_corpus <- function(eltids, texts) {
    corpustools::create_tcorpus(
        data.frame(ELTID = eltids, RECTXT = texts, stringsAsFactors = FALSE),
        text_columns = "RECTXT", doc_column = "ELTID",
        split_sentences = TRUE, remember_spaces = FALSE, verbose = FALSE)
}

rw_tasks <- tibble::tibble(
    task_id = c("P1::s", "P2::s", "P3::s"),
    PATID = c("P1", "P2", "P3"),
    anchor_date = as.Date("2025-03-10"))

# E1 (P1): in window + smoking term. E2 (P2): in window, no smoking term.
# E3 (P3): smoking term but OUT of the [anchor-365, anchor+7] window.
rw_docs_index <- tibble::tibble(
    ELTID = c("E1", "E2", "E3"),
    PATID = c("P1", "P2", "P3"),
    EVTID = c("V1", "V2", "V3"),
    RECDATE = as.Date(c("2025-03-01", "2025-03-01", "2020-01-01")),
    RECTYPE = "note")
rw_corpus <- rw_make_corpus(
    c("E1", "E2", "E3"),
    c("Patient tabagique actif, environ 10 cigarettes par jour.",
      "Examen clinique sans particularite ce jour.",
      "Tabac sevre depuis 2010."))

rw_sources <- list(documents = list(corpus = rw_corpus, docs_index = rw_docs_index))

rw_fake <- function(prompt, type, system_prompt) {
    if (grepl("tabagique", prompt, fixed = TRUE)) {
        return(list(smoking_status = "actif", evidence_ids = list("S001"),
                    decision_note = "tabagisme actif documente"))
    }
    list(smoking_status = "indetermine", evidence_ids = list(), decision_note = "")
}

rw_variable <- function() {
    variable_spec(
        template = documented_smoking_status_periop_template(),
        name = "tabac_statut_periop", unit = "transplant", anchor = "anchor_date")
}

# Why: the spec layer must be a real entry point into retrieval. run_variable()
# executes from raw documents through Lucene retrieval + eligibility windowing to
# final categorical values -- no pre-built coverage/candidates.
test_that("run_variable executes a text variable from raw documents via retrieval", {
    run <- run_variable(rw_variable(), rw_tasks, rw_sources,
                        caller = rw_fake, model_name = "fake")

    value <- setNames(run$values$value, run$values$task_id)

    expect_equal(value[["P1::s"]], "actif")   # retrieved smoking sentence -> extracted
    expect_true(is.na(value[["P2::s"]]))       # in-window doc, no smoking term -> no_candidate
    expect_true(is.na(value[["P3::s"]]))       # smoking doc OUT of window -> not eligible

    # P1's value is grounded by a real retrieved sentence reference into the corpus.
    ev1 <- run$evidence[run$evidence$task_id == "P1::s", ]
    expect_equal(nrow(ev1), 1L)
    expect_match(ev1$evidence_ref, "^E1::")
})

# Why: an unrecognized documents source shape must fail loudly, not silently
# produce empty results.
test_that("a malformed documents source is rejected", {
    expect_error(
        run_variable(rw_variable(), rw_tasks[1, ],
                     list(documents = list(foo = 1)),
                     caller = rw_fake, model_name = "fake"),
        "pre-retrieved|raw")
})
