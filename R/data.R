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

DOCS_SOURCE <- source_spec(
    name = "documents", module = "doceds", table = "documents",
    roles = list(
        subject_id = "PATID", event_id = "EVTID", source_item_id = "ELTID",
        point_date = "RECDATE", document_type = "RECTYPE"),
    unique_columns = "ELTID")

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
        analyte = "analyte", value_num = "value", value_str = "value_raw"))

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
