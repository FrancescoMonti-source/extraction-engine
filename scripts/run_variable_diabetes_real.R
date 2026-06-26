#!/usr/bin/env Rscript
# =============================================================================
# Real end-to-end run of the MULTI-SOURCE OR variable (any_positive) against a
# real local model -- the OR path with real extraction on real data.
# -----------------------------------------------------------------------------
# Drives `diabete_pre_greffe` (diabetes_baseline_status_template) over the real
# D0840 cohort with BOTH channels live on the same subjects:
#   - code: pmsi_diag_e10_e14  (deterministic ICD-10 E10-E14 over pmsi$diag)
#   - text: text_diabetes_mentions (Lucene retrieval -> gemma3:4b binary presence)
# combine = any_positive(); the point is TRANSPARENT SOURCE CONTRIBUTION: for each
# positive, WHICH channel(s) carried it (code-only / text-only / both) and which
# were silent -- the engine exposes contribution, it does not infer certainty.
#
# MODEL: gemma3:4b only (passes scripts/check_grammar_enforcement.R). Reasoning
# models escape the grammar and are rejected by that gate.
#
# PRIVACY: console prints ONLY aggregates (counts/rates) -- never note text, model
# evidence quotes, codes, or subject ids. Per-row detail (PHI) -> outputs/ only
# (gitignored). The committed script embeds no data.
#
# CORPUS BOUNDING (faithful): the documents corpus is pre-filtered to notes that
# mention diabetes (regex `diabet|insulin`, a SUPERSET of the channel's Lucene
# terms, so retrieval still does the precise selection) inside the variable's
# window, capped to the MAX_DOCS notes closest to the anchor per subject. This
# only bounds the raw input; eligibility + retrieval semantics are unchanged.
#
# Run:  Rscript scripts/run_variable_diabetes_real.R
# Env:  DIAB_N=8  MAX_DOCS=10  SMOKE_SEED=20260625  DATASETS_DIR=...
# =============================================================================

suppressWarnings(suppressMessages({
    library(dplyr)
    stopifnot(
        requireNamespace("ellmer", quietly = TRUE),
        requireNamespace("corpustools", quietly = TRUE),
        requireNamespace("openxlsx", quietly = TRUE))
}))

source("config/paths.R")
for (f in c("R/retrieval.R", "R/extract.R", "R/data.R", "R/structured.R",
            "R/channel-combine.R", "R/spec.R", "R/channels.R", "R/operators.R",
            "R/run_variable.R", "R/concepts-diabetes.R")) {
    source(f)
}

# ---- config -----------------------------------------------------------------
MODEL    <- "gemma3:4b"
N        <- as.integer(Sys.getenv("DIAB_N", "8"))
MAX_DOCS <- as.integer(Sys.getenv("MAX_DOCS", "10"))      # diabetes-notes per subject (bounding)
SEED     <- as.integer(Sys.getenv("SMOKE_SEED", "20260625"))
OUT_DIR  <- "outputs"
dir.create(OUT_DIR, showWarnings = FALSE, recursive = TRUE)

ch_p   <- path_data("D0840", "chirurgie.xlsx")
doc_p  <- path_data("D0840", "docs")
pmsi_p <- path_data("D0840", "pmsi")
stopifnot(file.exists(ch_p), file.exists(doc_p), file.exists(pmsi_p))

clean_mixed_date <- function(x) {                          # Excel-serial or ISO text -> Date
    x <- trimws(as.character(x)); out <- rep(as.Date(NA), length(x))
    is_num <- grepl("^\\d+(\\.\\d+)?$", x)
    out[is_num] <- as.Date(as.numeric(x[is_num]), origin = "1899-12-30")
    is_txt <- !is_num & nzchar(x); out[is_txt] <- as.Date(x[is_txt]); out
}

# ---- tasks: a sample of recipients (one task per subject) --------------------
ch <- openxlsx::read.xlsx(ch_p) %>%
    transmute(PATID = as.character(PATID_receveur), anchor_date = clean_mixed_date(DATEACTE)) %>%
    filter(!is.na(PATID), PATID != "", !is.na(anchor_date)) %>%
    distinct(PATID, .keep_all = TRUE)
set.seed(SEED)
ch <- ch[sample(nrow(ch), min(N, nrow(ch))), , drop = FALSE]
tasks <- ch %>% transmute(task_id = PATID, PATID, anchor_date)
sids  <- tasks$PATID
win   <- spec_window <- before_anchor(days = 1825L, grace_days = 7L)   # template's window

# ---- code source: real PMSI diagnoses for the sampled subjects --------------
diag <- load_pmsi_diag(pmsi_p) %>% filter(as.character(PATID) %in% sids)

