#!/usr/bin/env Rscript
# =============================================================================
# Real end-to-end run of the EVENT-scoped multi-field variable against a real
# local model -- the last spine path never run with a model (was fixtures-only).
# -----------------------------------------------------------------------------
# Drives `recipient_anastomoses` (recipient_anastomoses_template, struct_output)
# over the real D0840 cohort. The text channel is EVENT-scoped: eligibility is the
# recipient's documents from the SAME surgical event (PATID + EVTID), NOT a date
# window. run_variable() resolves that from raw documents:
#   raw operative-report docs -> create_tcorpus -> event eligibility (PATID+EVTID)
#   -> Lucene retrieval -> gemma3:4b nested multi-field extraction -> per-field
#   values (field-level acceptance) + audit envelope.
#
# MODEL: gemma3:4b only (passes scripts/check_grammar_enforcement.R).
#
# PRIVACY: console prints ONLY aggregates -- never note text, evidence quotes, or
# subject/event ids. Per-row detail (PHI) -> outputs/ only (gitignored). Committed
# script embeds no data.
#
# CORPUS BOUNDING (faithful): docs are restricted to the sampled events (PATID+EVTID)
# and to operative-report-like notes mentioning anastomosis terms (regex
# `anastom|gregoir|ureter|reimplant|iliaque`, a SUPERSET of the channel's Lucene
# query, so retrieval still does the precise selection), capped per event. Bounds the
# raw input only; event eligibility + retrieval semantics are unchanged. Tasks are
# sampled among recipients that HAVE >=1 such document, so the model has something to
# extract (a mechanism run, not a coverage estimate).
#
# Run:  Rscript scripts/run_variable_anastomoses_real.R
# Env:  ANA_N=6  MAX_DOCS=6  SMOKE_SEED=20260625  DATASETS_DIR=...
# =============================================================================

suppressWarnings(suppressMessages({
    library(dplyr)
    stopifnot(
        requireNamespace("ellmer", quietly = TRUE),
        requireNamespace("corpustools", quietly = TRUE))
}))

source("config/paths.R")
for (f in c("R/retrieval.R", "R/extract.R", "R/data.R", "R/spec.R", "R/channels.R",
            "R/operators.R", "R/run_variable.R", "R/concepts-anastomoses.R",
            "R/adapter_anastomoses.R", "R/types/anastomoses.R")) {
    source(f)
}

# ---- config -----------------------------------------------------------------
MODEL    <- "gemma3:4b"
N        <- as.integer(Sys.getenv("ANA_N", "6"))
MAX_DOCS <- as.integer(Sys.getenv("MAX_DOCS", "6"))       # CRO-like notes per event (bounding)
SEED     <- as.integer(Sys.getenv("SMOKE_SEED", "20260625"))
OUT_DIR  <- "outputs"
dir.create(OUT_DIR, showWarnings = FALSE, recursive = TRUE)

ch_p  <- path_data("D0840", "chirurgie.xlsx")
doc_p <- path_data("D0840", "docs")
stopifnot(file.exists(ch_p), file.exists(doc_p))

ANA_RX <- "anastom|gregoir|ureter|reimplant|iliaque"      # superset of ANASTOMOSES_QUERY

# ---- tasks: recipient surgical events ---------------------------------------
all_tasks <- anastomoses_load_tasks(ch_p)

# ---- raw docs restricted to those events + anastomosis-mentioning notes ------
docs <- readRDS(doc_p) %>%
    transmute(PATID = as.character(PATID), EVTID = as.character(EVTID),
              native_eltid = as.character(ELTID), RECDATE = as.Date(RECDATE),
              RECTYPE = as.character(RECTYPE), RECTXT = as.character(RECTXT)) %>%
    semi_join(all_tasks, by = c("PATID", "EVTID")) %>%                 # same-event docs only
    filter(grepl(ANA_RX, RECTXT, ignore.case = TRUE))

# sample among events that actually have >=1 operative-report-like note
events_with_docs <- docs %>% distinct(PATID, EVTID)
cand_tasks <- all_tasks %>% semi_join(events_with_docs, by = c("PATID", "EVTID"))
set.seed(SEED)
tasks <- cand_tasks[sample(nrow(cand_tasks), min(N, nrow(cand_tasks))), , drop = FALSE]

