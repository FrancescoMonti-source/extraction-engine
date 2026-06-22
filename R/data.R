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

# Models that have passed scripts/check_grammar_enforcement.R (grammar-constrained
# output is the premise of runtime validation). Extraction must refuse ungated
# models unless explicitly overridden, since reasoning models fail open to prose.
APPROVED_MODELS <- c("gemma3:4b")

require_gated_model <- function(model) {
    if (!model %in% APPROVED_MODELS && !nzchar(Sys.getenv("ALLOW_UNGATED_MODEL"))) {
        stop(sprintf(
            "Model '%s' has not passed the grammar gate (scripts/check_grammar_enforcement.R). Approved: %s. Set ALLOW_UNGATED_MODEL=1 to override.",
            model, paste(APPROVED_MODELS, collapse = ", ")), call. = FALSE)
    }
    invisible(model)
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

# --- structured sources (already process_*()-ed RDS) -------------------------
# redsan parses these dates to POSIXct in the warehouse tz; take the LOCAL
# calendar date (tz = Europe/Paris) so an evening timestamp is not pushed to the
# previous UTC day -- the timezone regression to avoid.
WAREHOUSE_TZ <- "Europe/Paris"

local_clinical_date <- function(x) {
    if (inherits(x, "Date")) return(x)
    if (inherits(x, "POSIXt")) return(as.Date(x, tz = WAREHOUSE_TZ))
    as.Date(x)
}

source_row_ids <- function(source, n) {
    sprintf("%s:%08d", source, seq_len(n))
}

require_source_columns <- function(x, columns, source) {
    missing <- setdiff(columns, names(x))
    if (length(missing)) {
        stop(source, ": missing columns: ", paste(missing, collapse = ", "),
             call. = FALSE)
    }
    invisible(x)
}

# pmsi$diag: one row per ICD-10 diagnosis, attached to the parent stay interval.
load_pmsi_diag <- function(pmsi_path) {
    x <- readRDS(pmsi_path)
    d <- if (is.data.frame(x)) x else x$diag
    if (!is.data.frame(d)) {
        stop("pmsi diag: expected a data frame or an object with $diag.", call. = FALSE)
    }
    require_source_columns(
        d, c("PATID", "EVTID", "ELTID", "diag", "DATENT", "DATSORT"), "pmsi diag")
    tibble::tibble(
        source_row_id = source_row_ids("pmsi_diag", nrow(d)),
        PATID   = d$PATID,
        EVTID   = d$EVTID,
        ELTID   = d$ELTID,
        diag    = d$diag,
        DATENT  = local_clinical_date(d$DATENT),
        DATSORT = local_clinical_date(d$DATSORT))
}

# All biology results. Serum/plasma potassium is TYPEANA "K.K"; its unit is
# fixed by organisational convention, so UNITE is intentionally not read.
load_biol_results <- function(bio_path) {
    d <- readRDS(bio_path)
    if (!is.data.frame(d)) {
        stop("biol results: expected a data frame.", call. = FALSE)
    }
    require_source_columns(
        d, c("PATID", "EVTID", "ELTID", "DATEXAM", "TYPEANA", "NUMRES"),
        "biol results")
    biol_id <- if ("biol_ID" %in% names(d)) {
        d$biol_ID
    } else if ("BIOL_ID" %in% names(d)) {
        d$BIOL_ID
    } else {
        stop("biol results: missing column biol_ID.", call. = FALSE)
    }
    tibble::tibble(
        source_row_id = source_row_ids("biol", nrow(d)),
        PATID   = d$PATID,
        EVTID   = d$EVTID,
        ELTID   = d$ELTID,
        BIOL_ID = biol_id,
        DATEXAM = local_clinical_date(d$DATEXAM),
        analyte = d$TYPEANA,
        value_raw = d$NUMRES,
        value = suppressWarnings(as.numeric(as.character(d$NUMRES))))
}
