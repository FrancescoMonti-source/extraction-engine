#!/usr/bin/env Rscript
# Real deterministic run of the structured variables (diabetes via pmsi$diag,
# hyperkalaemia via biol) over the recipient-surgery cohort. No corpus, no model.
# Console prints AGGREGATES ONLY; per-task values/evidence (PHI) -> gitignored outputs/.
source("config/paths.R")
source("R/data.R")
source("R/structured.R")
source("R/adapter_anastomoses.R")   # recipient-surgery tasks (task_id, PATID, anchor_date)

tasks <- anastomoses_load_tasks(path_data("D0840", "chirurgie.xlsx"))
diag  <- load_pmsi_diag(path_data("D0840", "pmsi"))
pot   <- load_potassium(path_data("D0840", "bio"))

rdia <- measure_diabetes(diag, tasks)
rhyp <- measure_hyperkalaemia(pot, tasks)

report <- function(name, r) {
    cat(sprintf("\n==== %s ====\n", name))
    cat("coverage processing_state:\n"); print(dplyr::count(r$coverage, processing_state))
    if (nrow(r$values)) { cat("values:\n"); print(dplyr::count(r$values, value)) }
    cat(sprintf("evidence rows=%d\n", nrow(r$evidence)))
}

cat(sprintf("============ STRUCTURED RUN (deterministic) — tasks=%d ============\n", nrow(tasks)))
cat(sprintf("pmsi$diag rows=%d | potassium (K.K) results=%d\n", nrow(diag), nrow(pot)))
report("diabetes (pmsi$diag, ICD-10 E10-E14, 5y lookback)", rdia)
report("hyperkalaemia (biol K.K, > 5.0, +/-7d)", rhyp)

stamp <- format(Sys.time(), "%Y%m%d_%H%M%S")
out_dir <- file.path("outputs", "structured", paste0(stamp, "_", Sys.getpid()))
if (dir.exists(out_dir)) stop("run directory already exists: ", out_dir, call. = FALSE)
dir.create(out_dir, recursive = TRUE, showWarnings = TRUE)
saveRDS(list(diabetes = rdia, hyperkalaemia = rhyp), file.path(out_dir, "structured.rds"))
openxlsx::write.xlsx(
    list(diabetes_coverage = rdia$coverage, diabetes_values = rdia$values,
         diabetes_evidence = rdia$evidence, hyperk_coverage = rhyp$coverage,
         hyperk_values = rhyp$values, hyperk_evidence = rhyp$evidence),
    file.path(out_dir, "structured.xlsx"), overwrite = FALSE)
cat(sprintf("\nWrote artifacts to %s/ (gitignored).\n", out_dir))
cat("==================================================================\n")
