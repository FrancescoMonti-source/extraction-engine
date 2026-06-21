#!/usr/bin/env Rscript
# =============================================================================
# Round 3 architecture experiments (Claude — run once per Codex agreement)
# -----------------------------------------------------------------------------
# Settles the canonical-corpus design with measurements, in the agreed order:
#   PHASE 0  build ONE canonical corpus over the whole document collection
#            (single pass, split_sentences=TRUE, remember_spaces=FALSE;
#             NO keyword prefilter, NO cohort filter, NO second corpus).
#   PHASE 1  persistence round-trip   saveRDS -> readRDS, equality + search.
#   PHASE 2  scoping benchmark        A = full search + R join
#                                     B = subset_meta(copy=TRUE) + search + join.
#   PHASE 3  one-pass normalized sentence reconstruction for hit docs only,
#            via a deterministic untokenizer (no exact-spacing second pass).
#
# Retrieval only: no ellmer, no model call.
# PRIVACY: the console prints COUNTS / TIMINGS / BOOLEANS only. Document ids,
# evidence refs and reconstructed sentence text (PHI) go ONLY to outputs/
# (gitignored). Nothing identifying is printed.
# =============================================================================

suppressWarnings(suppressMessages({
    library(dplyr)
    library(stringr)
    library(corpustools)
    stopifnot(requireNamespace("openxlsx", quietly = TRUE))
    stopifnot(packageVersion("corpustools") == "0.5.2")
}))

source("config/paths.R")  # single source of truth for DATASETS / path_data()
OUT_DIR  <- file.path("outputs", "round3-experiments")
dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)

WIN_PRE  <- 365L
WIN_POST <- 7L
REPS     <- 5L

# Pinned smoking query (identical to round 2), sentence level.
SMOKING_QUERY <- paste(
    "tabac*", "tabagi*", "fumeu*", "sevr*", "cigarette*", "paquet*",
    "<(0* OR 1* OR 2* OR 3* OR 4* OR 5* OR 6* OR 7* OR 8* OR 9*) PA>",
    "(0*PA OR 1*PA OR 2*PA OR 3*PA OR 4*PA OR 5*PA OR 6*PA OR 7*PA OR 8*PA OR 9*PA)",
    sep = " OR "
)

# ---- helpers ----------------------------------------------------------------
elapsed <- function(expr) as.numeric(system.time(expr)["elapsed"])

# Deterministic normalized untokenizer (readable, NOT a claim of exact source
# whitespace). Single tested punctuation policy.
untokenize <- function(toks) {
    s <- paste(toks, collapse = " ")
    s <- gsub(" ([,.;:!?%)\\]}])", "\\1", s, perl = TRUE)  # no space before close punct
    s <- gsub("([(\\[{]) ", "\\1", s, perl = TRUE)          # no space after open punct
    s <- gsub(" ?- ?", "-", s)                               # tighten hyphens
    s <- gsub(" ?' ?", "'", s)                               # tighten apostrophes
    trimws(gsub("\\s+", " ", s))
}
stopifnot(identical(untokenize(c("non", "-", "fumeur", ",", "20", "PA", ".")),
                    "non-fumeur, 20 PA."))

mb <- function(x) as.numeric(x) / 1e6

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

cat("=============== ROUND 3 EXPERIMENTS (aggregates / timings only) ==============\n")

# ---- tasks (task_id = PATID::DATEACTE::role) --------------------------------
ch <- openxlsx::read.xlsx(path_data("D0840", "chirurgie.xlsx")) %>%
    mutate(DATEACTE = clean_mixed_date(DATEACTE))
tasks <- bind_rows(
    ch %>% transmute(DATEACTE, role = "donneur",  PATID = as.character(PATID_donneur)),
    ch %>% transmute(DATEACTE, role = "receveur", PATID = as.character(PATID_receveur))
) %>%
    filter(!is.na(PATID), PATID != "", !is.na(DATEACTE)) %>%
    distinct() %>%
    mutate(task_id = sprintf("%s::%s::%s", PATID, format(DATEACTE, "%Y-%m-%d"), role))
cohort_patids <- unique(tasks$PATID)

# ---- documents: WHOLE collection, no prefilter, no cohort filter ------------
docs_all <- readRDS(path_data("D0840", "docs")) %>%
    transmute(
        ELTID   = as.character(ELTID),
        PATID   = as.character(PATID),
        RECDATE = as.Date(RECDATE),
        RECTYPE = as.character(RECTYPE),
        RECTXT  = as.character(RECTXT)
    )
# Drop whitespace-only documents (no tokens to index). The gap from the raw
# count is expected accounting, NOT corpus loss: 65,408 raw -> 65,397 non-empty
# (11 whitespace-only docs) on the current D0840 docs snapshot.
docs <- docs_all %>% filter(nzchar(trimws(RECTXT)))
n_raw <- nrow(docs_all)
n_empty <- n_raw - nrow(docs)

