# =============================================================================
# retrieval.R — reusable, variable-agnostic retrieval (integrated baseline)
# -----------------------------------------------------------------------------
# Synthesis of the two independent builds. Consumes the complete task set + a
# resolved (task_id, ELTID) eligibility relation; runs ONE Lucene query on a
# temporary subset_meta(copy=TRUE) of the persisted canonical corpus; assembles
# model-visible snippets (snippet_id + bracketed snippet_text) with separate
# ELTID::sentence provenance; deduplicates by normalized HIT SENTENCE while
# retaining removed refs/dates as audit; reports three coverage states. Knows
# nothing clinical.
# =============================================================================

# Deterministic normalized untokenizer (single tested punctuation policy).
untokenize <- function(tokens) {
    s <- paste(tokens, collapse = " ")
    s <- gsub(" ([,.;:!?%)\\]}])", "\\1", s, perl = TRUE)
    s <- gsub("([(\\[{]) ", "\\1", s, perl = TRUE)
    s <- gsub(" ?- ?", "-", s)
    s <- gsub(" ?' ?", "'", s)
    trimws(gsub("\\s+", " ", s))
}

.reconstruct_sentences <- function(scoped_tc, hit_locations, neighbours) {
    targets <- hit_locations %>%
        tidyr::crossing(offset = seq.int(-neighbours, neighbours)) %>%
        transmute(ELTID, sentence = sentence + offset) %>%
        filter(sentence >= 1L) %>% distinct()
    tok <- scoped_tc$tokens %>% as.data.frame()
    tibble::tibble(
        ELTID = as.character(tok$doc_id), sentence = as.integer(tok$sentence),
        token_id = as.integer(tok$token_id), token = as.character(tok$token)
    ) %>%
        semi_join(targets, by = c("ELTID", "sentence")) %>%
        arrange(ELTID, sentence, token_id) %>%
        group_by(ELTID, sentence) %>%
        summarise(text = untokenize(token), .groups = "drop")
}

.band_text <- function(hit_locations, sentence_text, lo, hi) {
    hit_locations %>%
        rename(hit_sentence = sentence) %>%
        inner_join(sentence_text, by = "ELTID", relationship = "many-to-many") %>%
        filter(sentence >= hit_sentence + lo, sentence <= hit_sentence + hi) %>%
        arrange(ELTID, hit_sentence, sentence) %>%
        group_by(ELTID, sentence = hit_sentence) %>%
        summarise(text = paste(text, collapse = " "), .groups = "drop")
}

.assemble_snippets <- function(scoped_tc, hits, neighbours) {
    empty <- tibble::tibble(ELTID = character(), sentence = integer(),
        hit_ref = character(), hit_text = character(),
        context_before = character(), context_after = character(),
        snippet_text = character())
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
            snippet_text = str_squish(trimws(paste(
                ifelse(is.na(context_before), "", context_before),
                sprintf("[%s]", hit_text),
                ifelse(is.na(context_after), "", context_after))))
        )
}

# Deduplicate by NORMALIZED HIT SENTENCE within a task (not the full snippet),
# keeping the canonical occurrence (min |days_from_anchor| -> earliest RECDATE ->
# smallest ELTID -> smallest sentence) and retaining removed refs/dates as audit.
.deduplicate <- function(candidates) {
    if (!nrow(candidates)) return(candidates)
    candidates %>%
        mutate(.norm_hit = tolower(str_squish(hit_text)),
               .abs_days = abs(days_from_anchor)) %>%
        arrange(task_id, .norm_hit, .abs_days, RECDATE, ELTID, sentence) %>%
        group_by(task_id, .norm_hit) %>%
        group_modify(function(.x, .y) {
            keep <- .x[1L, , drop = FALSE]
            dup  <- if (nrow(.x) > 1L) .x[-1L, , drop = FALSE] else .x[0, ]
            keep$n_duplicate_occurrences <- nrow(dup)
            keep$duplicate_hit_refs <- paste(dup$hit_ref, collapse = ";")
            keep$duplicate_recdates <- paste(format(dup$RECDATE, "%Y-%m-%d"), collapse = ";")
            keep
        }) %>%
        ungroup() %>%
        select(-.norm_hit, -.abs_days) %>%
        arrange(task_id, abs(days_from_anchor), RECDATE, ELTID, sentence)
}

