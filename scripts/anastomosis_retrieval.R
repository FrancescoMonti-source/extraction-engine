#!/usr/bin/env Rscript
# =============================================================================
# Anastomosis (recipient transplant event) — Claude independent build
# RETRIEVAL + candidate assembly (the structured ellmer extraction is a separate
# file: scripts/anastomosis_extract.R). Implements the ratified observable
# contract (HANDOFF, commit 651e5d7).
#
# Key departure from smoking: scope is EVENT MEMBERSHIP, not a date window.
#   eligible docs = docs where PATID == task.PATID AND EVTID == task.EVTID
#
# Uses the validated canonical-corpus path:
#   load persisted canonical corpus -> event-eligible doc union ->
#   subset_meta(copy=TRUE) -> one Lucene search -> join hits to event tasks ->
#   reconstruct only hit sentences +/-1.
#
# PRIVACY: reads ONLY DATEACTE / PATID_receveur / EVTID_receveur from
# chirurgie.xlsx (never names / NIP). Console prints AGGREGATES ONLY; all
# candidates / snippets / refs (PHI) -> gitignored outputs/.
# =============================================================================

suppressWarnings(suppressMessages({
    library(dplyr)
    library(stringr)
    library(corpustools)
    stopifnot(requireNamespace("openxlsx", quietly = TRUE))
    stopifnot(packageVersion("corpustools") == "0.5.2")
}))
source("config/paths.R")  # single source of truth for path_data()

OUT_DIR    <- file.path("outputs", "anastomosis")
dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)
# Prefer the shared dataset-dir canonical corpus (study-agnostic cached artifact);
# fall back to the round-3 build output. Either reload works: this task resolves
# event scope from the external docs index, not from corpus metadata.
CORPUS_RDS <- local({
    shared <- path_data("D0840", "canonical_tcorpus.rds")
    localc <- file.path("outputs", "round3-experiments", "canonical_tcorpus.rds")
    if (file.exists(shared)) shared else localc
})

# Anastomosis Lucene query (FREE design; mirrors D0840 §4.7 regex intent).
# as_ascii=TRUE folds accents on both sides, so ascii stems match the accented
# operative text (artère, urétéro, réimplantation) without variant spam.
ANASTOMOSIS_QUERY <- paste(
    "anastom*",                      # anastomose(s), anastomotique, temps d'anastomose
    "gregoir*",                      # Gregoir(e)
    "ureter*",                       # uretere, ureterale, ureterwhen-uretero
    "reimplant*",                    # reimplantation ureterale
    "<veine iliaque>", "<artere iliaque>",  # adjacent-sequence sites
    sep = " OR "
)
SEARCH_ASCII <- TRUE

# ---- helpers ----------------------------------------------------------------
clean_mixed_date <- function(x) {
    if (inherits(x, "Date")) return(x)
    x <- trimws(as.character(x))
    out <- rep(as.Date(NA), length(x))
    is_num <- grepl("^\\d+(\\.\\d+)?$", x)
    out[is_num] <- as.Date(as.numeric(x[is_num]), origin = "1899-12-30")
    is_txt <- !is_num & nzchar(x)
    out[is_txt] <- as.Date(substr(x[is_txt], 1, 10))
    out
}

# Deterministic normalized untokenizer (single tested punctuation policy).
untokenize <- function(toks) {
    s <- paste(toks, collapse = " ")
    s <- gsub(" ([,.;:!?%)\\]}])", "\\1", s, perl = TRUE)
    s <- gsub("([(\\[{]) ", "\\1", s, perl = TRUE)
    s <- gsub(" ?- ?", "-", s)
    s <- gsub(" ?' ?", "'", s)
    trimws(gsub("\\s+", " ", s))
}
stopifnot(identical(untokenize(c("temps", "d", "'", "anastomose", ":", "16", "min", ".")),
                    "temps d'anastomose: 16 min."))

