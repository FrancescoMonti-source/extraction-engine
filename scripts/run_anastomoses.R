#!/usr/bin/env Rscript
# End-to-end recipient anastomoses on the synthesis baseline: retrieval +
# structured extraction. Console prints aggregates only; PHI -> gitignored outputs/.
source("config/paths.R")
source("R/data.R")
source("R/retrieval.R")
source("R/extract.R")
source("R/adapter_anastomoses.R")
source("R/types/anastomoses.R")

OUT_DIR <- file.path("outputs", "synthesis-anastomoses")
dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)
MODEL   <- Sys.getenv("OLLAMA_MODEL", "gemma3:4b")
N       <- as.integer(Sys.getenv("ANASTOMOSES_N", "5"))

docs_index  <- load_docs_index(path_data("D0840", "docs"))
tasks       <- anastomoses_load_tasks(path_data("D0840", "chirurgie.xlsx"))
eligibility <- anastomoses_eligibility(tasks, docs_index)
corpus      <- readRDS(corpus_path())

r <- retrieve(corpus, tasks, eligibility, ANASTOMOSES_QUERY, neighbours = 1L, as_ascii = TRUE)
rm(corpus)

run <- run_extraction(
    r$coverage, r$candidates,
    make_ollama_caller(MODEL, ANASTOMOSES_SYSTEM_PROMPT),
    model_name = MODEL,
    type_builder = type_anastomoses,
    prompt_builder = prompt_anastomoses,
    parse_result = parse_anastomoses,
    sample_n = N
)

# Physician review view: one row per task x clinical field (incl. summary).
fields_all <- c(names(ANASTOMOSES_FIELDS), ANASTOMOSES_SUMMARY)
review <- list()
if (nrow(run$values)) for (i in seq_len(nrow(run$values))) {
    v <- run$values[i, ]
    for (f in fields_all) {
        fev <- run$evidence[run$evidence$task_id == v$task_id & run$evidence$field == f, ]
        review[[length(review) + 1L]] <- tibble::tibble(
            task_id = v$task_id, field = f,
            value = if (f == ANASTOMOSES_SUMMARY) v[[ANASTOMOSES_SUMMARY]] else as.character(v[[f]]),
            status = if (f == ANASTOMOSES_SUMMARY) NA_character_ else v[[paste0(f, "_status")]],
            summary = v[[ANASTOMOSES_SUMMARY]],
            task_valid = v$task_valid, task_reason = v$task_reason,
            cited_snippet_ids = paste(fev$snippet_id, collapse = ";"),
            evidence_text = paste(sprintf("[%s] %s", fev$snippet_id, fev$snippet_text), collapse = "\n\n"),
            review_decision = "", review_note = ""
        )
    }
}
review <- if (length(review)) dplyr::bind_rows(review) else tibble::tibble()

stamp <- format(Sys.time(), "%Y%m%d_%H%M%S")
saveRDS(run, file.path(OUT_DIR, "run.rds"))
flatten <- function(df) { for (c in names(df)) if (is.list(df[[c]])) df[[c]] <- vapply(df[[c]], function(x) paste(unlist(x), collapse = ";"), character(1)); df }
openxlsx::write.xlsx(
    list(physician_review = review, coverage = run$coverage,
         values = flatten(run$values), evidence = run$evidence, attempts = run$attempts),
    file.path(OUT_DIR, sprintf("anastomoses_%s.xlsx", stamp)), overwrite = TRUE
)

# ---- report (counts only) ----
cs <- run$coverage
cat("============ ANASTOMOSES (synthesis baseline) ============\n")
cat(sprintf("model=%s | called=%d\n", MODEL, sum(run$attempts$attempt_status != "")))
cat("coverage processing_state:\n"); print(dplyr::count(cs, processing_state))
if (nrow(run$attempts)) {
    ok <- run$attempts$attempt_status == "completed"
    cat(sprintf("calls ok=%d error=%d | valid=%d | latency ms median/max=%d/%d\n",
                sum(ok), sum(!ok), sum(run$attempts$task_valid %in% TRUE),
                as.integer(median(run$attempts$latency_ms[ok])), max(run$attempts$latency_ms[ok])))
}
if (nrow(run$values)) for (f in names(ANASTOMOSES_FIELDS)) {
    st <- run$values[[paste0(f, "_status")]]
    cat(sprintf("  %-38s doc=%d not_doc=%d unusable=%d\n", f,
                sum(st == "documented", na.rm = TRUE), sum(st == "not_documented", na.rm = TRUE),
                sum(st == "unusable", na.rm = TRUE)))
}
cat(sprintf("evidence rows=%d | review rows=%d\n", nrow(run$evidence), nrow(review)))
cat("==========================================================\n")
