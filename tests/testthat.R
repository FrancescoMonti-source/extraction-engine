library(testthat)
library(extractionengine)

test_files <- list.files(
  "testthat",
  pattern = "^test.*\\.[Rr]$",
  full.names = TRUE
)

if (length(test_files)) {
  test_check("extractionengine")
}