cat("=============== ANASTOMOSIS RETRIEVAL (aggregates only) ==============\n")

# ---- 1. project adapter: recipient transplant-event tasks -------------------
# Read ONLY the three non-identifier columns this task needs.
ch <- openxlsx::read.xlsx(path_data("D0840", "chirurgie.xlsx"))
ch <- ch[, c("DATEACTE", "PATID_receveur", "EVTID_receveur")]

tasks <- ch %>%
    transmute(
        PATID    = as.character(PATID_receveur),
        EVTID    = as.character(EVTID_receveur),
        DATEACTE = clean_mixed_date(DATEACTE)
    ) %>%
    filter(!is.na(PATID), PATID != "", !is.na(EVTID), EVTID != "", !is.na(DATEACTE)) %>%
    distinct() %>%
    mutate(task_id = sprintf("%s::%s::%s", PATID, format(DATEACTE, "%Y-%m-%d"), EVTID))

# ---- 2. documents + EVENT scope (no date window) ----------------------------
docs <- readRDS(path_data("D0840", "docs")) %>%
    transmute(
        ELTID   = as.character(ELTID),
        PATID   = as.character(PATID),
        EVTID   = as.character(EVTID),
        RECDATE = as.Date(RECDATE),
        RECTYPE = as.character(RECTYPE),
        RECTXT  = as.character(RECTXT)
    ) %>%
    filter(nzchar(trimws(RECTXT)))

event_keys <- tasks %>% distinct(PATID, EVTID)
event_docs <- docs %>% inner_join(event_keys, by = c("PATID", "EVTID"))
doc_meta   <- event_docs %>% distinct(ELTID, PATID, EVTID, RECDATE, RECTYPE)
eligible_ids <- unique(event_docs$ELTID)
tasks_with_event_docs <- event_docs %>% distinct(PATID, EVTID) %>% nrow()

cat(sprintf("recipient tasks ............... %d\n", nrow(tasks)))
cat(sprintf("tasks with event documents .... %d\n", tasks_with_event_docs))
cat(sprintf("eligible event documents ...... %d\n", length(eligible_ids)))

# ---- 3. validated canonical-corpus path: subset_meta -> one search ----------
tc  <- readRDS(CORPUS_RDS)
sub <- tc$subset(subset_meta = doc_id %in% eligible_ids, copy = TRUE)

hits <- as.data.frame(search_contexts(sub, ANASTOMOSIS_QUERY,
                                      context_level = "sentence",
                                      as_ascii = SEARCH_ASCII)$hits)
if (nrow(hits)) {
    hits <- hits %>%
        transmute(ELTID = as.character(doc_id), sentence = as.integer(sentence)) %>%
        distinct()
} else {
    hits <- tibble(ELTID = character(), sentence = integer())
}

# ---- 4. reconstruct hit sentences +/-1 from subset tokens -------------------
hit_docs <- unique(hits$ELTID)
hit_sent <- hits %>% transmute(doc_id = ELTID, sentence)
targets <- bind_rows(
    hit_sent,
    hit_sent %>% mutate(sentence = sentence - 1L),
    hit_sent %>% mutate(sentence = sentence + 1L)
) %>% filter(sentence >= 1L) %>% distinct()

sent_text <- sub$tokens %>% as.data.frame() %>%
    filter(as.character(doc_id) %in% hit_docs) %>%
    transmute(doc_id = as.character(doc_id), sentence = as.integer(sentence),
              token_id = as.integer(token_id), token = as.character(token)) %>%
    semi_join(targets, by = c("doc_id", "sentence")) %>%
    arrange(doc_id, sentence, token_id) %>%
    group_by(doc_id, sentence) %>%
    summarise(text = untokenize(token), .groups = "drop")

