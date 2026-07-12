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
    grain_id = c("P1::s", "P2::s", "P3::s"),
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
    documented_smoking_status_periop(
        name = "tabac_statut_periop", anchor = "anchor_date")
}

rw_event_concept <- function() {
    definition <- binary_presence_text_definition(
        name = "event mention", status_key = "mention_status",
        field = "event_mention", system_prompt = "Extract documented presence.")
    concept_spec("event text", list(
        event_text = text_channel(
            source = "documents", selector = lucene_query("anastomose"),
            required_roles = c("subject_id", "event_id", "point_date", "text",
                               "source_item_id"),
            linkage = c("subject", "event"), extractor = definition,
            default_method = llm_after_lucene())))
}

rw_event_variable <- function(anchor = NULL, window = NULL) {
    variable_spec(
        "event mention", rw_event_concept(), output_one_row_per = "PATID",
        anchor = anchor, window = window,
        channels = list(event_text = use_channel()), output = bin_output())
}

rw_event_fake <- function(...) {
    list(mention_status = "documented", evidence_ids = list("S001"))
}

# Why: the spec layer must be a real entry point into retrieval. run_variable()
# executes from raw documents through Lucene retrieval + eligibility windowing to
# final categorical values -- no pre-built coverage/candidates.
test_that("run_variable executes a text variable from raw documents via retrieval", {
    run <- run_variable(rw_variable(), rw_tasks, rw_sources,
                        chat = fake_chat(rw_fake))

    value <- setNames(run$values$value, run$values$grain_id)

    expect_equal(value[["P1::s"]], "actif")   # retrieved smoking sentence -> extracted
    expect_true(is.na(value[["P2::s"]]))       # in-window doc, no smoking term -> no_candidate
    expect_true(is.na(value[["P3::s"]]))       # smoking doc OUT of window -> not eligible

    # P1's value is grounded by a real retrieved sentence reference into the corpus.
    ev1 <- run$evidence[run$evidence$grain_id == "P1::s", ]
    expect_equal(nrow(ev1), 1L)
    expect_match(ev1$evidence_ref, "^E1::")
})

test_that("raw event-linked text retrieval does not require an anchor", {
    # Relational-scope contract: same-event attachment is sufficient; an
    # unrelated temporal anchor must not be invented as an input requirement.
    variable <- rw_event_variable()
    tasks <- tibble::tibble(
        grain_id = "event-task", PATID = "subject", EVTID = "event")
    index <- tibble::tibble(
        ELTID = "event-doc", PATID = "subject", EVTID = "event",
        RECDATE = as.POSIXct("2025-01-01", tz = "Europe/Paris"),
        RECTYPE = "note")
    source <- list(
        documents = list(
            corpus = rw_make_corpus("event-doc", "Anastomose documentee."),
            docs_index = index))
    n_calls <- 0L
    responder <- function(...) {
        n_calls <<- n_calls + 1L
        rw_event_fake(...)
    }

    run <- run_variable(variable, tasks, source, chat = fake_chat(responder))

    expect_equal(run$values$value, 1L)
    expect_equal(n_calls, 1L)

    windowed <- rw_event_variable(anchor = "index_date", window = c(-1, 1))
    distant_tasks <- dplyr::mutate(tasks, index_date = as.Date("2026-01-01"))
    distant <- run_variable(
        windowed, distant_tasks, source, chat = fake_chat(responder))

    expect_equal(distant$values$value, 0L)
    expect_equal(n_calls, 1L)
})

test_that("an undeclared anchor column cannot change event-text evidence", {
    # Executable-definition contract: an incidental task column must not enter
    # ranking or deduplication when anchor = NULL.
    variable <- rw_event_variable()
    index <- tibble::tibble(
        ELTID = c("event-old", "event-new"), PATID = "subject", EVTID = "event",
        RECDATE = as.POSIXct(c("2024-01-01", "2025-01-01"),
                            tz = "Europe/Paris"),
        RECTYPE = "note")
    source <- list(documents = list(
        corpus = rw_make_corpus(
            c("event-old", "event-new"),
            rep("Anastomose documentee.", 2)),
        docs_index = index))
    tasks <- tibble::tibble(
        grain_id = "event-task", PATID = "subject", EVTID = "event")

    plain <- run_variable(variable, tasks, source, chat = fake_chat(rw_event_fake))
    decoy <- run_variable(
        variable, dplyr::mutate(tasks, anchor_date = as.Date("2025-01-01")),
        source, chat = fake_chat(rw_event_fake))

    expect_equal(decoy$evidence$evidence_ref, plain$evidence$evidence_ref)
    expect_match(plain$evidence$evidence_ref, "^event-old::")
})