# ---- text source: bounded real-note corpus for the sampled subjects ---------
raw <- readRDS(doc_p) %>%
    transmute(PATID = as.character(PATID), EVTID = as.character(EVTID),
              native_eltid = as.character(ELTID), RECDATE = as.Date(RECDATE),
              RECTYPE = as.character(RECTYPE), RECTXT = as.character(RECTXT)) %>%
    inner_join(tasks[, c("PATID", "anchor_date")], by = "PATID") %>%
    filter(RECDATE >= anchor_date + win$from_days, RECDATE <= anchor_date + win$to_days,
           grepl("diabet|insulin", RECTXT, ignore.case = TRUE)) %>%
    mutate(prox = abs(as.numeric(RECDATE - anchor_date))) %>%
    arrange(PATID, prox) %>%
    group_by(PATID) %>% slice_head(n = MAX_DOCS) %>% ungroup() %>%
    mutate(ELTID = sprintf("E%06d", row_number()))        # unique corpus doc key

docs_index <- raw %>% transmute(ELTID, PATID, EVTID, RECDATE, RECTYPE)
corpus <- corpustools::create_tcorpus(
    data.frame(ELTID = raw$ELTID, RECTXT = raw$RECTXT, stringsAsFactors = FALSE),
    text_columns = "RECTXT", doc_column = "ELTID",
    split_sentences = TRUE, remember_spaces = FALSE, verbose = FALSE)

sources <- list(pmsi_diag = diag, documents = list(corpus = corpus, docs_index = docs_index))

# ---- the variable + the real caller -----------------------------------------
spec <- variable_spec(
    template = diabetes_baseline_status_template(),
    name = "diabete_pre_greffe", unit = "transplant", anchor = "anchor_date")
caller <- make_ollama_caller(model = MODEL, seed = SEED, max_tokens = 512L)

cat(sprintf("Real run | multi-source OR | model=%s | subjects=%d | max_docs/subj=%d | seed=%d\n",
            MODEL, nrow(tasks), MAX_DOCS, SEED))
cat(sprintf("variable=%s combine=%s channels=%s | diabetes-notes in corpus=%d\n\n",
            spec$name, spec$combine$kind, paste(names(spec$channels), collapse = "+"), nrow(raw)))

t0  <- Sys.time()
run <- run_variable(spec, tasks, sources, caller = caller, model_name = MODEL)
secs <- as.numeric(difftime(Sys.time(), t0, units = "secs"))

# ---- per-row detail (PHI) -> outputs/ ---------------------------------------
stamp <- format(Sys.time(), "%Y%m%d_%H%M%S")
saveRDS(list(spec = spec, run = run, native_eltid = raw[, c("ELTID", "native_eltid", "PATID")]),
        file.path(OUT_DIR, sprintf("diabetes_realrun_%s.rds", stamp)))

# ---- aggregate report: channel contribution is the headline -----------------
val <- run$values; ss <- run$channel_status
CODE <- "pmsi_diag_e10_e14"; TEXT <- "text_diabetes_mentions"
code_hit <- ss$task_id[ss$channel == CODE & ss$hit %in% TRUE]
text_hit <- ss$task_id[ss$channel == TEXT & ss$hit %in% TRUE]
pos  <- val$task_id[val$value %in% 1L]
both <- intersect(intersect(pos, code_hit), text_hit)
conly <- setdiff(intersect(pos, code_hit), text_hit)
tonly <- setdiff(intersect(pos, text_hit), code_hit)
chan_contrib <- function(chn) {
    t <- table(ss$contribution[ss$channel == chn])
    paste(sprintf("%s=%d", names(t), as.integer(t)), collapse = "  ")
}
cat("================ REAL-RUN REPORT (aggregates only) ================\n")
cat(sprintf("subjects ................ %d\n", nrow(val)))
cat(sprintf("value: 1=%d  0=%d  NA=%d\n",
            sum(val$value %in% 1L), sum(val$value %in% 0L), sum(is.na(val$value))))
cat(sprintf("ascertainment ........... %s\n",
            paste(sprintf("%s=%d", names(table(val$ascertainment)), table(val$ascertainment)),
                  collapse = "  ")))
cat(sprintf("combine_rule ............ %s\n", run$combine_rule))
cat("\n-- channel contribution (the OR transparency) --\n")
cat(sprintf("  %-24s %s\n", CODE, chan_contrib(CODE)))
cat(sprintf("  %-24s %s\n", TEXT, chan_contrib(TEXT)))
cat(sprintf("\npositives attributed:  both=%d  code-only=%d  text-only=%d\n",
            length(both), length(conly), length(tonly)))
cat(sprintf("wall time ............... %.1fs\n", secs))
cat(sprintf("\nPer-row detail (PHI) -> %s/diabetes_realrun_%s.rds (gitignored)\n", OUT_DIR, stamp))
cat("===================================================================\n")