raw <- docs %>%
    semi_join(tasks, by = c("PATID", "EVTID")) %>%
    group_by(PATID, EVTID) %>% slice_head(n = MAX_DOCS) %>% ungroup() %>%
    mutate(ELTID = sprintf("E%06d", row_number()))        # unique corpus doc key
docs_index <- raw %>% transmute(ELTID, PATID, EVTID, RECDATE, RECTYPE)
corpus <- corpustools::create_tcorpus(
    data.frame(ELTID = raw$ELTID, RECTXT = raw$RECTXT, stringsAsFactors = FALSE),
    text_columns = "RECTXT", doc_column = "ELTID",
    split_sentences = TRUE, remember_spaces = FALSE, verbose = FALSE)

sources <- list(documents = list(corpus = corpus, docs_index = docs_index))

# ---- the variable + the real caller -----------------------------------------
spec <- variable_spec(
    template = recipient_anastomoses_template(),
    name = "recipient_anastomoses", unit = "transplant", anchor = "anchor_date")
caller <- make_ollama_caller(model = MODEL, seed = SEED, max_tokens = 1024L)

cat(sprintf("Real run | event-scoped multi-field | model=%s | events=%d | max_docs/event=%d | seed=%d\n",
            MODEL, nrow(tasks), MAX_DOCS, SEED))
cat(sprintf("variable=%s combine=%s window=%s | corpus docs=%d\n\n",
            spec$name, spec$combine$kind,
            if (is.null(spec$window)) "NULL (event scope)" else "date", nrow(raw)))

t0  <- Sys.time()
run <- run_variable(spec, tasks, sources, caller = caller, model_name = MODEL)
secs <- as.numeric(difftime(Sys.time(), t0, units = "secs"))

stamp <- format(Sys.time(), "%Y%m%d_%H%M%S")
saveRDS(list(spec = spec, run = run, native_eltid = raw[, c("ELTID", "native_eltid", "PATID", "EVTID")]),
        file.path(OUT_DIR, sprintf("anastomoses_realrun_%s.rds", stamp)))

# ---- aggregate report (SAFE: counts/rates only, no PHI) ---------------------
val <- run$values; ss <- run$channel_status
cat("================ REAL-RUN REPORT (aggregates only) ================\n")
cat(sprintf("events processed ........ %d\n", nrow(ss)))
cat(sprintf("channel status .......... %s\n",
            paste(sprintf("%s=%d", names(table(ss$status)), table(ss$status)), collapse = "  ")))
# field-level acceptance: a field is "documented" (extracted value), valid-absence
# (not_documented), or invalid (documented but ungrounded/unusable -> needs_review).
cat("\n-- per field: documented (extracted value) / invalid / total events --\n")
if (nrow(val)) {
    by_field <- val %>% group_by(field) %>%
        summarise(documented = sum(!is.na(value)),
                  invalid = sum(field_validity == "invalid"), n = n(), .groups = "drop")
    for (i in seq_len(nrow(by_field))) {
        cat(sprintf("  %-50s documented=%d  invalid=%d  / %d\n",
                    by_field$field[i], by_field$documented[i], by_field$invalid[i], by_field$n[i]))
    }
    cat(sprintf("  (fields with an extracted value: %d of %d; the rest are valid 'not_documented')\n",
                sum(!is.na(val$value)), nrow(val)))
} else cat("  (no fields produced)\n")
cat(sprintf("\nneeds_review events ..... %d\n", sum(ss$needs_review, na.rm = TRUE)))
cat(sprintf("citation_warning events . %d\n", sum(ss$citation_warning, na.rm = TRUE)))
cat(sprintf("events with evidence .... %d / %d\n",
            length(unique(run$evidence$task_id)), nrow(ss)))
cat(sprintf("wall time ............... %.1fs\n", secs))
cat(sprintf("\nPer-row detail (PHI) -> %s/anastomoses_realrun_%s.rds (gitignored)\n", OUT_DIR, stamp))
cat("===================================================================\n")
