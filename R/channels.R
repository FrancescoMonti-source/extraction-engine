# =============================================================================
# channels.R -- experimental channel + selector constructors
# -----------------------------------------------------------------------------
# A channel is ONE source-specific route for resurfacing signals related to a
# concept. It does not interpret clinical meaning. `type` (code / lab / text) is
# the dispatch key the runner uses to pick an execution path, and it IMPLIES the
# signal shape: `produces` is derived from the constructor, never supplied by the
# user (a code channel cannot claim to produce a measurement). `selector` is the
# source-specific identity rule. The text channel may also carry the concept-owned
# answer `extractor` (its response definition), because the answer schema belongs
# to the concept, not to each variable.
# =============================================================================

# Signal shape per channel type. The constructor sets this; users never write it.
.channel_produces <- c(
    code = "code_hit",
    act  = "act_hit",
    lab  = "numeric_measurement",
    text = "text_candidate",
    doc  = "doc_hit")

channel <- function(source, selector, type = "generic",
                    native_grain = NA_character_, required_roles = character(),
                    linkage = character(), ...) {
    for (arg in c("source", "type")) {
        val <- get(arg)
        if (!is.character(val) || length(val) != 1L || !nzchar(val)) {
            stop(arg, " must be one non-empty string.", call. = FALSE)
        }
    }
    # Aggregate membership predicate (the HAVING shape, DESIGN §16.7 -> landed
    # 2026-07-05): membership decided by a group aggregate ("anaemic stay = the
    # stay's mean Hb < 10"). Still a row FILTER -- qualifying groups keep their
    # ORIGINAL rows -- so it lives on the channel definition as a pair of plain
    # params, validated here for every typed constructor:
    #   group_at_level  = the identity-spine key whose groups are tested
    #   keep_group_when = plain closure, group values -> one TRUE/FALSE
    extra <- list(...)
    has_pred <- !is.null(extra$keep_group_when)
    has_lvl <- !is.null(extra$group_at_level)
    if (has_pred || has_lvl) {
        if (has_pred && !is.function(extra$keep_group_when)) {
            stop("keep_group_when must be a plain function ",
                 "(the group's values -> one TRUE/FALSE).", call. = FALSE)
        }
        if (has_pred && !has_lvl) {
            stop("keep_group_when needs group_at_level: the closure decides ",
                 "which GROUPS keep their rows.", call. = FALSE)
        }
        if (has_lvl && !has_pred) {
            stop("group_at_level without keep_group_when is dead weight; ",
                 "declare the predicate or drop the level.", call. = FALSE)
        }
        if (!is.character(extra$group_at_level) ||
            length(extra$group_at_level) != 1L ||
            !extra$group_at_level %in% c("PATID", "EVTID", "ELTID")) {
            stop("group_at_level must be an identity-spine key ",
                 "(PATID/EVTID/ELTID); got '",
                 paste(extra$group_at_level, collapse = ", "), "'.",
                 call. = FALSE)
        }
    }
    produces <- unname(.channel_produces[type])
    if (is.na(produces)) produces <- paste0(type, "_signal")
    .experimental_spec(
        c(list(
            type = type,
            source = source,
            selector = selector,
            produces = produces,
            native_grain = native_grain,
            required_roles = required_roles,
            linkage = linkage),
          list(...)),
        "ee_channel")
}

code_channel <- function(source, selector, ...) {
    channel(source, selector, type = "code", ...)
}

text_channel <- function(source, selector, ...) {
    channel(source, selector, type = "text", ...)
}

lab_channel <- function(source, selector, ...) {
    channel(source, selector, type = "lab", ...)
}

# Act channel: CCAM procedure codes over pmsi$actes. Same membership executor as
# code_channel (a code family over a coded source); the source's point-dated time
# and CODEACTE column are resolved from its roles.
act_channel <- function(source, selector, ...) {
    channel(source, selector, type = "act", ...)
}

# Doc channel: the simplest channel kind -- a document's EXISTENCE is the hit,
# selected on docs_index METADATA (doc_meta), no content read, no Lucene, no LLM
# (consumer 2026-07-07: date of the pre-op anesthesia consult = a document of
# type X from unite medicale ANES). The hit rows are docs_index rows: they carry
# the identity spine (PATID/EVTID/ELTID) and their own clock (RECDATE), so a doc
# hit joins level algebra and feeds a date payload like any structured row set.
doc_channel <- function(source, selector, ...) {
    channel(source, selector, type = "doc", ...)
}

# --- selectors ----------------------------------------------------------------
# A selector is the concept-level identity rule for one source. A code selector
# (icd10 for CIM-10 diagnoses, ccam for CCAM acts) declares codes + a match mode:
# `match = "regex"` matches each pattern against the normalized code (e.g.
# icd10("^E1[0-4]")); `match = "exact"` matches against the normalized code set.
# The code SYSTEM is implied by the channel's source, so the selector only carries
# codes + mode (both lower to the same `kind = "code"` selector).
icd10 <- function(pattern, match = c("regex", "exact")) {
    .experimental_spec(
        list(kind = "code", codes = as.character(pattern), match = match.arg(match)),
        "ee_selector")
}

