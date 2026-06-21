#!/usr/bin/env Rscript
# =============================================================================
# Parallel round 2 (Claude branch) — corpustools/Lucene smoking retrieval
# -----------------------------------------------------------------------------
# Implements the pinned round-two retrieval contract (HANDOFF.md, 9936457 +
# 0a2d98a + c1238c7). Retrieval ONLY: no ellmer, prompt, validation, or cohort
# values this round. Produces the dry-run citable-hit workbook.
#
# Pinned inputs (must match Codex's independent build):
#   - task_id      = PATID::DATEACTE::role   (role kept: real PATID collision)
#   - scope        = RECDATE in [DATEACTE - 365, DATEACTE + 7]
#   - query        = SMOKING_QUERY below, search_contexts(context_level="sentence",
#                    as_ascii = FALSE)
#   - evidence_ref = ELTID::sentence (native corpustools coordinates)
#   - citable unit = the hit sentence; +/-1 sentence shown as context only
#   - dedup        = normalized hit text, canonical occurrence by
#                    min|days_from_anchor| -> earliest RECDATE -> smallest ELTID
#                    -> smallest sentence
#   - tokenization = two-pass corpustools 0.5.2 (c1238c7): sentences from a
#                    split corpus, spacing from a no-split corpus, joined by
#                    ELTID + token_id with equal-count/equal-text assertions.
#
# RECTYPE is metadata only; it must not affect retrieval or ordering.
# PRIVACY: console prints aggregates only; the workbook (PHI) -> outputs/ (gitignored).
# =============================================================================

suppressWarnings(suppressMessages({
    library(dplyr)
    library(stringr)
    library(corpustools)
    stopifnot(requireNamespace("openxlsx", quietly = TRUE))
    stopifnot(packageVersion("corpustools") == "0.5.2")
}))

DATASETS <- Sys.getenv("DATASETS_DIR", "C:/Users/franc/Documents/Datasets/D0840")
OUT_DIR <- file.path("outputs", "smoking-round2")
dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)

WIN_PRE <- 365L
WIN_POST <- 7L

# Pinned Lucene query (sentence level).
SMOKING_QUERY <- paste(
    "tabac*", "tabagi*", "fumeu*", "sevr*", "cigarette*", "paquet*",
    "<(0* OR 1* OR 2* OR 3* OR 4* OR 5* OR 6* OR 7* OR 8* OR 9*) PA>",
    "(0*PA OR 1*PA OR 2*PA OR 3*PA OR 4*PA OR 5*PA OR 6*PA OR 7*PA OR 8*PA OR 9*PA)",
    sep = " OR "
)

# Performance-only superset pre-filter: any document that can yield a Lucene hit
# contains one of these substrings, so restricting the search corpus to cohort
# patients' matching documents leaves the hit set identical to a full-corpus
# search. This is NOT a regex retrieval method — Lucene still decides every hit.
KEYWORD_SUPERSET <- "tabac|tabagi|fumeu|sevr|cigarette|paquet|\\d\\s*PA\\b"

# ---- helpers ----------------------------------------------------------------
norm <- function(x) tolower(str_squish(x))

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

# ---- 1. tasks (task_id = PATID::DATEACTE::role) ------------------------------
ch <- openxlsx::read.xlsx(file.path(DATASETS, "chirurgie.xlsx")) %>%
    mutate(DATEACTE = clean_mixed_date(DATEACTE))

tasks <- bind_rows(
    ch %>% transmute(DATEACTE, role = "donneur", PATID = as.character(PATID_donneur)),
    ch %>% transmute(DATEACTE, role = "receveur", PATID = as.character(PATID_receveur))
) %>%
    filter(!is.na(PATID), PATID != "", !is.na(DATEACTE)) %>%
    distinct() %>%
    mutate(task_id = sprintf("%s::%s::%s", PATID, format(DATEACTE, "%Y-%m-%d"), role))

cohort_patids <- unique(tasks$PATID)

# ---- 2. documents + performance superset ------------------------------------
docs <- readRDS(file.path(DATASETS, "docs")) %>%
    transmute(
        ELTID = as.character(ELTID),
        PATID = as.character(PATID),
        RECDATE = as.Date(RECDATE),
        RECTYPE = as.character(RECTYPE),
        RECTXT = as.character(RECTXT)
    ) %>%
    filter(
        PATID %in% cohort_patids,
        nzchar(trimws(RECTXT)),
        str_detect(RECTXT, regex(KEYWORD_SUPERSET, ignore_case = TRUE))
    )

cat(sprintf(
    "tasks=%d | cohort patients=%d | search docs (cohort+superset)=%d\n",
    nrow(tasks), length(cohort_patids), nrow(docs)
))

# ---- 3. two-pass corpus (c1238c7) -------------------------------------------
# Pass A: sentence labels.
tcA <- create_tcorpus(docs, text_columns = "RECTXT", doc_column = "ELTID",
                      split_sentences = TRUE, remember_spaces = FALSE)

# ---- 4. Lucene query at sentence level --------------------------------------
hits <- search_contexts(tcA, SMOKING_QUERY, context_level = "sentence",
                        as_ascii = FALSE)$hits %>%
    as.data.frame() %>%
    transmute(ELTID = as.character(doc_id), sentence = as.integer(sentence)) %>%
    distinct()

relevant_eltids <- unique(hits$ELTID)
cat(sprintf("Lucene hit sentences=%d across docs=%d\n",
            nrow(hits), length(relevant_eltids)))

