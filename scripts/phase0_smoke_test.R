#!/usr/bin/env Rscript
# =============================================================================
# Phase 0 — contract smoke test  (DESIGN.md 8, step 1)
# -----------------------------------------------------------------------------
# Validates the MECHANISM, not accuracy (no gold needed). It checks the five
# clauses of the Phase 0 contract on the real `tabac` pool:
#   1. ellmer -> Ollama structured path returns an R object
#   2. schema enforcement      (smoking_status is always one of the 4 enum values)
#   3. missingness             (not_stated is reachable)
#   4. evidence-substring check (model's quote is an EXACT substring of the source)
#   5. failure capture         (errors/timeouts are recorded, never crash the run)
# It also writes a MINIMAL attempt record from the first spike (Review #2):
#   attempt_id, ts, model, schema_version, prompt_version, status, latency, error.
#
# PRIVACY: this script prints ONLY aggregates and category counts to stdout.
# Note text and model-produced evidence quotes are PHI and are written ONLY to
# outputs/ (gitignored) — never to the console.
#
# Run:  Rscript scripts/phase0_smoke_test.R
# Env overrides: SMOKE_MODELS="gemma3:4b,gpt-oss:20b"  SMOKE_N=12  DATASETS_DIR=...
# =============================================================================

suppressWarnings(suppressMessages({
  stopifnot(requireNamespace("ellmer",  quietly = TRUE),
            requireNamespace("writexl", quietly = TRUE),   # per-row detail -> .xlsx (UTF-8 safe)
            requireNamespace("readr",   quietly = TRUE))   # attempts -> UTF-8+BOM csv
}))

# ---- config -----------------------------------------------------------------
DATASETS       <- Sys.getenv("DATASETS_DIR", "C:/Users/franc/Documents/Datasets")
POOL           <- file.path(DATASETS, "tabac_eval_pool_1000.rds")
MODELS         <- strsplit(Sys.getenv("SMOKE_MODELS", "gemma3:4b"), ",")[[1]]
N              <- as.integer(Sys.getenv("SMOKE_N", "12"))
NUM_CTX        <- as.integer(Sys.getenv("SMOKE_NUM_CTX", "8192"))
SEED           <- 20260619L
SCHEMA_VERSION <- "tabac-v1"
PROMPT_VERSION <- "tabac-fr-v1"
OUT_DIR        <- file.path(dirname(dirname(normalizePath(sub("--file=", "",
                    grep("--file=", commandArgs(FALSE), value = TRUE)[1]), mustWork = FALSE))),
                    "outputs")
if (is.na(OUT_DIR) || !nzchar(OUT_DIR)) OUT_DIR <- "outputs"
dir.create(OUT_DIR, showWarnings = FALSE, recursive = TRUE)

# ---- the variable spec, as DATA (JSON Schema string) ------------------------
SCHEMA_JSON <- '{
  "type": "object",
  "description": "Statut tabagique du patient, extrait d un extrait de dossier clinique en francais.",
  "properties": {
    "smoking_status": {
      "type": "string",
      "enum": ["never", "former", "current", "not_stated"],
      "description": "never=jamais fume / non-fumeur ; former=ancien fumeur, sevrage, arret ; current=fumeur actif ; not_stated=non mentionne."
    },
    "evidence": {
      "type": "string",
      "description": "Citation VERBATIM exacte (copiee-collee) du texte qui justifie le statut. Chaine vide si not_stated."
    }
  },
  "required": ["smoking_status", "evidence"]
}'

SYSTEM_PROMPT <- paste(
  "Tu es un outil d'extraction clinique. A partir d'un extrait de dossier medical en francais,",
  "determine le statut tabagique du patient et reponds UNIQUEMENT selon le schema JSON impose.",
  "Le champ 'evidence' doit etre une citation EXACTE et VERBATIM copiee depuis le texte fourni",
  "(aucune reformulation, aucun ajout). Si le statut est 'not_stated', mets 'evidence' a \"\"."
)

ENUM <- c("never", "former", "current", "not_stated")