st_hit  <- sent_text %>% transmute(ELTID = doc_id, sentence, hit_text = text)
st_prev <- sent_text %>% transmute(ELTID = doc_id, sentence = sentence + 1L, context_before = text)
st_next <- sent_text %>% transmute(ELTID = doc_id, sentence = sentence - 1L, context_after = text)

# ---- 5. candidates: hit sentences joined to event tasks ---------------------
candidates <- hits %>%
    left_join(st_hit,  by = c("ELTID", "sentence")) %>%
    left_join(st_prev, by = c("ELTID", "sentence")) %>%
    left_join(st_next, by = c("ELTID", "sentence")) %>%
    filter(!is.na(hit_text), nzchar(hit_text)) %>%
    inner_join(doc_meta, by = "ELTID") %>%
    inner_join(tasks, by = c("PATID", "EVTID")) %>%
    mutate(evidence_ref = sprintf("%s::%d", ELTID, sentence)) %>%
    arrange(task_id, RECDATE, ELTID, sentence) %>%
    select(task_id, PATID, EVTID, DATEACTE, evidence_ref, ELTID, sentence,
           RECDATE, RECTYPE, hit_text, context_before, context_after)

# ---- 6. coverage over ALL tasks (no_candidate is a coverage state) ----------
eligible_per_task <- event_docs %>%
    inner_join(tasks, by = c("PATID", "EVTID")) %>%
    group_by(task_id) %>% summarise(n_eligible_docs = n_distinct(ELTID), .groups = "drop")
cand_per_task <- candidates %>%
    group_by(task_id) %>%
    summarise(n_candidate_docs = n_distinct(ELTID),
              n_candidate_sentences = n(), .groups = "drop")

coverage <- tasks %>%
    left_join(eligible_per_task, by = "task_id") %>%
    left_join(cand_per_task, by = "task_id") %>%
    mutate(
        n_eligible_docs       = coalesce(n_eligible_docs, 0L),
        n_candidate_docs      = coalesce(n_candidate_docs, 0L),
        n_candidate_sentences = coalesce(n_candidate_sentences, 0L),
        state = case_when(
            n_eligible_docs == 0L  ~ "no_event_docs",
            n_candidate_docs == 0L ~ "no_candidate",
            TRUE                   ~ "candidate_bearing"
        )
    ) %>%
    select(task_id, PATID, EVTID, DATEACTE, n_eligible_docs,
           n_candidate_docs, n_candidate_sentences, state)

# ---- 7. persist PHI artifacts (gitignored) ----------------------------------
saveRDS(candidates, file.path(OUT_DIR, "candidates.rds"))
saveRDS(coverage,   file.path(OUT_DIR, "coverage.rds"))

# ---- 8. report (SAFE: counts only) ------------------------------------------
cand_docs  <- n_distinct(candidates$ELTID)
cand_tasks <- coverage %>% filter(state == "candidate_bearing") %>% nrow()
cand_sent  <- nrow(candidates)
per <- coverage %>% filter(state == "candidate_bearing")

cat(sprintf("\nLucene query (as_ascii=%s): %s\n", SEARCH_ASCII, ANASTOMOSIS_QUERY))
cat(sprintf("candidate sentences ........... %d\n", cand_sent))
cat(sprintf("candidate documents ........... %d  (legacy regex: 763)\n", cand_docs))
cat(sprintf("candidate-bearing tasks ....... %d  (legacy regex: 242)\n", cand_tasks))
cat(sprintf("no-candidate tasks ............ %d\n",
            sum(coverage$state == "no_candidate")))
cat(sprintf("tasks without event docs ...... %d\n",
            sum(coverage$state == "no_event_docs")))
if (nrow(per)) {
    cat(sprintf("candidate sentences/task (median/max) ... %d / %d\n",
                as.integer(median(per$n_candidate_sentences)), max(per$n_candidate_sentences)))
}
cat(sprintf("\nWrote candidates.rds + coverage.rds to %s/ (gitignored).\n", OUT_DIR))
cat("=====================================================================\n")
