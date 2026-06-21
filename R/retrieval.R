# =============================================================================
# retrieval.R — reusable, variable-agnostic retrieval (synthesis baseline)
# -----------------------------------------------------------------------------
# Knows NOTHING clinical. It consumes:
#   - tasks:        tibble(task_id, ...)  the complete task set (for coverage)
#   - eligibility:  tibble(task_id, ELTID, RECDATE, RECTYPE, anchor_date)
#                   the already-resolved task<->document relation (built by a
#                   project adapter; the engine never computes scope itself)
#   - corpus:       the persisted canonical tCorpus (reused across variables)
#   - query:        one variable-specific Lucene query
#
# It runs ONE search on a temporary subset_meta(copy=TRUE) of the union of
# eligible documents, assembles the exact model-visible snippet per hit with
# stable provenance, assigns task-local snippet IDs, and returns candidates +
# coverage. It must not know what a transplant, donor, recipient, or anchor is.
# =============================================================================

suppressWarnings(suppressMessages({
    library(dplyr)
    library(stringr)
    library(corpustools)
}))

# Deterministic normalized untokenizer (single tested punctuation policy).
# Readable, NOT a claim of exact source whitespace.
untokenize <- function(tokens) {
    s <- paste(tokens, collapse = " ")
    s <- gsub(" ([,.;:!?%)\\]}])", "\\1", s, perl = TRUE)  # no space before close punct
    s <- gsub("([(\\[{]) ", "\\1", s, perl = TRUE)          # no space after open punct
    s <- gsub(" ?- ?", "-", s)                               # tighten hyphens
    s <- gsub(" ?' ?", "'", s)                               # tighten apostrophes
    trimws(gsub("\\s+", " ", s))
}

# Reconstruct normalized text for every sentence within +/-neighbours of a hit,
# from the scoped corpus tokens only (no second corpus, no global sentence table).
.reconstruct_sentences <- function(scoped_tc, hit_locations, neighbours) {
    offsets <- seq.int(-neighbours, neighbours)
    targets <- hit_locations %>%
        tidyr::crossing(offset = offsets) %>%
        transmute(ELTID, sentence = sentence + offset) %>%
        filter(sentence >= 1L) %>%
        distinct()

    tok <- scoped_tc$tokens %>% as.data.frame()
    tibble::tibble(
        ELTID    = as.character(tok$doc_id),
        sentence = as.integer(tok$sentence),
        token_id = as.integer(tok$token_id),
        token    = as.character(tok$token)
    ) %>%
        semi_join(targets, by = c("ELTID", "sentence")) %>%
        arrange(ELTID, sentence, token_id) %>%
        group_by(ELTID, sentence) %>%
        summarise(text = untokenize(token), .groups = "drop")
}

# Concatenate the neighbour sentences in a relative offset band [lo, hi] around
# each hit sentence, in reading order.
.band_text <- function(hit_locations, sentence_text, lo, hi) {
    hit_locations %>%
        rename(hit_sentence = sentence) %>%
        inner_join(sentence_text, by = "ELTID", relationship = "many-to-many") %>%
        filter(sentence >= hit_sentence + lo, sentence <= hit_sentence + hi) %>%
        arrange(ELTID, hit_sentence, sentence) %>%
        group_by(ELTID, sentence = hit_sentence) %>%
        summarise(text = paste(text, collapse = " "), .groups = "drop")
}

# Per Lucene hit: hit_ref + hit_text + context_before/after + the exact
# model-visible snippet_text ("before [hit] after"; missing neighbours omitted).
.assemble_snippets <- function(scoped_tc, hits, neighbours) {
    empty <- tibble::tibble(
        ELTID = character(), sentence = integer(), hit_ref = character(),
        hit_text = character(), context_before = character(),
        context_after = character(), snippet_text = character()
    )
    if (!nrow(hits)) return(empty)

    hit_loc <- hits %>%
        transmute(ELTID = as.character(doc_id), sentence = as.integer(sentence)) %>%
        distinct()

    sent <- .reconstruct_sentences(scoped_tc, hit_loc, neighbours)
    before <- .band_text(hit_loc, sent, -neighbours, -1L) %>% rename(context_before = text)
    after  <- .band_text(hit_loc, sent,  1L, neighbours) %>% rename(context_after = text)

    hit_loc %>%
        left_join(rename(sent, hit_text = text), by = c("ELTID", "sentence")) %>%
        left_join(before, by = c("ELTID", "sentence")) %>%
        left_join(after,  by = c("ELTID", "sentence")) %>%
        filter(!is.na(hit_text), nzchar(hit_text)) %>%
        mutate(
            hit_ref = sprintf("%s::%d", ELTID, sentence),
            snippet_text = trimws(paste(
                ifelse(is.na(context_before), "", context_before),
                sprintf("[%s]", hit_text),
                ifelse(is.na(context_after), "", context_after)
            )) %>% str_squish()
        )
}

# Main reusable entry point.
retrieve <- function(corpus, tasks, eligibility, query,
                     neighbours = 1L, as_ascii = TRUE) {
    stopifnot(all(c("task_id", "ELTID") %in% names(eligibility)))

    corpus_ids <- as.character(corpus$get_meta("doc_id"))
    elig <- eligibility %>% mutate(in_corpus = ELTID %in% corpus_ids)
    eligible_ids <- unique(elig$ELTID[elig$in_corpus])

    if (length(eligible_ids)) {
        sub <- corpus$subset(subset_meta = doc_id %in% eligible_ids, copy = TRUE)
        hits <- as.data.frame(search_contexts(
            sub, query, context_level = "sentence", as_ascii = as_ascii
        )$hits)
        snippets <- .assemble_snippets(sub, hits, neighbours)
        rm(sub)
    } else {
        snippets <- .assemble_snippets(NULL, data.frame(), neighbours)
    }

    # Attach snippets to every task whose eligible document they belong to, then
    # assign deterministic task-local snippet IDs (S01, S02, ...).
    candidates <- elig %>%
        filter(in_corpus) %>%
        inner_join(snippets, by = "ELTID", relationship = "many-to-many") %>%
        mutate(days_from_anchor = as.numeric(RECDATE - anchor_date)) %>%
        arrange(task_id, RECDATE, ELTID, sentence) %>%
        group_by(task_id) %>%
        mutate(snippet_id = sprintf("S%02d", row_number())) %>%
        ungroup() %>%
        select(task_id, snippet_id, hit_ref, hit_text, context_before,
               context_after, snippet_text, ELTID, sentence, RECDATE, RECTYPE,
               anchor_date, days_from_anchor)

    # Coverage over ALL tasks. no_candidate is a coverage state, not a value.
    n_eligible <- elig %>% group_by(task_id) %>%
        summarise(n_eligible_documents = n_distinct(ELTID),
                  n_searchable_documents = n_distinct(ELTID[in_corpus]),
                  .groups = "drop")
    n_cand <- candidates %>% group_by(task_id) %>%
        summarise(n_candidates = n(), .groups = "drop")

    coverage <- tasks %>%
        left_join(n_eligible, by = "task_id") %>%
        left_join(n_cand, by = "task_id") %>%
        mutate(across(c(n_eligible_documents, n_searchable_documents, n_candidates),
                      ~ coalesce(as.integer(.x), 0L)),
               coverage_state = if_else(n_candidates > 0L, "candidate", "no_candidate"))

    list(candidates = candidates, coverage = coverage)
}