# ---- helpers ----------------------------------------------------------------
norm <- function(x) tolower(gsub("\\s+", " ", trimws(x)))   # whitespace/case-insensitive view

make_chat <- function(model) {
  # ellmer routes Ollama through its OpenAI-compatible /v1 endpoint, so determinism
  # comes from OpenAI-style PARAMS (temperature + seed) — NOT from api_args$options
  # (that path is silently ignored on /v1, which let the model run stochastic).
  ellmer::chat_ollama(
    model         = model,
    system_prompt = SYSTEM_PROMPT,
    params        = ellmer::params(temperature = 0, seed = SEED),
    api_args      = list(options = list(num_ctx = NUM_CTX)),  # best-effort; /v1 may ignore
    echo          = "none"
  )
}

run_one <- function(chat, type, text) {
  t0 <- Sys.time()
  out <- tryCatch(
    {
      res <- chat$chat_structured(text, type = type)
      list(status = "ok", res = res, error = NA_character_)
    },
    error = function(e) list(status = "error", res = NULL,
                             error = conditionMessage(e))
  )
  out$latency_ms <- as.numeric(difftime(Sys.time(), t0, units = "secs")) * 1000
  out
}

validate <- function(res, source_text) {
  # structural + content checks on one returned object
  v <- list(schema_ok = FALSE, status = NA_character_, status_in_enum = FALSE,
            is_not_stated = NA, evidence_exact = NA, evidence_norm = NA)
  if (is.null(res) || !is.list(res)) return(v)
  st <- res[["smoking_status"]]; ev <- res[["evidence"]]
  v$schema_ok <- is.character(st) && length(st) == 1 &&
                 (is.null(ev) || is.character(ev))
  if (!isTRUE(v$schema_ok)) return(v)
  v$status         <- st
  v$status_in_enum <- st %in% ENUM
  v$is_not_stated  <- identical(st, "not_stated")
  ev <- if (is.null(ev)) "" else ev
  if (!v$is_not_stated && nzchar(trimws(ev))) {
    v$evidence_exact <- grepl(ev, source_text, fixed = TRUE)
    v$evidence_norm  <- grepl(norm(ev), norm(source_text), fixed = TRUE)
  }
  v
}

# ---- load + sample (stratified by length so long rows stress num_ctx) -------
d <- readRDS(POOL)
d$.row_id <- seq_len(nrow(d))
set.seed(SEED)
len  <- nchar(d$text_tabac_llm)
tert <- cut(len, breaks = quantile(len, c(0, 1/3, 2/3, 1), na.rm = TRUE),
            include.lowest = TRUE, labels = c("short", "mid", "long"))
per  <- max(1L, N %/% 3L)
idx  <- unlist(lapply(split(d$.row_id, tert), function(ids) sample(ids, min(per, length(ids)))))
idx  <- head(idx, N)
samp <- d[idx, ]

cat(sprintf("Phase 0 smoke test | pool=%d rows | sample=%d | num_ctx=%d | seed=%d\n",
            nrow(d), nrow(samp), NUM_CTX, SEED))
cat(sprintf("schema=%s prompt=%s | models: %s\n\n",
            SCHEMA_VERSION, PROMPT_VERSION, paste(MODELS, collapse = ", ")))

# ---- type from the JSON-Schema spec (the ratified mechanism) -----------------
type <- tryCatch(ellmer::type_from_schema(text = SCHEMA_JSON),
                 error = function(e) {
                   cat("FATAL: type_from_schema() rejected the spec:\n  ", conditionMessage(e), "\n")
                   quit(status = 1)
                 })
cat("type_from_schema(): OK (JSON-Schema spec accepted)\n\n")

rows     <- list()   # full per-row detail  -> outputs/ only (contains PHI)
attempts <- list()   # minimal attempt log  -> outputs/