n_cohort_docs <- sum(docs$PATID %in% cohort_patids)
cat(sprintf("tasks=%d | cohort patients=%d\n", nrow(tasks), length(cohort_patids)))
cat(sprintf("collection docs raw=%d | non-empty=%d (dropped %d whitespace-only)\n",
            n_raw, nrow(docs), n_empty))
cat(sprintf("cohort docs=%d (%.1f%% of non-empty)\n", n_cohort_docs,
            100 * n_cohort_docs / nrow(docs)))

# =============================================================================
# PHASE 0 — build the canonical corpus ONCE
# =============================================================================
gc(reset = TRUE)
build_s <- elapsed(tc <- create_tcorpus(
    docs, text_columns = "RECTXT", doc_column = "ELTID",
    split_sentences = TRUE, remember_spaces = FALSE
))
n_sentences <- nrow(unique(tc$tokens[, c("doc_id", "sentence")]))
tok_mb <- mb(object.size(tc$tokens)) + mb(object.size(tc$meta))
peak_mb <- sum(gc()[, 6])  # column 6 = "max used (Mb)" for Ncells + Vcells
cat(sprintf("\n[PHASE 0] canonical build\n"))
cat(sprintf("  docs=%d  tokens=%d  sentences=%d  | build=%.1fs\n",
            tc$n_meta, tc$n, n_sentences, build_s))
cat(sprintf("  in-memory tokens+meta=%.0f MB | R session peak=%.0f MB\n",
            tok_mb, peak_mb))

# =============================================================================
# PHASE 1 — persistence round-trip
# =============================================================================
rds_path <- file.path(OUT_DIR, "canonical_tcorpus.rds")
save_s   <- elapsed(saveRDS(tc, rds_path))
size_mb  <- mb(file.info(rds_path)$size)
load_s   <- elapsed(tc2 <- readRDS(rds_path))

ok_docs   <- tc$n_meta == tc2$n_meta
ok_tokens <- tc$n == tc2$n
ok_meta   <- isTRUE(all.equal(as.data.frame(tc$meta), as.data.frame(tc2$meta)))

# search both; the pinned-query hit set must be byte-identical, and searching
# the reloaded corpus must work without rebuilding any index.
h1 <- as.data.frame(search_contexts(tc,  SMOKING_QUERY, context_level = "sentence",
                                    as_ascii = FALSE)$hits)
h2 <- as.data.frame(search_contexts(tc2, SMOKING_QUERY, context_level = "sentence",
                                    as_ascii = FALSE)$hits)
ref1 <- sort(unique(sprintf("%s::%s", h1$doc_id, h1$sentence)))
ref2 <- sort(unique(sprintf("%s::%s", h2$doc_id, h2$sentence)))
ok_search <- identical(ref1, ref2)

cat(sprintf("\n[PHASE 1] persistence (saveRDS/readRDS)\n"))
cat(sprintf("  file=%.0f MB | save=%.1fs | load=%.1fs\n", size_mb, save_s, load_s))
cat(sprintf("  equal docs=%s tokens=%s meta=%s | reloaded-search hits=%d equal=%s\n",
            ok_docs, ok_tokens, ok_meta, length(ref2), ok_search))

# =============================================================================
# PHASE 2 — full search + R join  vs  subset_meta(copy=TRUE) + search + join
# =============================================================================
doc_meta <- docs %>% distinct(ELTID, PATID, RECDATE, RECTYPE)

# eligible docs = cohort patients' docs within ANY task window (subset target)
eligible_ids <- doc_meta %>%
    inner_join(tasks, by = "PATID", relationship = "many-to-many") %>%
    filter(RECDATE >= DATEACTE - WIN_PRE, RECDATE <= DATEACTE + WIN_POST) %>%
    distinct(ELTID) %>% pull(ELTID)

scope_join <- function(hits_df) {
    hits_df %>%
        transmute(ELTID = as.character(doc_id), sentence = as.integer(sentence)) %>%
        distinct() %>%
        inner_join(doc_meta, by = "ELTID") %>%
        inner_join(tasks, by = "PATID", relationship = "many-to-many") %>%
        filter(RECDATE >= DATEACTE - WIN_PRE, RECDATE <= DATEACTE + WIN_POST) %>%
        transmute(task_id, evidence_ref = sprintf("%s::%d", ELTID, sentence)) %>%
        distinct() %>%
        arrange(task_id, evidence_ref)
}

search_hits <- function(corpus) {
    as.data.frame(search_contexts(corpus, SMOKING_QUERY,
                                  context_level = "sentence", as_ascii = FALSE)$hits)
}

