# Channel and selector constructors ------------------------------------------

.channel_produces <- c(
    code = "code_hit",
    act = "act_hit",
    lab = "numeric_measurement",
    text = "text_candidate",
    doc = "doc_hit")

.check_llm_task <- function(x, what = "extractor") {
    required <- c("system_prompt", "type_builder", "prompt_builder", "parser")
    if (!is.list(x) || !all(required %in% names(x)) ||
        !is.function(x$type_builder) || !is.function(x$prompt_builder) ||
        !is.function(x$parser)) {
        stop(what, " must be created with llm_task().", call. = FALSE)
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
                    native_grain = NA_character_, required_roles = character(),
                    linkage = character(), extractor = NULL,
                    default_method = NULL, group_at_level = NULL,
                    keep_group_when = NULL) {
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
    if (!is.character(linkage) || anyNA(linkage) ||
        any(!linkage %in% c("subject", "event"))) {
        stop("linkage may contain only 'subject' and 'event'.", call. = FALSE)
    }
    if (!is.null(extractor)) {
        if (!identical(type, "text")) {
            stop("extractor is valid only for text_channel().", call. = FALSE)
        }
        .check_llm_task(extractor)
    }
    if (!is.null(default_method) &&
        !inherits(default_method, "ee_extraction_method")) {
        stop("default_method must be created with llm_after_lucene().",
             call. = FALSE)
    }
    has_level <- !is.null(group_at_level)
    has_predicate <- !is.null(keep_group_when)
    if (has_level != has_predicate) {
        stop(if (has_level)
                 "group_at_level without keep_group_when is dead weight."
             else "keep_group_when needs group_at_level.", call. = FALSE)
    }
    if (has_level) {
        if (!is.character(group_at_level) || length(group_at_level) != 1L ||
            !group_at_level %in% c("PATID", "EVTID", "ELTID")) {
            stop("group_at_level must be PATID, EVTID, or ELTID.",
                 call. = FALSE)
        }
        if (!is.function(keep_group_when)) {
            stop("keep_group_when must be a plain function.", call. = FALSE)
        }
    }

    .new_spec(
        list(
            type = type,
            source = source,
            selector = selector,
            produces = unname(.channel_produces[[type]]),
            native_grain = native_grain,
            required_roles = unique(required_roles),
            linkage = unique(linkage),
            extractor = extractor,
            default_method = default_method,
            group_at_level = group_at_level,
            keep_group_when = keep_group_when),
        "ee_channel")
}

code_channel <- function(source, selector, native_grain = NA_character_,
                         required_roles = character(), linkage = character(),
                         group_at_level = NULL, keep_group_when = NULL) {
    .check_channel_selector(selector, "code", "code")
    channel(source, selector, "code", native_grain, required_roles, linkage,
            group_at_level = group_at_level,
            keep_group_when = keep_group_when)
}

act_channel <- function(source, selector, native_grain = NA_character_,
                        required_roles = character(), linkage = character(),
                        group_at_level = NULL, keep_group_when = NULL) {
    .check_channel_selector(selector, "code", "act")
    channel(source, selector, "act", native_grain, required_roles, linkage,
            group_at_level = group_at_level,
            keep_group_when = keep_group_when)
}

lab_channel <- function(source, selector, native_grain = NA_character_,
                        required_roles = character(), linkage = character(),
                        group_at_level = NULL, keep_group_when = NULL) {
    .check_channel_selector(selector, "analyte", "lab")
    channel(source, selector, "lab", native_grain, required_roles, linkage,
            group_at_level = group_at_level,
            keep_group_when = keep_group_when)
}

text_channel <- function(source, selector, extractor = NULL,
                         default_method = NULL,
                         native_grain = NA_character_,
                         required_roles = character(), linkage = character(),
                         group_at_level = NULL, keep_group_when = NULL) {
    .check_channel_selector(selector, "lucene_query", "text")
    channel(source, selector, "text", native_grain, required_roles, linkage,
            extractor = extractor, default_method = default_method,
            group_at_level = group_at_level,
            keep_group_when = keep_group_when)
}

doc_channel <- function(source, selector, native_grain = NA_character_,
                        required_roles = character(), linkage = character(),
                        group_at_level = NULL, keep_group_when = NULL) {
    .check_channel_selector(selector, "doc_meta", "doc")
    channel(source, selector, "doc", native_grain, required_roles, linkage,
            group_at_level = group_at_level,
            keep_group_when = keep_group_when)
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

analyte_value <- function(codes, gt = NULL, lt = NULL, unit = NULL,
                          keep_when = NULL) {
    for (bound in c("gt", "lt")) {
        value <- get(bound)
        if (!is.null(value) &&
            (!is.numeric(value) || length(value) != 1L || is.na(value))) {
            stop("analyte_value() `", bound, "` must be one number.",
                 call. = FALSE)
        }
    }
    if (!is.null(unit) &&
        (!is.character(unit) || length(unit) != 1L || is.na(unit) || !nzchar(unit))) {
        stop("analyte_value() `unit` must be one non-empty string.",
             call. = FALSE)
    }
    if (!is.null(keep_when)) {
        if (!is.function(keep_when)) {
            stop("analyte_value() `keep_when` must be a function of row columns.",
                 call. = FALSE)
        }
        if (!is.null(gt) || !is.null(lt)) {
            stop("analyte_value() takes EITHER fixed bounds (gt/lt) OR ",
                 "keep_when, not both.",
                 call. = FALSE)
        }
        if (!length(formals(keep_when))) {
            stop("analyte_value() `keep_when` must name at least one row column.",
                 call. = FALSE)
        }
    } else if (is.null(gt) && is.null(lt)) {
        stop("analyte_value() needs gt/lt or keep_when; use analyte() otherwise.",
             call. = FALSE)
    }
    .new_spec(
        list(kind = "analyte", codes = .check_codes(codes, "analyte_value()"),
             gt = if (is.null(gt)) NULL else as.numeric(gt),
             lt = if (is.null(lt)) NULL else as.numeric(lt),
             unit = unit, keep_when = keep_when),
        "ee_selector")
}