ccam <- function(codes, match = c("exact", "regex")) {
    .experimental_spec(
        list(kind = "code", codes = as.character(codes), match = match.arg(match)),
        "ee_selector")
}

lucene_query <- function(query) {
    .experimental_spec(list(kind = "lucene_query", query = as.character(query)),
                       "ee_selector")
}

# Document-metadata selector for a doc_channel: named any-of filters over
# docs_index columns, e.g. doc_meta(RECTYPE = "CR-ANES") or
# doc_meta(RECTYPE = c("CR-ANES", "CS-ANES"), SEJUM = "ANES"). Matching is exact
# string equality (HDW metadata is standardized; no normalization pass). A filter
# column the docs index does not carry is a loud run-time error, never a silent
# empty set.
doc_meta <- function(...) {
    filters <- list(...)
    if (!length(filters) || is.null(names(filters)) ||
        any(!nzchar(names(filters))) || anyDuplicated(names(filters))) {
        stop("doc_meta() needs uniquely named metadata filters, e.g. ",
             "doc_meta(RECTYPE = \"CR-ANES\").", call. = FALSE)
    }
    filters <- lapply(filters, as.character)
    bad <- vapply(filters, function(v) !length(v) || anyNA(v) || any(!nzchar(v)),
                  logical(1))
    if (any(bad)) {
        stop("doc_meta() filter value(s) must be non-empty strings: ",
             paste(names(filters)[bad], collapse = ", "), call. = FALSE)
    }
    .experimental_spec(list(kind = "doc_meta", filters = filters), "ee_selector")
}

analyte <- function(codes) {
    .experimental_spec(list(kind = "analyte", codes = as.character(codes)),
                       "ee_selector")
}

# Thresholded analyte selector (DESIGN §8/§14.6): the same analyte identity as
# analyte() PLUS a value predicate, so the lab channel's target signal becomes "an
# in-scope measurement of this analyte past the cutoff" -- the MEMBERSHIP face
# (bin_output / combine). `gt` is a strict lower cutoff (the DESIGN §14.6 shape);
# `lt` is the symmetric strict upper cutoff (consumer: §14.9's hb_low, an anaemia
# definition = Hb BELOW threshold). `unit` is carried for provenance/inspectability
# only: HDW results are unit-normalized upstream (redsan), so the executor does not
# convert.
#
# `keep_when` is the SUBJECT-CONTEXT escape (DESIGN §8; consumer: sex/age-dependent
# reference ranges, e.g. anaemia = Hb < 12 in women, < 13 in men). It is a plain
# vectorised predicate whose FORMALS NAME RAW COLUMNS on the analyte's rows -- the
# measured `value` plus any subject attribute the source carries (PATSEX, PATAGE) --
# and returns one logical per row (the reducers-are-plain-functions rule: the
# researcher's closure IS the membership rule, not a sex-keyed threshold table the
# engine would have to interpret). Only columns DECLARED on the source_spec survive
# normalization, so a formal naming an undeclared column is a hard error. `gt`/`lt`
# are the fixed-cutoff sugar for the common single-column case; `keep_when` and the
# bounds are mutually exclusive (fold any fixed part into the closure). At least one
# of {gt, lt, keep_when} is required.
analyte_value <- function(codes, gt = NULL, lt = NULL, unit = NULL, keep_when = NULL) {
    for (bound in c("gt", "lt")) {
        val <- get(bound)
        if (!is.null(val) && (!is.numeric(val) || length(val) != 1L || is.na(val))) {
            stop("analyte_value() `", bound, "` must be one number.", call. = FALSE)
        }
    }
    if (!is.null(keep_when)) {
        if (!is.function(keep_when)) {
            stop("analyte_value() `keep_when` must be a function of the analyte's ",
                 "row columns (e.g. \\(value, PATSEX) value < ifelse(PATSEX == ",
                 "\"F\", 12, 13)).", call. = FALSE)
        }
        if (!is.null(gt) || !is.null(lt)) {
            stop("analyte_value() takes EITHER fixed bounds (gt/lt) OR a keep_when ",
                 "predicate, not both; fold any fixed cutoff into the closure.",
                 call. = FALSE)
        }
        if (!length(formals(keep_when))) {
            stop("analyte_value() `keep_when` must name at least one row column ",
                 "(e.g. `value`); a nullary predicate cannot see the measurement.",
                 call. = FALSE)
        }
    } else if (is.null(gt) && is.null(lt)) {
        stop("analyte_value() needs a value bound (gt and/or lt) or a keep_when ",
             "predicate; for an unthresholded analyte use analyte().", call. = FALSE)
    }
    .experimental_spec(
        list(kind = "analyte", codes = as.character(codes),
             gt = if (is.null(gt)) NULL else as.numeric(gt),
             lt = if (is.null(lt)) NULL else as.numeric(lt),
             unit = if (is.null(unit)) NULL else as.character(unit),
             keep_when = keep_when),
        "ee_selector")
}
