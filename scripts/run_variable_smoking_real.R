#!/usr/bin/env Rscript
# =============================================================================
# Real end-to-end run of the NEW variable vocabulary against a real local model.
# -----------------------------------------------------------------------------
# This is the first time the spec layer (concept -> channel -> retrieval ->
# extractor -> run_variable) is exercised against an actual Ollama model instead
# of a `fake` caller. It drives `documented_smoking_status_periop` over the real
# de-identified smoking pool: raw note text -> create_tcorpus -> Lucene retrieval
# + date-window eligibility -> gemma3:4b structured extraction -> categorical
# values + the audit envelope (source_status, evidence, citation_warning).
#
# MODEL: gemma3:4b only -- it passes scripts/check_grammar_enforcement.R (the
# JSON schema is grammar-enforced). Reasoning models (gpt-oss, gemma4) escape to
# prose and are rejected by that gate; do not use them here.
#
# PRIVACY: console prints ONLY aggregates (counts/rates) -- never note text,
# model evidence quotes, or subject ids. Per-row detail (PHI) is written ONLY to
# outputs/ (gitignored). The subject key is SYNTHETIC (one per sampled note) so
# each note links to exactly one task; the note text and DATEACTE are real.
#
# Run:  Rscript scripts/run_variable_smoking_real.R
# Env:  SMOKE_N=10  DATASETS_DIR=C:/Users/franc/Documents/Datasets  SMOKE_SEED=20260625
# =============================================================================

suppressWarnings(suppressMessages({
    stopifnot(
        requireNamespace("ellmer", quietly = TRUE),
        requireNamespace("corpustools", quietly = TRUE),
        requireNamespace("dplyr", quietly = TRUE))
}))

# ---- engine (same chain as tests/testthat.R, no test-only files) -------------
for (f in c("R/retrieval.R", "R/extract.R", "R/data.R", "R/structured.R",
            "R/multisource.R", "R/spec.R", "R/channels.R", "R/operators.R",
            "R/run_variable.R", "R/concepts-smoking.R", "R/adapter_smoking.R",
            "R/types/smoking.R")) {
    source(f)
}

# ---- config -----------------------------------------------------------------
MODEL    <- "gemma3:4b"                                    # grammar-enforced (vetted)
N        <- as.integer(Sys.getenv("SMOKE_N", "10"))
SEED     <- as.integer(Sys.getenv("SMOKE_SEED", "20260625"))
DATASETS <- Sys.getenv("DATASETS_DIR", "C:/Users/franc/Documents/Datasets")
POOL     <- file.path(DATASETS, "tabac_eval_pool_1000.rds")
OUT_DIR  <- "outputs"
dir.create(OUT_DIR, showWarnings = FALSE, recursive = TRUE)

if (!file.exists(POOL)) {
    stop("Smoking pool not found: ", POOL,
         "\nSet DATASETS_DIR to the de-identified datasets directory.", call. = FALSE)
}

# ---- real data -> the new vocabulary's inputs -------------------------------
# Real note text + real DATEACTE; SYNTHETIC per-note subject key for clean 1:1
# task<->document linkage (the real PATID is irrelevant to the mechanism and is
# not carried, minimising PHI handling).
pool <- readRDS(POOL)
set.seed(SEED)
samp <- pool[sample(nrow(pool), min(N, nrow(pool))), , drop = FALSE]
n    <- nrow(samp)

sid       <- sprintf("S%04d", seq_len(n))                 # synthetic subject == one note
anchor    <- as.Date(samp$DATEACTE)
note_text <- as.character(samp$text_tabac_llm)            # PHI: never printed to console

tasks <- tibble::tibble(task_id = sid, PATID = sid, anchor_date = anchor)

docs_index <- tibble::tibble(
    ELTID = sprintf("E%04d", seq_len(n)), PATID = sid, EVTID = sprintf("V%04d", seq_len(n)),
    RECDATE = anchor,                                     # in-window by construction
    RECTYPE = "note")

corpus <- corpustools::create_tcorpus(
    data.frame(ELTID = docs_index$ELTID, RECTXT = note_text, stringsAsFactors = FALSE),
    text_columns = "RECTXT", doc_column = "ELTID",
    split_sentences = TRUE, remember_spaces = FALSE, verbose = FALSE)

sources <- list(documents = list(corpus = corpus, docs_index = docs_index))

# ---- the variable + the real caller -----------------------------------------
spec <- variable_spec(
    template = documented_smoking_status_periop_template(),
    name = "tabac_statut_periop", unit = "transplant", anchor = "anchor_date")

caller <- make_ollama_caller(model = MODEL, seed = SEED, max_tokens = 512L)

cat(sprintf("Real run | new vocabulary | model=%s | sampled notes=%d | seed=%d\n",
            MODEL, n, SEED))
cat(sprintf("variable=%s combine=%s output=%s window=[%d,%+d]d\n\n",
            spec$name, spec$combine$kind, spec$output$kind,
            spec$window$from_days, spec$window$to_days))

t0  <- Sys.time()
run <- run_variable(spec, tasks, sources, caller = caller, model_name = MODEL)
secs <- as.numeric(difftime(Sys.time(), t0, units = "secs"))

# ---- per-row detail (PHI) -> outputs/ only ----------------------------------
detail <- merge(run$values, run$source_status[, c("task_id", "status")],
                by = "task_id", all.x = TRUE)
ev <- run$evidence
detail$evidence_text <- vapply(detail$task_id, function(tid) {
    e <- ev$hit_text[ev$task_id == tid]
    if (length(e)) paste(unique(e), collapse = " || ") else NA_character_
}, character(1))
stamp <- format(Sys.time(), "%Y%m%d_%H%M%S")
saveRDS(list(spec = spec, run = run, detail = detail),
        file.path(OUT_DIR, sprintf("smoking_realrun_%s.rds", stamp)))

# ---- aggregate report (SAFE: counts/rates only, no PHI) ---------------------
val <- run$values
cat("================ REAL-RUN REPORT (aggregates only) ================\n")
cat(sprintf("notes processed ......... %d\n", nrow(val)))
cat("value distribution ...... ")
cat(paste(sprintf("%s=%d", names(table(factor(val$value, levels = SMOKING_STATUSES),
                                       useNA = "ifany")),
                  table(factor(val$value, levels = SMOKING_STATUSES), useNA = "ifany")),
          collapse = "  "), "\n")
cat("ascertainment ........... ")
cat(paste(sprintf("%s=%d", names(table(val$ascertainment)), table(val$ascertainment)),
          collapse = "  "), "\n")
cat(sprintf("channel status .......... %s\n",
            paste(sprintf("%s=%d", names(table(run$source_status$status)),
                          table(run$source_status$status)), collapse = "  ")))
cat(sprintf("needs_review ............ %d\n", sum(val$needs_review, na.rm = TRUE)))
cat(sprintf("citation_warning ........ %d\n", sum(val$citation_warning, na.rm = TRUE)))
cat(sprintf("grounded (have evidence)  %d / %d\n",
            sum(!is.na(detail$evidence_text)), nrow(detail)))
cat(sprintf("wall time ............... %.1fs (%.1fs/note)\n", secs, secs / max(n, 1)))
cat(sprintf("\nPer-row detail (PHI) -> %s/smoking_realrun_%s.rds (gitignored)\n",
            OUT_DIR, stamp))
cat("===================================================================\n")
