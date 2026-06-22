# Run from the repository root: Rscript tests/testthat.R
# Sources the engine + adapters + type library, then runs the contract tests.
# No provider, no patient data.
suppressWarnings(suppressMessages(library(testthat)))

source("R/retrieval.R")
source("R/extract.R")
source("R/data.R")
source("R/structured.R")
source("R/adapter_anastomoses.R")
source("R/adapter_smoking.R")
source("R/types/anastomoses.R")
source("R/types/smoking.R")

testthat::test_dir("tests/testthat", stop_on_failure = TRUE)
