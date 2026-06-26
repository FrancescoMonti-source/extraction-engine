# Run from the repository root: Rscript tests/testthat.R
# Sources the engine + adapters + type library, then runs the contract tests.
# No provider, no patient data.
suppressWarnings(suppressMessages(library(testthat)))

source("R/retrieval.R")
source("R/extract.R")
source("R/data.R")
source("R/structured.R")
source("R/channel-combine.R")
source("R/spec.R")
source("R/channels.R")
source("R/operators.R")
source("R/hitset.R")
source("R/run_variable.R")
source("R/concepts-diabetes.R")
source("R/concepts-hyperkalaemia.R")
source("R/concepts-smoking.R")
source("R/concepts-anastomoses.R")
source("R/concepts-dialysis.R")
source("R/adapter_anastomoses.R")
source("R/adapter_smoking.R")
source("R/types/anastomoses.R")
source("R/types/smoking.R")

testthat::test_dir("tests/testthat", stop_on_failure = TRUE)
