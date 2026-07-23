# EDSAN source boundary -------------------------------------------------------

`%||%` <- function(x, y) {
    if (is.null(x)) y else x
}

.nullable_chr <- function(x) {
    if (is.null(x) || length(x) == 0L || (length(x) == 1L && is.na(x))) {
        return(NULL)
    }
    x <- as.character(x)
    if (length(x) != 1L || !nzchar(x)) {
        stop("Expected one non-empty string.", call. = FALSE)
    }
    x
}

.source_contract <- function(module, table) {
    if (!is.character(module) || length(module) != 1L || !nzchar(module) ||
        !is.character(table) || length(table) != 1L || !nzchar(table)) {
        stop("source_spec() requires one non-empty module and table.",
             call. = FALSE)
    }
    contract <- redsan::edsan_sources(module, table)
    if (nrow(contract) != 1L) {
        stop("source_spec() must resolve exactly one redsan source contract.",
             call. = FALSE)
    }
    contract
}

.check_role_bindings <- function(roles) {
    if (!is.list(roles) || is.null(names(roles)) || anyNA(names(roles)) ||
        any(!nzchar(names(roles))) || anyDuplicated(names(roles))) {
        stop("source_spec() roles must be a uniquely named list.", call. = FALSE)
    }
    bad <- vapply(roles, function(x) {
        !is.character(x) || length(x) != 1L || is.na(x) || !nzchar(x)
    }, logical(1))
    if (any(bad)) {
        stop("Every source role must bind to one non-empty prepared-view column: ",
             paste(names(roles)[bad], collapse = ", "), ".", call. = FALSE)
    }
    invisible(TRUE)
}

# A source spec binds columns of an already prepared view to engine payload
# roles. Source mechanics come from redsan's live registry; no value coercion or
# warehouse parsing happens here.
source_spec <- function(name, module, table, roles,
                        required_columns = NULL, unique_columns = character()) {
    if (!is.character(name) || length(name) != 1L || !nzchar(name)) {
        stop("source_spec() requires one non-empty name.", call. = FALSE)
    }
    .check_role_bindings(roles)
    contract <- .source_contract(module, table)
    required_columns <- unique(as.character(
        required_columns %||% unlist(roles, use.names = FALSE)))
    unique_columns <- unique(as.character(unique_columns))
    bad_columns <- c(required_columns, unique_columns)
    if (anyNA(bad_columns) || any(!nzchar(bad_columns))) {
        stop("source_spec() column declarations must be non-empty strings.",
             call. = FALSE)
    }

    structure(
        list(
            name = name,
            module = module,
            table = table,
            grain = contract$grain[[1]],
            identifiers = contract$identifiers[[1]],
            source_time_kind = contract$source_time_kind[[1]],
            source_time_start = contract$source_time_start[[1]],
            source_time_end = .nullable_chr(contract$source_time_end[[1]]),
            query_date_keys = contract$query_date_keys[[1]],
            default_batch_key = contract$default_batch_key[[1]],
            normalizer = .nullable_chr(contract$normalizer[[1]]),
            redsan_version = as.character(utils::packageVersion("redsan")),
            roles = roles,
            required_columns = required_columns,
            unique_columns = unique_columns),
        class = c("ee_source_spec", "list"))
}

source_roles <- function(spec) {
    if (!inherits(spec, "ee_source_spec")) {
        stop("source_roles() requires a source_spec().", call. = FALSE)
    }
    spec$roles
}

# Validate a compatible prepared view without changing it. redsan owns typing;
# this boundary only fails closed when a role-bound column is absent or untyped.
validate_source_view <- function(data, spec) {
    if (!inherits(spec, "ee_source_spec")) {
        stop("validate_source_view() requires a source_spec().", call. = FALSE)
    }
    if (!is.data.frame(data)) {
        stop(spec$name, ": expected a prepared data frame.", call. = FALSE)
    }
    missing <- setdiff(spec$required_columns, names(data))
    if (length(missing)) {
        stop(spec$name, ": missing prepared-view columns: ",
             paste(missing, collapse = ", "), ".", call. = FALSE)
    }
    for (column in spec$unique_columns) {
        value <- data[[column]]
        if (anyNA(value) || any(!nzchar(as.character(value))) ||
            anyDuplicated(value)) {
            stop(spec$name, ": ", column,
                 " must be non-missing and unique.", call. = FALSE)
        }
    }
    numeric_column <- spec$roles$value_num
    if (!is.null(numeric_column) && !is.numeric(data[[numeric_column]])) {
        stop(spec$name, ": role value_num must bind a numeric column; got '",
             numeric_column, "'.", call. = FALSE)
    }
    for (role in intersect(c("point_date", "event_start", "event_end"),
                           names(spec$roles))) {
        column <- spec$roles[[role]]
        if (!inherits(data[[column]], c("Date", "POSIXt"))) {
            stop(spec$name, ": role ", role,
                 " must bind a Date or POSIXt column; got '", column, "'.",
                 call. = FALSE)
        }
    }
    invisible(data)
}

# Adapt normalized redsan frames to the stable execution view used internally.
# This is deliberately an execution-boundary projection, not a second public
# normalization step: redsan owns parsing/typing; the engine supplies only its
# run-local evidence coordinate while preserving physical prepared columns.
.source_row_ids <- function(source, rows) {
    sprintf("%s:%08d", source, as.integer(rows))
}

.prepare_biology_view <- function(data) {
    # redsan owns typing and preserves the normalized physical result columns.
    # The engine adds no `value` alias: variable outputs read NUMRES, STRRES,
    # DATEXAM, or other prepared columns explicitly in from_channel(value =).
    redsan::process_biol(data)
}

