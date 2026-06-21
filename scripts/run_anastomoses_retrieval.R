#!/usr/bin/env Rscript
# Retrieval-only run for recipient anastomoses (verifies the reusable core).
# Console prints aggregates only; candidates (PHI) -> gitignored outputs/.
source("config/paths.R")
source("R/data.R")
source("R/retrieval.R")
source("R/adapter_anastomoses.R")

OUT_DIR <- file.path("outputs", "synthesis-anastomoses")
dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)

docs_index  <- load_docs_index(path_data("D0840", "docs"))
tasks       <- anastomoses_load_tasks(path_data("D0840", "chirurgie.xlsx"))
eligibility <- anastomoses_eligibility(tasks, docs_index)
corpus      <- readRDS(corpus_path())

r <- retrieve(corpus, tasks, eligibility, ANASTOMOSES_QUERY,
              neighbours = 1L, as_ascii = TRUE)

saveRDS(r$candidates, file.path(OUT_DIR, "candidates.rds"))
saveRDS(r$coverage,   file.path(OUT_DIR, "coverage.rds"))

cov <- r$coverage
cand_bearing <- sum(cov$coverage_state == "candidate")
cat("=============== ANASTOMOSES RETRIEVAL (synthesis core) ===============\n")
cat(sprintf("tasks ......................... %d\n", nrow(tasks)))
cat(sprintf("tasks w/ eligible docs ........ %d\n", sum(cov$n_eligible_documents > 0)))
cat(sprintf("candidate-bearing tasks ....... %d\n", cand_bearing))
cat(sprintf("no-candidate tasks ............ %d\n", sum(cov$coverage_state == "no_candidate")))
cat(sprintf("candidate snippets ............ %d\n", nrow(r$candidates)))
cat(sprintf("candidate documents ........... %d\n", dplyr::n_distinct(r$candidates$ELTID)))
if (cand_bearing) {
    per <- cov$n_candidates[cov$coverage_state == "candidate"]
    cat(sprintf("snippets/task (median/max) .... %d / %d\n",
                as.integer(median(per)), max(per)))
}
cat("=====================================================================\n")
