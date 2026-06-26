#!/usr/bin/env Rscript
# Real deterministic run of the structured variables (diabetes via pmsi$diag,
# hyperkalaemia via biol) over the recipient-surgery cohort. No corpus, no model.
# Console prints AGGREGATES ONLY; per-task values/evidence (PHI) -> gitignored outputs/.
source("config/paths.R")
source("R/data.R")
source("R/structured.R")
source("R/concepts-diabetes.R")       # measure_diabetes (clinical caller of the neutral core)
source("R/concepts-hyperkalaemia.R")  # measure_hyperkalaemia (clinical caller of the neutral core)
source("R/adapter_anastomoses.R")   # recipient-surgery tasks (task_id, PATID, anchor_date)

tasks <- anastomoses_load_tasks(path_data("D0840", "chirurgie.xlsx"))
diag  <- load_pmsi_diag(path_data("D0840", "pmsi"))
biol  <- load_biol_results(path_data("D0840", "bio"))

rdia <- run_structured_measurement(
    measure_diabetes, diag, tasks, field = "diabetes_status")
rhyp <- run_structured_measurement(
    measure_hyperkalaemia, biol, tasks, field = "hyperkalaemia")
diabetes_review <- build_structured_review_view(rdia$values, rdia$evidence)
hyperkalaemia_review <- build_structured_review_view(rhyp$values, rhyp$evidence)

report <- function(name, r) {
    cat(sprintf("\n==== %s ====\n", name))
    cat("coverage processing_state:\n")
    print(dplyr::count(r$coverage, processing_state, name = "n_tasks"))
    if (nrow(r$values)) {
        cat("value outcomes:\n")
        print(dplyr::count(
            r$values, normalized_value, accepted_value, field_validity,
            name = "n_tasks"))
    }
    cat(sprintf(
        "observations=%d | evidence=%d | derivations=%d\n",
        nrow(r$observations), nrow(r$evidence), nrow(r$derivation)))
}

cat(sprintf("============ STRUCTURED RUN (deterministic) — tasks=%d ============\n", nrow(tasks)))
cat(sprintf("pmsi$diag rows=%d | biology rows=%d\n", nrow(diag), nrow(biol)))
report("diabetes (pmsi$diag, ICD-10 E10-E14, 5y lookback)", rdia)
report("hyperkalaemia (biol K.K, > 5.0, +/-7d)", rhyp)

stamp <- format(Sys.time(), "%Y%m%d_%H%M%S")
out_dir <- file.path("outputs", "structured", paste0(stamp, "_", Sys.getpid()))
if (dir.exists(out_dir)) stop("run directory already exists: ", out_dir, call. = FALSE)
dir.create(out_dir, recursive = TRUE, showWarnings = TRUE)
saveRDS(
    list(
        diabetes = c(rdia, list(review = diabetes_review)),
        hyperkalaemia = c(rhyp, list(review = hyperkalaemia_review))),
    file.path(out_dir, "structured.rds"))
openxlsx::write.xlsx(
    list(
        diabetes_coverage = rdia$coverage,
        diabetes_values = rdia$values,
        diabetes_evidence = rdia$evidence,
        diabetes_observations = rdia$observations,
        diabetes_derivation = rdia$derivation,
        diabetes_review = diabetes_review,
        hyperk_coverage = rhyp$coverage,
        hyperk_values = rhyp$values,
        hyperk_evidence = rhyp$evidence,
        hyperk_observations = rhyp$observations,
        hyperk_derivation = rhyp$derivation,
        hyperk_review = hyperkalaemia_review),
    file.path(out_dir, "structured.xlsx"), overwrite = FALSE)
cat(sprintf("\nWrote artifacts to %s/ (gitignored).\n", out_dir))
cat("==================================================================\n")