# correctness: both paths must produce the identical final eligible ref set
refsA <- scope_join(search_hits(tc))
sub0  <- tc$subset(subset_meta = doc_id %in% eligible_ids, copy = TRUE)
h_sub <- search_hits(sub0)             # engine-default hit set (eligible docs only)
refsB <- scope_join(h_sub)
ok_paths_equal <- identical(refsA, refsB)
sub_tokens <- sub0$n
sub_mb <- mb(object.size(sub0$tokens)) + mb(object.size(sub0$meta))
rm(sub0); gc()

# warm-up (discard), then timed reps
invisible(scope_join(search_hits(tc)))
A <- vapply(seq_len(REPS), function(i) {
    s <- elapsed(hh <- search_hits(tc))
    j <- elapsed(scope_join(hh))
    c(subset = 0, search = s, join = j, total = s + j)
}, numeric(4))

invisible({ s <- tc$subset(subset_meta = doc_id %in% eligible_ids, copy = TRUE); rm(s); gc() })
B <- vapply(seq_len(REPS), function(i) {
    cp <- elapsed(sb <- tc$subset(subset_meta = doc_id %in% eligible_ids, copy = TRUE))
    s  <- elapsed(hh <- search_hits(sb))
    j  <- elapsed(scope_join(hh))
    rm(sb); gc()
    c(subset = cp, search = s, join = j, total = cp + s + j)
}, numeric(4))

med <- function(M) apply(M, 1, median)
mA <- med(A); mB <- med(B)

cat(sprintf("\n[PHASE 2] scoping benchmark (median of %d warm reps)\n", REPS))
cat(sprintf("  eligible in-window docs=%d / collection=%d (%.1f%%)\n",
            length(eligible_ids), nrow(doc_meta),
            100 * length(eligible_ids) / nrow(doc_meta)))
cat(sprintf("  canonical tokens=%d (%.0f MB) | subset tokens=%d (%.0f MB)\n",
            tc$n, tok_mb, sub_tokens, sub_mb))
cat(sprintf("  A full-search+join : subset=%.3fs search=%.3fs join=%.3fs total=%.3fs\n",
            mA["subset"], mA["search"], mA["join"], mA["total"]))
cat(sprintf("  B subset+search+join: subset=%.3fs search=%.3fs join=%.3fs total=%.3fs\n",
            mB["subset"], mB["search"], mB["join"], mB["total"]))
cat(sprintf("  final eligible refs A=%d B=%d | identical=%s\n",
            nrow(refsA), nrow(refsB), ok_paths_equal))
cat(sprintf("  verdict: %s\n",
            if (mA["total"] <= mB["total"])
                "full-corpus search + R join is the default (subset adds copy cost for no gain)"
            else
                "subset_meta wins on total time — keep as measured optimization"))

# =============================================================================
# PHASE 3 — one-pass normalized reconstruction for HIT SENTENCES +/-1 only
# =============================================================================
# Reconstruct ONLY the citable sentence and its two neighbours per hit, never
# every sentence in the document. That keeps the sentence table proportional to
# the number of hits instead of materializing a global one. Use the ENGINE-DEFAULT
# hit set (h_sub: subset/eligible-doc search), not the full-corpus h1 (whose
# out-of-window hits are never cited). Reconstruction reads canonical tokens,
# which are identical to the subset's for these docs.
hit_docs <- unique(as.character(h_sub$doc_id))
hit_sent <- h_sub %>% transmute(doc_id = as.character(doc_id),
                                sentence = as.integer(sentence))
targets <- bind_rows(
    hit_sent,
    hit_sent %>% mutate(sentence = sentence - 1L),
    hit_sent %>% mutate(sentence = sentence + 1L)
) %>% filter(sentence >= 1L) %>% distinct()

recon_s <- elapsed({
    tok_target <- tc$tokens %>% as.data.frame() %>%
        filter(as.character(doc_id) %in% hit_docs) %>%
        transmute(doc_id = as.character(doc_id), sentence = as.integer(sentence),
                  token_id = as.integer(token_id), token = as.character(token)) %>%
        semi_join(targets, by = c("doc_id", "sentence")) %>%
        arrange(doc_id, sentence, token_id)
    sent_text <- tok_target %>%
        group_by(doc_id, sentence) %>%
        summarise(text = untokenize(token), .groups = "drop")
})
# PHI -> outputs/ only (reconstructed clinical sentences); console prints counts.
saveRDS(sent_text, file.path(OUT_DIR, "hit_sentences_normalized.rds"))
cat(sprintf("\n[PHASE 3] one-pass normalized reconstruction (hit sentences +/-1)\n"))
cat(sprintf("  hit docs=%d | hit sentences=%d | reconstructed sentences=%d | %.1fs\n",
            length(hit_docs), nrow(hit_sent), nrow(sent_text), recon_s))

cat(sprintf("\nArtifacts (gitignored): %s/\n", OUT_DIR))
cat("=============================================================================\n")
