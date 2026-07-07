# =============================================================================
# data.R — D0840 project data loaders (glue, not engine)
# -----------------------------------------------------------------------------
# This is the SOURCE LAYER: the only place raw warehouse column names appear.
# Each source is a DECLARATION (`source_spec`) mapping raw columns -> canonical
# roles (subject_id / event_id / source_item_id / point_date / event_start /
# event_end / value_num / value_str / analyte / code / text / ...); one generic
# `normalize_source()` applies the shared normalization (Europe/Paris clinical
# dates, numeric coercion, source-row ids, presence/uniqueness checks). A new
# warehouse re-declares only these specs; nothing else should mention a raw column
# name. Output column names are still the historical runner names for now; the
# target role vocabulary is exposed through source metadata.
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
# `col()` declares one output column: which raw column it comes from (`from`, a
# fallback vector is allowed), how to normalize it (`kind`), and which canonical
# engine role(s) it plays.
col <- function(from, kind = c("chr", "num", "date"), role = NULL,
                roles = NULL) {
    if (is.null(roles)) roles <- role
    roles <- as.character(roles %||% character())
    roles <- roles[!is.na(roles) & nzchar(roles)]
    structure(
        list(
            from = from,
            kind = match.arg(kind),
            role = if (length(roles)) roles[[1]] else NA_character_,
            roles = roles),
        class = c("ee_source_col", "list"),
        api_status = "experimental")
}

# A source spec: the per-source raw->role mapping plus normalization options.
source_spec <- function(name, cols, source_row_id = NULL, unique_cols = NULL,
                        module = NULL, table = NULL, identifiers = character(),
                        source_time_kind = NULL, source_time_start = NULL,
                        source_time_end = NULL, query_date_keys = character(),
                        default_batch_key = NULL, normalizer = NULL) {
    structure(
        list(
            name = name,
            module = .nullable_chr(module),
            table = .nullable_chr(table),
            identifiers = as.character(identifiers %||% character()),
            source_time_kind = .nullable_chr(source_time_kind),
            source_time_start = .nullable_chr(source_time_start),
            source_time_end = .nullable_chr(source_time_end),
            query_date_keys = as.character(query_date_keys %||% character()),
            default_batch_key = .nullable_chr(default_batch_key),
            normalizer = .nullable_chr(normalizer),
            cols = cols,
            roles = .source_role_map(cols),
            source_row_id = source_row_id,
            unique_cols = unique_cols),
        class = c("ee_source_spec", "list"),
        api_status = "experimental")
}

source_row_ids <- function(source, n) {
    sprintf("%s:%08d", source, seq_len(n))
}

`%||%` <- function(x, y) {
    if (is.null(x)) y else x
}

.nullable_chr <- function(x) {
    if (is.null(x) || length(x) == 0L || (length(x) == 1L && is.na(x))) {
        return(NULL)
    }
    x <- as.character(x)
    if (length(x) != 1L) stop("Expected a single string.", call. = FALSE)
    x
}

.source_role_map <- function(cols) {
    out <- list()
    for (nm in names(cols)) {
        for (role in cols[[nm]]$roles) {
            out[[role]] <- unique(c(out[[role]], nm))
        }
    }
    out
}

source_roles <- function(spec) {
    if (!inherits(spec, "ee_source_spec")) {
        stop("source_roles() requires a source_spec().", call. = FALSE)
    }
    spec$roles
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
        ELTID   = col("ELTID",   "chr",  roles = "source_item_id"),
        PATID   = col("PATID",   "chr",  roles = "subject_id"),
        EVTID   = col("EVTID",   "chr",  roles = "event_id"),
        RECDATE = col("RECDATE", "date", roles = "point_date"),
        RECTYPE = col("RECTYPE", "chr",  roles = "document_type"),
        # Attribution of the document, always present in the raw docs table
        # (owner, 2026-07-07): SEJUM = unité médicale, SEJUF = unité
        # fonctionnelle. No role: the engine never interprets them --
        # doc_meta(SEJUM = "ANES") names the column directly.
        SEJUM   = col("SEJUM",   "chr"),
        SEJUF   = col("SEJUF",   "chr")),
    unique_cols = "ELTID",
    module = "doceds",
    table = "documents",
    identifiers = c("PATID", "EVTID", "ELTID"),
    source_time_kind = "point",
    source_time_start = "RECDATE",
    query_date_keys = "RECDATE",
    default_batch_key = "RECDATE")

load_docs_index <- function(docs_path) {
    normalize_source(readRDS(docs_path), DOCS_SOURCE)
}

