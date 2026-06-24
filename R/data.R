# =============================================================================
# data.R — D0840 project data loaders (glue, not engine)
# -----------------------------------------------------------------------------
# This is the SOURCE LAYER: the only place raw warehouse column names appear.
# Each source is a DECLARATION (`source_spec`) mapping raw columns -> canonical
# ROLES (subject / event / date / interval / value / analyte / code / text / …);
# one generic `normalize_source()` applies the shared normalization (Europe/Paris
# clinical dates, numeric coercion, source-row ids, presence/uniqueness checks).
# A new warehouse re-declares only these specs; nothing else should mention a raw
# column name. (Output column names are still the historical ones for now; the
# rename of downstream code to *speak* roles is a separate step.)
# Privacy: identifier-bearing workbooks are read column-by-column (see
# read_workbook_columns); the docs RDS carries no direct identifiers.
# =============================================================================

suppressWarnings(suppressMessages({
    library(dplyr)
    stopifnot(requireNamespace("openxlsx", quietly = TRUE))
}))

# EDSAN timestamps use the hospital's local timezone. Date conversion must retain
# that clinical calendar day rather than derive a UTC date near local midnight.
WAREHOUSE_TZ <- "Europe/Paris"

clean_mixed_date <- function(x) {
    if (inherits(x, "Date")) return(x)
    if (inherits(x, "POSIXt")) return(as.Date(x, tz = WAREHOUSE_TZ))
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

# --- declared source layer ---------------------------------------------------
# `col()` declares one output column: which raw column it comes from (`from`,
# a fallback vector is allowed), how to normalize it (`kind`), and which canonical
# engine ROLE it plays (`role`, metadata for later use — not consumed here yet).
col <- function(from, kind = c("chr", "num", "date"), role = NA_character_) {
    list(from = from, kind = match.arg(kind), role = role)
}

# A source spec: the per-source raw->role mapping plus normalization options.
source_spec <- function(name, cols, source_row_id = NULL, unique_cols = NULL) {
    list(name = name, cols = cols, source_row_id = source_row_id,
         unique_cols = unique_cols)
}

source_row_ids <- function(source, n) {
    sprintf("%s:%08d", source, seq_len(n))
}

.source_pick <- function(raw, candidates) {
    hit <- intersect(candidates, names(raw))      # candidates' order wins (fallback)
    if (length(hit)) raw[[hit[[1]]]] else NULL
}

# Generic loader body: project + normalize a raw frame per its source_spec.
normalize_source <- function(raw, spec) {
    if (!is.data.frame(raw)) {
        stop(spec$name, ": expected a data frame.", call. = FALSE)
    }
    picked  <- lapply(spec$cols, function(cc) .source_pick(raw, cc$from))
    missing <- vapply(picked, is.null, logical(1))
    if (any(missing)) {
        want <- vapply(spec$cols[missing],
                       function(cc) paste(cc$from, collapse = "/"), character(1))
        stop(spec$name, ": missing columns: ", paste(want, collapse = ", "),
             call. = FALSE)
    }
    out <- Map(function(cc, v) switch(cc$kind,
                   chr  = as.character(v),
                   num  = suppressWarnings(as.numeric(as.character(v))),
                   date = clean_mixed_date(v)),
               spec$cols, picked)
    out <- tibble::as_tibble(out)
    if (!is.null(spec$source_row_id)) {
        out <- tibble::add_column(out,
            source_row_id = source_row_ids(spec$source_row_id, nrow(out)), .before = 1L)
    }
    for (u in spec$unique_cols) {
        v <- out[[u]]
        if (anyNA(v) || any(!nzchar(v))) {
            stop(spec$name, ": ", u, " must be non-missing.", call. = FALSE)
        }
        if (anyDuplicated(v)) {
            stop(spec$name, ": ", u, " must be unique.", call. = FALSE)
        }
    }
    out
}

# Document index used by adapters to resolve task<->document eligibility.
# All documents (incl. empty ones); the corpus membership flag in retrieval()
# separates eligible from searchable. No direct identifiers here; text lives in
# the corpus (RECTXT), not the index.
DOCS_SOURCE <- source_spec("docs index",
    cols = list(
        ELTID   = col("ELTID",   "chr",  role = "record"),
        PATID   = col("PATID",   "chr",  role = "subject"),
        EVTID   = col("EVTID",   "chr",  role = "event"),
        RECDATE = col("RECDATE", "date", role = "date"),
        RECTYPE = col("RECTYPE", "chr",  role = "type")),
    unique_cols = "ELTID")

load_docs_index <- function(docs_path) {
    normalize_source(readRDS(docs_path), DOCS_SOURCE)
}

# pmsi$diag: one row per ICD-10 diagnosis, attached to the parent stay interval.
DIAG_SOURCE <- source_spec("pmsi diag",
    cols = list(
        PATID   = col("PATID",   "chr",  role = "subject"),
        EVTID   = col("EVTID",   "chr",  role = "event"),
        ELTID   = col("ELTID",   "chr",  role = "record"),
        diag    = col("diag",    "chr",  role = "code"),
        DATENT  = col("DATENT",  "date", role = "interval_start"),
        DATSORT = col("DATSORT", "date", role = "interval_end")),
    source_row_id = "pmsi_diag")

load_pmsi_diag <- function(pmsi_path) {
    x <- readRDS(pmsi_path)
    normalize_source(if (is.data.frame(x)) x else x$diag, DIAG_SOURCE)
}

# All biology results. Serum/plasma potassium is TYPEANA "K.K"; its unit is fixed
# by organisational convention, so UNITE is intentionally not read. `value` is the
# numeric result; `value_raw` keeps the original string for audit.
BIOL_SOURCE <- source_spec("biol results",
    cols = list(
        PATID     = col("PATID",                 "chr",  role = "subject"),
        EVTID     = col("EVTID",                 "chr",  role = "event"),
        ELTID     = col("ELTID",                 "chr",  role = "record"),
        BIOL_ID   = col(c("biol_ID", "BIOL_ID"), "chr",  role = "record_aux"),
        DATEXAM   = col("DATEXAM",               "date", role = "date"),
        analyte   = col("TYPEANA",               "chr",  role = "analyte"),
        value_raw = col("NUMRES",                "chr",  role = "value_raw"),
        value     = col("NUMRES",                "num",  role = "value")),
    source_row_id = "biol")

load_biol_results <- function(bio_path) {
    normalize_source(readRDS(bio_path), BIOL_SOURCE)
}

# NB: pmsi$main and pmsi$actes are real redsan tables but have no loader/consumer
# yet (the surgery anchor currently comes from the chirurgie workbook via the
# adapters). Declare their source_spec when a variable actually consumes them.
