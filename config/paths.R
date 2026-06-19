# Single source of truth for where data lives.
# ALL data (sensitive and reference) lives OUTSIDE this repo and is NEVER committed.
# Override per machine with the DATASETS_DIR environment variable if the path differs.

DATASETS <- Sys.getenv("DATASETS_DIR", "C:/Users/franc/Documents/Datasets")

path_data <- function(...) file.path(DATASETS, ...)

# examples:
#   path_data("D0740 - dmo nutrition", "docs_merged_00_25")   # sensitive (PHI)
#   path_data("ref", "ref_cim10.txt")                          # reference terminology
#   path_data("PARTAGE", "parhaf_train.parquet")               # non-sensitive
