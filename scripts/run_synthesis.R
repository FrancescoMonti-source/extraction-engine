#!/usr/bin/env Rscript
# Integrated baseline runner. One parameterized entry point for every variable.
#   $env:SYNTHESIS_TASK = "smoking" | "anastomoses"
# Retrieval covers the full task set (so coverage is measurable); the model is
# called only on a small representative sample. Outputs go to an IMMUTABLE,
# timestamped run directory so a rerun never overwrites prior review work.
# Console prints aggregates only; PHI -> gitignored outputs/.
source("config/paths.R")
source("R/data.R")
source("R/retrieval.R")
source("R/extract.R")
source("R/adapter_smoking.R")
source("R/adapter_anastomoses.R")
source("R/types/smoking.R")
source("R/types/anastomoses.R")

TASK  <- Sys.getenv("SYNTHESIS_TASK", "smoking")
MODEL <- Sys.getenv("OLLAMA_MODEL", "gemma3:4b")
N     <- as.integer(Sys.getenv("SYNTHESIS_N", "5"))
require_gated_model(MODEL)  # refuse ungated models unless ALLOW_UNGATED_MODEL=1

docs_index <- load_docs_index(path_data("D0840", "docs"))
chir       <- path_data("D0840", "chirurgie.xlsx")
if (identical(TASK, "smoking")) {
    tasks <- smoking_load_tasks(chir); eligibility <- smoking_eligibility(tasks, docs_index)
    query <- SMOKING_QUERY; definition <- smoking_definition()
} else if (identical(TASK, "anastomoses")) {
    tasks <- anastomoses_load_tasks(chir); eligibility <- anastomoses_eligibility(tasks, docs_index)
    query <- ANASTOMOSES_QUERY; definition <- anastomoses_definition()
} else {
    stop("SYNTHESIS_TASK must be 'smoking' or 'anastomoses'.", call. = FALSE)
}

corpus <- readRDS(corpus_path())
r <- retrieve(corpus, tasks, eligibility, query, neighbours = 1L, as_ascii = TRUE)
rm(corpus)

SEED <- 20260621L
run <- run_extraction(r$coverage, r$candidates, definition,
                      make_ollama_caller(MODEL, SEED), MODEL,
                      provider = "ollama", seed = SEED, query = query, sample_n = N)
review <- build_review_view(run$values, run$evidence)

stamp <- format(Sys.time(), "%Y%m%d_%H%M%S")
run_id <- paste0(stamp, "_", Sys.getpid())                 # pid avoids same-second collision
out_dir <- file.path("outputs", "integrated", TASK, run_id)
if (dir.exists(out_dir)) stop("run directory already exists: ", out_dir, call. = FALSE)
dir.create(out_dir, recursive = TRUE, showWarnings = TRUE) # immutable per run
saveRDS(run, file.path(out_dir, "run.rds"))

flatten <- function(df) {
    for (c in names(df)) if (is.list(df[[c]])) {
        df[[c]] <- vapply(df[[c]], function(x) paste(unlist(x), collapse = ";"), character(1))
    }
    df
}
openxlsx::write.xlsx(
    list(physician_review = review, coverage = run$coverage,
         values = flatten(run$values), evidence = run$evidence,
         attempts = dplyr::select(run$attempts, -dplyr::any_of("raw_response")),
         candidates = flatten(run$candidates)),
    file.path(out_dir, "review.xlsx"), asTable = TRUE, overwrite = FALSE)

cat(sprintf("========== INTEGRATED BASELINE: %s (model=%s) ==========\n", TASK, MODEL))
cat(sprintf("tasks=%d | called=%d | out=%s\n", nrow(tasks), nrow(run$attempts), out_dir))
cat("coverage processing_state:\n"); print(dplyr::count(run$coverage, processing_state))
if (nrow(run$attempts)) {
    ok <- run$attempts$attempt_status == "completed"
    cat(sprintf("calls ok=%d error=%d | processing_error=%d\n", sum(ok), sum(!ok),
                sum(run$attempts$processing_status %in% "processing_error")))
    if (any(ok)) cat(sprintf("latency ms median/max=%d/%d\n",
                as.integer(median(run$attempts$latency_ms[ok])), max(run$attempts$latency_ms[ok])))
}
if (nrow(run$values)) {
    cat("field validity:\n"); print(dplyr::count(run$values, field, field_validity))
}
cat(sprintf("evidence rows=%d | review rows=%d\n", nrow(run$evidence), nrow(review)))
cat("=========================================================\n")
