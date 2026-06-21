# =============================================================================
# data.R — D0840 project data loaders (glue, not engine)
# Privacy: workbooks with direct identifiers are read column-by-column so the
# identifier columns are never loaded. The docs RDS carries no direct identifiers
# (ELTID/PATID/EVTID/RECDATE/RECTYPE/text), so it is read then projected.
# =============================================================================

suppressWarnings(suppressMessages({
    library(dplyr)
    stopifnot(requireNamespace("openxlsx", quietly = TRUE))
}))

clean_mixed_date <- function(x) {
    if (inherits(x, "Date")) return(x)
    if (inherits(x, "POSIXt")) return(as.Date(x))
    x <- trimws(as.character(x))
    out <- rep(as.Date(NA), length(x))
    is_num <- grepl("^\\d+(\\.\\d+)?$", x)
    out[is_num] <- as.Date(as.numeric(x[is_num]), origin = "1899-12-30")
    is_txt <- !is_num & nzchar(x)
    out[is_txt] <- as.Date(substr(x[is_txt], 1, 10))
    out
}

# Path to the persisted canonical corpus: shared dataset dir, else round-3 output.
corpus_path <- function() {
    shared <- path_data("D0840", "canonical_tcorpus.rds")
    localc <- file.path("outputs", "round3-experiments", "canonical_tcorpus.rds")
    if (file.exists(shared)) shared else localc
}

# Document index used by adapters to resolve task<->document eligibility.
# All documents (incl. empty ones); the corpus membership flag in retrieval()
# separates eligible from searchable. No direct identifiers here.
load_docs_index <- function(docs_path) {
    d <- readRDS(docs_path)
    idx <- tibble::tibble(
        ELTID   = as.character(d$ELTID),
        PATID   = as.character(d$PATID),
        EVTID   = as.character(d$EVTID),
        RECDATE = clean_mixed_date(d$RECDATE),
        RECTYPE = as.character(d$RECTYPE)
    )
    if (anyNA(idx$ELTID) || any(idx$ELTID == "")) {
        stop("docs index: ELTID must be non-missing.", call. = FALSE)
    }
    if (anyDuplicated(idx$ELTID)) {
        stop("docs index: ELTID must be unique.", call. = FALSE)
    }
    idx
}

# Read only the named columns from an identifier-bearing workbook, by locating
# them in the header first (never loads other columns into memory).
read_workbook_columns <- function(path, columns) {
    header <- openxlsx::read.xlsx(path, rows = 1, colNames = TRUE)
    idx <- match(columns, names(header))
    if (anyNA(idx)) {
        stop("Missing workbook columns: ",
             paste(columns[is.na(idx)], collapse = ", "), call. = FALSE)
    }
    openxlsx::read.xlsx(path, cols = idx, colNames = TRUE)
}