for (model in MODELS) {
  chat <- tryCatch(make_chat(model), error = function(e) NULL)
  if (is.null(chat)) { cat(sprintf("[%s] could not init chat - skipped\n", model)); next }

  for (i in seq_len(nrow(samp))) {
    r   <- samp[i, ]
    out <- run_one(chat, type, r$text_tabac_llm)
    v   <- if (identical(out$status, "ok")) validate(out$res, r$text_tabac_llm)
           else validate(NULL, r$text_tabac_llm)

    aid <- sprintf("%s#%03d", model, i)
    attempts[[length(attempts) + 1]] <- data.frame(
      attempt_id = aid, ts = format(Sys.time(), "%Y-%m-%dT%H:%M:%S"),
      model = model, schema_version = SCHEMA_VERSION, prompt_version = PROMPT_VERSION,
      row_id = r$.row_id, status = out$status,
      latency_ms = round(out$latency_ms), error = out$error,
      stringsAsFactors = FALSE
    )
    rows[[length(rows) + 1]] <- data.frame(
      attempt_id = aid, model = model, row_id = r$.row_id, role = r$role,
      n_chars = nchar(r$text_tabac_llm), call_status = out$status,
      schema_ok = v$schema_ok, status = v$status, status_in_enum = v$status_in_enum,
      is_not_stated = v$is_not_stated, evidence_exact = v$evidence_exact,
      evidence_norm = v$evidence_norm, latency_ms = round(out$latency_ms),
      evidence = if (identical(out$status, "ok") && is.list(out$res))
                   (if (is.null(out$res[["evidence"]])) "" else out$res[["evidence"]]) else NA_character_,
      source_text = r$text_tabac_llm,   # full note text, for debugging FALSE evidence matches
      stringsAsFactors = FALSE
    )
  }
}

res_df <- do.call(rbind, rows)
att_df <- do.call(rbind, attempts)
stamp  <- format(Sys.time(), "%Y%m%d_%H%M%S")
# Per-row detail as .xlsx: holds full UTF-8 clinical text + evidence for review,
# with NO csv encoding trap (Excel reads a BOM-less UTF-8 csv as Windows-1252 ->
# mojibake). Sort/filter on evidence_exact == FALSE to debug against source_text.
writexl::write_xlsx(res_df, file.path(OUT_DIR, sprintf("smoke_rows_%s.xlsx", stamp)))
# Attempt log as UTF-8 + BOM csv (write_excel_csv) so Excel detects the encoding.
readr::write_excel_csv(att_df, file.path(OUT_DIR, sprintf("smoke_attempts_%s.csv", stamp)))

# ---- aggregate report (SAFE: counts/rates only, no PHI) ---------------------
pct <- function(x) sprintf("%.0f%%", 100 * mean(x, na.rm = TRUE))
cat("================ CONTRACT REPORT (aggregates only) ================\n")
for (model in unique(res_df$model)) {
  m <- res_df[res_df$model == model, ]
  n <- nrow(m); ok <- m$call_status == "ok"
  cat(sprintf("\n[%s]  n=%d\n", model, n))
  cat(sprintf("  1. call ok ............... %d/%d (%s)\n", sum(ok), n, pct(ok)))
  cat(sprintf("  2. schema valid ......... %d/%d (%s)\n", sum(m$schema_ok, na.rm = TRUE), n, pct(m$schema_ok)))
  cat(sprintf("     status in enum ....... %s\n", pct(m$status_in_enum)))
  enum_tab <- table(factor(m$status, levels = ENUM))
  cat("  3. status distribution ... "); cat(paste(sprintf("%s=%d", names(enum_tab), enum_tab), collapse = "  "), "\n")
  ndecided <- m[!is.na(m$evidence_exact), ]
  cat(sprintf("  4. evidence substring .... exact %s | normalized %s  (of %d decided rows)\n",
              pct(ndecided$evidence_exact), pct(ndecided$evidence_norm), nrow(ndecided)))
  cat(sprintf("  5. failures captured ..... %d\n", sum(!ok)))
  lat <- m$latency_ms[ok]
  if (length(lat)) cat(sprintf("     latency ms (med/max) . %d / %d\n", round(median(lat)), max(lat)))
}
cat(sprintf("\nWrote per-row detail + attempt log to %s/ (gitignored).\n", OUT_DIR))
cat("===================================================================\n")