# ---- 5. reconstruct sentence text (Pass B + join) ---------------------------
# Pass B over only the relevant documents: original spacing, no sentence split.
docs_rel <- docs %>% filter(ELTID %in% relevant_eltids)
tcB <- create_tcorpus(docs_rel, text_columns = "RECTXT", doc_column = "ELTID",
                      split_sentences = FALSE, remember_spaces = TRUE)

tokA <- tcA$tokens %>% as.data.frame() %>%
    filter(as.character(doc_id) %in% relevant_eltids) %>%
    transmute(ELTID = as.character(doc_id), token_id = as.integer(token_id),
              sentence = as.integer(sentence), token_a = as.character(token))
tokB <- tcB$tokens %>% as.data.frame() %>%
    transmute(ELTID = as.character(doc_id), token_id = as.integer(token_id),
              token = as.character(token), space = as.character(space))

tok <- inner_join(tokA, tokB, by = c("ELTID", "token_id"))
# pinned assertions: equal counts and identical token text across passes
stopifnot(
    nrow(tok) == nrow(tokA),
    nrow(tok) == nrow(tokB),
    all(tok$token_a == tok$token)
)

sentence_text <- tok %>%
    arrange(ELTID, sentence, token_id) %>%
    group_by(ELTID, sentence) %>%
    summarise(text = trimws(paste0(token, space, collapse = "")), .groups = "drop")

# Vectorized: hit text plus +/-1 neighbour context via shifted self-joins.
st_hit <- sentence_text %>% transmute(ELTID, sentence, hit_text = text)
st_prev <- sentence_text %>% transmute(ELTID, sentence = sentence + 1L, context_before = text)
st_next <- sentence_text %>% transmute(ELTID, sentence = sentence - 1L, context_after = text)

# ---- 6. attach text + context, then patient/temporal eligibility ------------
hit_rows <- hits %>%
    left_join(st_hit, by = c("ELTID", "sentence")) %>%
    left_join(st_prev, by = c("ELTID", "sentence")) %>%
    left_join(st_next, by = c("ELTID", "sentence")) %>%
    filter(!is.na(hit_text), nzchar(hit_text))

doc_meta <- docs %>% distinct(ELTID, PATID, RECDATE, RECTYPE)

eligible <- hit_rows %>%
    inner_join(doc_meta, by = "ELTID") %>%
    inner_join(tasks, by = "PATID", relationship = "many-to-many") %>%
    filter(RECDATE >= DATEACTE - WIN_PRE, RECDATE <= DATEACTE + WIN_POST) %>%
    mutate(
        evidence_ref = sprintf("%s::%d", ELTID, sentence),
        days_from_anchor = as.numeric(RECDATE - DATEACTE)
    )

# ---- 7. copy-forward dedup within task (pinned canonical order) -------------
deduped <- eligible %>%
    mutate(normalized_hit_text = norm(hit_text)) %>%
    group_by(task_id, normalized_hit_text) %>%
    arrange(abs(days_from_anchor), RECDATE, ELTID, sentence, .by_group = TRUE) %>%
    summarise(
        # duplicate fields first: they read the full grouped vectors, before the
        # first() reassignments below shadow `evidence_ref` / `RECDATE` with scalars.
        n_duplicate_occurrences = n() - 1L,
        duplicate_refs = paste(evidence_ref[-1], collapse = " | "),
        duplicate_dates = paste(format(RECDATE[-1], "%Y-%m-%d"), collapse = " | "),
        evidence_ref = first(evidence_ref),
        hit_text = first(hit_text),
        context_before = first(context_before),
        context_after = first(context_after),
        PATID = first(PATID),
        DATEACTE = first(DATEACTE),
        role = first(role),
        ELTID = first(ELTID),
        sentence = first(sentence),
        RECDATE = first(RECDATE),
        RECTYPE = first(RECTYPE),
        days_from_anchor = first(days_from_anchor),
        .groups = "drop"
    ) %>%
    select(
        task_id, evidence_ref, hit_text, context_before, context_after,
        PATID, DATEACTE, role, ELTID, sentence, RECDATE, RECTYPE,
        days_from_anchor, n_duplicate_occurrences, duplicate_refs, duplicate_dates
    ) %>%
    arrange(task_id, abs(days_from_anchor), evidence_ref)

# ---- 8. outputs -------------------------------------------------------------
stamp <- format(Sys.time(), "%Y%m%d_%H%M%S")
openxlsx::write.xlsx(
    deduped,
    file.path(OUT_DIR, sprintf("smoking_retrieval_round2_%s.xlsx", stamp)),
    overwrite = TRUE
)

# ---- 9. report (SAFE: counts only) ------------------------------------------
per_task <- deduped %>% count(task_id, name = "n")
cat("============ ROUND 2 RETRIEVAL (corpustools/Lucene) — aggregates ============\n")
cat(sprintf("tasks (total) ................ %d\n", nrow(tasks)))
cat(sprintf("candidate-bearing tasks ...... %d\n", nrow(per_task)))
cat(sprintf("no-hit tasks ................. %d\n", nrow(tasks) - nrow(per_task)))
cat(sprintf("eligible hits (pre-dedup) .... %d\n", nrow(eligible)))
cat(sprintf("citable hits (post-dedup) .... %d\n", nrow(deduped)))
cat(sprintf("collapsed copy-forward ....... %d\n", nrow(eligible) - nrow(deduped)))
if (nrow(per_task)) {
    cat(sprintf("hits/task (median/max) ....... %d / %d\n",
                as.integer(median(per_task$n)), max(per_task$n)))
}
cat(sprintf("\nWrote dry-run workbook to %s/ (gitignored).\n", OUT_DIR))
cat("=============================================================================\n")
