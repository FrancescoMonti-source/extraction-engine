# Run from the repository root: Rscript tests/testthat.R
# Sources the engine + adapters, then runs the contract tests. No provider, no data.
suppressWarnings(suppressMessages(library(testthat)))

source("R/retrieval.R")
source("R/extract.R")
source("R/adapter_anastomoses.R")
source("R/types/anastomoses.R")

testthat::test_dir("tests/testthat", stop_on_failure = TRUE)
