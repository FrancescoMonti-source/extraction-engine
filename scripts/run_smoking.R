#!/usr/bin/env Rscript
# End-to-end peri-operative smoking on the synthesis baseline (date-window scope).
# Console prints aggregates only; PHI -> gitignored outputs/.
source("config/paths.R")
source("R/data.R")
source("R/retrieval.R")
source("R/extract.R")
source("R/adapter_smoking.R")
source("R/types/smoking.R")

OUT_DIR <- file.path("outputs", "synthesis-smoking")
dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)
MODEL   <- Sys.getenv("OLLAMA_MODEL", "gemma3:4b")
N       <- as.integer(Sys.getenv("SMOKING_N", "5"))

docs_index  <- load_docs_index(path_data("D0840", "docs"))
tasks       <- smoking_load_tasks(path_data("D0840", "chirurgie.xlsx"))
eligibility <- smoking_eligibility(tasks, docs_index)
corpus      <- readRDS(corpus_path())

r <- retrieve(corpus, tasks, eligibility, SMOKING_QUERY, neighbours = 1L, as_ascii = TRUE)
rm(corpus)

run <- run_extraction(
    r$coverage, r$candidates,
    make_ollama_caller(MODEL, SMOKING_SYSTEM_PROMPT),
    model_name = MODEL,
    type_builder = type_smoking,
    prompt_builder = prompt_smoking,
    parse_result = parse_smoking,
    sample_n = N
)

# Physician review view: one row per task (single clinical field).
review <- tibble::tibble()
if (nrow(run$values)) {
    review <- do.call(dplyr::bind_rows, lapply(seq_len(nrow(run$values)), function(i) {
        v <- run$values[i, ]
        fev <- run$evidence[run$evidence$task_id == v$task_id, ]
        tibble::tibble(
            task_id = v$task_id, field = "smoking_status",
            value = v$smoking_status, decision_note = v$decision_note,
            task_valid = v$task_valid, task_reason = v$task_reason,
            cited_snippet_ids = paste(fev$snippet_id, collapse = ";"),
            evidence_text = paste(sprintf("[%s] %s", fev$snippet_id, fev$snippet_text), collapse = "\n\n"),
            review_decision = "", review_note = ""
        )
    }))
}

stamp <- format(Sys.time(), "%Y%m%d_%H%M%S")
saveRDS(run, file.path(OUT_DIR, "run.rds"))
openxlsx::write.xlsx(
    list(physician_review = review, coverage = run$coverage,
         values = run$values, evidence = run$evidence, attempts = run$attempts),
    file.path(OUT_DIR, sprintf("smoking_%s.xlsx", stamp)), overwrite = TRUE
)

cs <- run$coverage
cat("============ SMOKING (synthesis baseline, window scope) ============\n")
cat(sprintf("tasks=%d | candidate-bearing=%d | model=%s | called=%d\n",
            nrow(tasks), sum(cs$coverage_state == "candidate"), MODEL, nrow(run$attempts)))
cat("coverage processing_state:\n"); print(dplyr::count(cs, processing_state))
if (nrow(run$attempts)) {
    ok <- run$attempts$attempt_status == "completed"
    cat(sprintf("calls ok=%d error=%d | valid=%d | latency ms median/max=%d/%d\n",
                sum(ok), sum(!ok), sum(run$attempts$task_valid %in% TRUE),
                as.integer(median(run$attempts$latency_ms[ok])), max(run$attempts$latency_ms[ok])))
}
if (nrow(run$values)) { cat("smoking_status:\n"); print(dplyr::count(run$values, smoking_status)) }
cat(sprintf("evidence rows=%d | review rows=%d\n", nrow(run$evidence), nrow(review)))
cat("====================================================================\n")