retrieve <- function(corpus, tasks, eligibility, query,
                     neighbours = 1L, as_ascii = TRUE) {
    stopifnot(all(c("task_id", "ELTID") %in% names(eligibility)))
    if (anyDuplicated(tasks$task_id)) stop("tasks$task_id must be unique.", call. = FALSE)
    unknown <- setdiff(unique(eligibility$task_id), tasks$task_id)
    if (length(unknown)) stop("eligibility references unknown task IDs.", call. = FALSE)

    corpus_ids <- as.character(corpus$get_meta("doc_id"))
    elig <- eligibility %>% mutate(in_corpus = ELTID %in% corpus_ids)
    eligible_ids <- unique(elig$ELTID[elig$in_corpus])

    if (length(eligible_ids)) {
        sub <- corpus$subset(subset_meta = doc_id %in% eligible_ids, copy = TRUE)
        hits <- as.data.frame(search_contexts(
            sub, query, context_level = "sentence", as_ascii = as_ascii)$hits)
        snippets <- .assemble_snippets(sub, hits, neighbours)
        rm(sub)
    } else {
        snippets <- .assemble_snippets(NULL, data.frame(), neighbours)
    }

    candidates <- elig %>%
        filter(in_corpus) %>%
        inner_join(snippets, by = "ELTID", relationship = "many-to-many")
    if ("anchor_date" %in% names(candidates)) {
        recdate <- if (inherits(candidates$RECDATE, "POSIXt")) {
            as.Date(candidates$RECDATE, tz = "Europe/Paris")
        } else {
            as.Date(candidates$RECDATE)
        }
        anchor <- if (inherits(candidates$anchor_date, "POSIXt")) {
            as.Date(candidates$anchor_date, tz = "Europe/Paris")
        } else {
            as.Date(candidates$anchor_date)
        }
        candidates$days_from_anchor <- as.numeric(recdate - anchor)
    } else {
        candidates$days_from_anchor <- NA_real_
    }
    candidates <- candidates %>%
        .deduplicate() %>%
        group_by(task_id) %>%
        mutate(snippet_id = sprintf("S%03d", row_number())) %>%
        ungroup() %>%
        select(any_of(c("task_id", "snippet_id", "hit_ref", "hit_text",
                        "context_before", "context_after", "snippet_text",
                        "ELTID", "EVTID", "sentence", "RECDATE", "RECTYPE",
                        "anchor_date", "days_from_anchor",
                        "n_duplicate_occurrences", "duplicate_hit_refs",
                        "duplicate_recdates")))

    if (nrow(candidates) && anyDuplicated(candidates[c("task_id", "snippet_id")])) {
        stop("Task-local snippet IDs must be unique.", call. = FALSE)
    }

    n_elig <- elig %>% group_by(task_id) %>%
        summarise(n_eligible_documents = n_distinct(ELTID),
                  n_searchable_documents = n_distinct(ELTID[in_corpus]), .groups = "drop")
    n_cand <- candidates %>% group_by(task_id) %>%
        summarise(n_snippets = n(), .groups = "drop")

    coverage <- tasks %>%
        left_join(n_elig, by = "task_id") %>%
        left_join(n_cand, by = "task_id") %>%
        mutate(across(c(n_eligible_documents, n_searchable_documents, n_snippets),
                      ~ coalesce(as.integer(.x), 0L)),
               coverage_state = case_when(
                   n_eligible_documents == 0L ~ "no_eligible_document",
                   n_snippets == 0L           ~ "no_candidate",
                   TRUE                        ~ "candidate"))

    list(coverage = coverage, candidates = candidates)
}