.prepare_execution_sources <- function(sources, cohort) {
    if (is.null(sources)) return(sources)
    if (!is.list(sources) || is.null(names(sources))) {
        stop("sources must be a named list.", call. = FALSE)
    }

    cohort_patids <- unique(as.character(cohort$PATID))
    cohort_patids <- cohort_patids[!is.na(cohort_patids) & nzchar(cohort_patids)]
    prepared_sources <- intersect(names(sources), names(EE_SOURCES))
    for (source in prepared_sources) {
        data <- sources[[source]]
        if (!is.data.frame(data)) next
        # Restrict the expensive normalization/projection to declared cohort
        # subjects. PATID is the conservative early key: event- and window-level
        # scope is applied later by each channel, after anchors are resolved.
        # Keep original row positions so generated evidence coordinates continue
        # to resolve against the caller's complete source snapshot.
        source_rows <- seq_len(nrow(data))
        if (length(cohort_patids) && "PATID" %in% names(data)) {
            keep <- !is.na(data$PATID) &
                as.character(data$PATID) %in% cohort_patids
            source_rows <- source_rows[keep]
            data <- data[which(keep), , drop = FALSE]
        }
        prepare <- EE_SOURCE_PREPARERS[[source]] %||% base::identity
        data <- prepare(data)
        if (!"source_row_id" %in% names(data)) {
            data <- tibble::add_column(
                data,
                source_row_id = .source_row_ids(source, source_rows),
                .before = 1L)
        }
        sources[[source]] <- data
    }
    sources
}

DOCS_SOURCE <- source_spec(
    name = "documents", module = "doceds", table = "documents",
    roles = list(
        subject_id = "PATID", event_id = "EVTID", source_item_id = "ELTID",
        point_date = "RECDATE", document_type = "RECTYPE"),
    unique_columns = "ELTID")

.is_tcorpus <- function(x) inherits(x, "tCorpus")

# A metadata-rich tCorpus is the canonical public document source. corpustools
# stores the column supplied as doc_column under its own `doc_id` name; the
# engine restores the native EDSAN name only in this private execution view.
.document_index_from_corpus <- function(corpus) {
    if (!.is_tcorpus(corpus) || !is.function(corpus$get_meta)) {
        stop("documents must be a corpustools tCorpus.", call. = FALSE)
    }
    meta <- tibble::as_tibble(corpus$get_meta(copy = TRUE))
    if (!"doc_id" %in% names(meta)) {
        stop("documents tCorpus metadata is missing doc_id.", call. = FALSE)
    }
    if ("ELTID" %in% names(meta)) {
        same_id <- identical(as.character(meta$ELTID),
                             as.character(meta$doc_id))
        if (!same_id) {
            stop("documents tCorpus must use ELTID as its doc_column.",
                 call. = FALSE)
        }
        meta$ELTID <- NULL
    }
    names(meta)[names(meta) == "doc_id"] <- "ELTID"
    validate_source_view(meta, DOCS_SOURCE)
    meta
}

# Normalize the canonical tCorpus and the retained legacy bundle to the one
# private shape consumed by text retrieval.
.raw_document_source <- function(src) {
    if (.is_tcorpus(src)) {
        return(list(corpus = src,
                    docs_index = .document_index_from_corpus(src)))
    }
    if (is.list(src) && all(c("corpus", "docs_index") %in% names(src))) {
        if (!.is_tcorpus(src$corpus) || !is.data.frame(src$docs_index)) {
            stop("legacy document bundles need a tCorpus and docs_index frame.",
                 call. = FALSE)
        }
        validate_source_view(src$docs_index, DOCS_SOURCE)
        return(src)
    }
    NULL
}

.document_index <- function(src) {
    if (is.data.frame(src)) {
        validate_source_view(src, DOCS_SOURCE)
        return(src)
    }
    raw <- .raw_document_source(src)
    if (!is.null(raw)) return(raw$docs_index)
    stop("documents must be a metadata-rich tCorpus or a document index frame.",
         call. = FALSE)
}

DIAG_SOURCE <- source_spec(
    name = "pmsi diagnoses", module = "pmsi", table = "diag",
    roles = list(
        source_row_id = "source_row_id", subject_id = "PATID",
        event_id = "EVTID", source_item_id = "ELTID", code = "diag",
        event_start = "DATENT", event_end = "DATSORT"))

BIOL_SOURCE <- source_spec(
    name = "biology results", module = "biol", table = "results",
    roles = list(
        source_row_id = "source_row_id", subject_id = "PATID",
        event_id = "EVTID", source_item_id = "ELTID",
        source_result_id = "BIOL_ID", point_date = "DATEXAM",
        analyte = "TYPEANA"),
    required_columns = c(
        "source_row_id", "PATID", "EVTID", "ELTID", "DATEXAM", "TYPEANA"))

ACTE_SOURCE <- source_spec(
    name = "PMSI acts", module = "pmsi", table = "actes",
    roles = list(
        source_row_id = "source_row_id", subject_id = "PATID",
        event_id = "EVTID", source_item_id = "ELTID", code = "CODEACTE",
        point_date = "DATEACTE"))

EE_SOURCES <- list(
    pmsi_diag = DIAG_SOURCE,
    pmsi_actes = ACTE_SOURCE,
    biology = BIOL_SOURCE,
    documents = DOCS_SOURCE)

# Source-specific boundary adaptation is itself registry data. Adding virology
# or bacteriology means registering its source contract and, only if necessary,
# its preparer here; execution never branches on a source name.
EE_SOURCE_PREPARERS <- list(
    biology = .prepare_biology_view)

edsan_source_specs <- function() {
    EE_SOURCES
}