# pmsi$diag: one row per ICD-10 diagnosis, attached to the parent stay interval.
DIAG_SOURCE <- source_spec("pmsi diag",
    cols = list(
        PATID   = col("PATID",   "chr",  roles = "subject_id"),
        EVTID   = col("EVTID",   "chr",  roles = "event_id"),
        ELTID   = col("ELTID",   "chr",  roles = "source_item_id"),
        diag    = col("diag",    "chr",  roles = "code"),
        DATENT  = col("DATENT",  "date", roles = "event_start"),
        DATSORT = col("DATSORT", "date", roles = "event_end")),
    source_row_id = "pmsi_diag",
    module = "pmsi",
    table = "diag",
    identifiers = c("PATID", "EVTID", "ELTID"),
    source_time_kind = "interval",
    source_time_start = "DATENT",
    source_time_end = "DATSORT",
    query_date_keys = c("DATENT", "DATSORT"),
    default_batch_key = "DATENT",
    normalizer = "process_pmsi")

load_pmsi_diag <- function(pmsi_path) {
    x <- readRDS(pmsi_path)
    normalize_source(if (is.data.frame(x)) x else x$diag, DIAG_SOURCE)
}

# All biology results. Serum/plasma potassium is TYPEANA "K.K"; its unit is fixed
# by organisational convention, so UNITE is intentionally not read. `value` is the
# numeric result; `value_raw` keeps the original string for audit.
BIOL_SOURCE <- source_spec("biol results",
    cols = list(
        PATID     = col("PATID",                 "chr",  roles = "subject_id"),
        EVTID     = col("EVTID",                 "chr",  roles = "event_id"),
        ELTID     = col("ELTID",                 "chr",  roles = "source_item_id"),
        BIOL_ID   = col(c("biol_ID", "BIOL_ID"), "chr",  roles = "source_result_id"),
        DATEXAM   = col("DATEXAM",               "date", roles = "point_date"),
        analyte   = col("TYPEANA",               "chr",  roles = "analyte"),
        value_raw = col("NUMRES",                "chr",  roles = "value_str"),
        value     = col("NUMRES",                "num",  roles = "value_num"),
        # Subject attributes carried on every biology row (owner 2026-07-07: PATSEX
        # and PATAGE are always present in the raw HDW table). Role-less: the engine
        # never interprets them -- a subject-context analyte_value(keep_when =) names
        # them directly (sex/age reference ranges). Same pattern as docs SEJUM/SEJUF.
        PATSEX    = col("PATSEX",                 "chr"),
        PATAGE    = col("PATAGE",                 "num")),
    source_row_id = "biol",
    module = "biol",
    table = "results",
    identifiers = c("PATID", "EVTID", "ELTID", "BIOL_ID"),
    source_time_kind = "point",
    source_time_start = "DATEXAM",
    query_date_keys = "DATEXAM",
    default_batch_key = "DATEXAM",
    normalizer = "process_biol")

load_biol_results <- function(bio_path) {
    normalize_source(readRDS(bio_path), BIOL_SOURCE)
}

# pmsi$actes: one row per CCAM procedure act, dated at the act itself (point time).
# Declared now that act_channel() consumes it (CODEACTE membership). Real redsan table;
# add a loader when a real run needs one (tests/run_variable take the frame directly).
ACTE_SOURCE <- source_spec("pmsi actes",
    cols = list(
        PATID    = col("PATID",    "chr",  roles = "subject_id"),
        EVTID    = col("EVTID",    "chr",  roles = "event_id"),
        ELTID    = col("ELTID",    "chr",  roles = "source_item_id"),
        CODEACTE = col("CODEACTE", "chr",  roles = "code"),
        DATEACTE = col("DATEACTE", "date", roles = "point_date")),
    source_row_id = "pmsi_actes",
    module = "pmsi",
    table = "actes",
    identifiers = c("PATID", "EVTID", "ELTID"),
    source_time_kind = "point",
    source_time_start = "DATEACTE",
    query_date_keys = "DATEACTE",
    default_batch_key = "DATEACTE",
    normalizer = "process_pmsi")

# NB: pmsi$main is a real redsan table but has no loader/consumer yet. Declare its
# source_spec when a variable actually consumes it.

# Registry: channel-facing source name -> source_spec, so run_variable() resolves a
# channel's roles (which column is `code`, point vs interval time) from the spec
# instead of hardcoding physical column names in the executor.
EE_SOURCES <- list(
    pmsi_diag  = DIAG_SOURCE,
    pmsi_actes = ACTE_SOURCE,
    biology    = BIOL_SOURCE,
    documents  = DOCS_SOURCE)
