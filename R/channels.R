# Channel and selector constructors ------------------------------------------

.channel_produces <- c(
    code = "code_hit",
    act = "act_hit",
    lab = "lab_rows",
    text = "text_candidate",
    doc = "doc_hit")

.check_llm_definition <- function(x, what = "definition") {
    required <- c("system_prompt", "type_builder", "prompt_builder", "parser")
    if (!inherits(x, "ee_llm_definition") || !all(required %in% names(x)) ||
        !is.function(x$type_builder) || !is.function(x$prompt_builder) ||
        !is.function(x$parser)) {
        stop(what, " is not a valid internal LLM definition.", call. = FALSE)
    }
    invisible(TRUE)
}

.check_channel_selector <- function(selector, expected_kind, type) {
    if (!inherits(selector, "ee_selector")) {
        stop(type, "_channel() selector must be created with a selector ",
             "constructor.", call. = FALSE)
    }
    if (!selector$kind %in% expected_kind) {
        stop(type, "_channel() cannot use selector kind '", selector$kind,
             "'.", call. = FALSE)
    }
    invisible(TRUE)
}

channel <- function(source, selector, type,
                    native_grain = NA_character_, required_roles = character()) {
    if (!is.character(source) || length(source) != 1L || !nzchar(source)) {
        stop("source must be one non-empty string.", call. = FALSE)
    }
    if (!is.character(type) || length(type) != 1L ||
        !type %in% names(.channel_produces)) {
        stop("type must be one of: ", paste(names(.channel_produces), collapse = ", "),
             ".", call. = FALSE)
    }
    if (!inherits(selector, "ee_selector")) {
        stop("selector must be created with a selector constructor.",
             call. = FALSE)
    }
    if (!(length(native_grain) == 1L &&
          (is.na(native_grain) ||
           (is.character(native_grain) && nzchar(native_grain))))) {
        stop("native_grain must be one non-empty string or NA.", call. = FALSE)
    }
    if (!is.character(required_roles) || anyNA(required_roles) ||
        any(!nzchar(required_roles))) {
        stop("required_roles must contain non-empty role names.", call. = FALSE)
    }
    .new_spec(
        list(
            type = type,
            source = source,
            selector = selector,
            produces = unname(.channel_produces[[type]]),
            native_grain = native_grain,
            required_roles = unique(required_roles)),
        "ee_channel")
}

code_channel <- function(source, selector, native_grain = NA_character_,
                         required_roles = character()) {
    .check_channel_selector(selector, "code", "code")
    channel(source, selector, "code", native_grain, required_roles)
}

act_channel <- function(source, selector, native_grain = NA_character_,
                        required_roles = character()) {
    .check_channel_selector(selector, "code", "act")
    channel(source, selector, "act", native_grain, required_roles)
}

lab_channel <- function(source = "biology", selector,
                        native_grain = NA_character_,
                        required_roles = character()) {
    .check_channel_selector(selector, "analyte", "lab")
    channel(source, selector, "lab", native_grain, required_roles)
}

text_channel <- function(selector, source = "documents",
                         native_grain = NA_character_,
                         required_roles = character()) {
    .check_channel_selector(selector, "lucene_query", "text")
    channel(source, selector, "text", native_grain, required_roles)
}

doc_channel <- function(source, selector, native_grain = NA_character_,
                        required_roles = character()) {
    .check_channel_selector(selector, "doc_meta", "doc")
    channel(source, selector, "doc", native_grain, required_roles)
}

.check_codes <- function(codes, what) {
    codes <- as.character(codes)
    if (!length(codes) || anyNA(codes) || any(!nzchar(codes))) {
        stop(what, " requires non-empty code values.", call. = FALSE)
    }
    codes
}

icd10 <- function(pattern, match = c("regex", "exact")) {
    .new_spec(
        list(kind = "code", codes = .check_codes(pattern, "icd10()"),
             match = match.arg(match)),
        "ee_selector")
}

ccam <- function(codes, match = c("exact", "regex")) {
    .new_spec(
        list(kind = "code", codes = .check_codes(codes, "ccam()"),
             match = match.arg(match)),
        "ee_selector")
}

lucene_query <- function(query) {
    if (!is.character(query) || length(query) != 1L || !nzchar(query)) {
        stop("lucene_query() requires one non-empty query.", call. = FALSE)
    }
    .new_spec(list(kind = "lucene_query", query = query), "ee_selector")
}

doc_meta <- function(...) {
    filters <- list(...)
    if (!length(filters) || is.null(names(filters)) ||
        any(!nzchar(names(filters))) || anyDuplicated(names(filters))) {
        stop("doc_meta() needs uniquely named metadata filters.", call. = FALSE)
    }
    filters <- lapply(filters, as.character)
    bad <- vapply(filters, function(v) !length(v) || anyNA(v) || any(!nzchar(v)),
                   logical(1))
    if (any(bad)) {
        stop("doc_meta() filter values must be non-empty strings: ",
             paste(names(filters)[bad], collapse = ", "), ".", call. = FALSE)
    }
    .new_spec(list(kind = "doc_meta", filters = filters), "ee_selector")
}

analyte <- function(codes) {
    .new_spec(list(kind = "analyte", codes = .check_codes(codes, "analyte()")),
              "ee_selector")
}
