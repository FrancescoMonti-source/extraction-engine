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
    lab  = "numeric_measurement",
    text = "text_candidate")

channel <- function(source, selector, type = "generic",
                    native_grain = NA_character_, required_roles = character(),
                    linkage = character(), ...) {
    for (arg in c("source", "type")) {
        val <- get(arg)
        if (!is.character(val) || length(val) != 1L || !nzchar(val)) {
            stop(arg, " must be one non-empty string.", call. = FALSE)
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

# --- selectors ----------------------------------------------------------------
# A selector is the concept-level identity rule for one source. (The design note
# writes icd10("^E1[0-4]"); this slice carries the equivalent code prefixes so it
# can reuse the tested prefix-family matcher. A richer pattern/regex selector
# grammar is a deferred refinement.)
icd10 <- function(prefixes) {
    .experimental_spec(list(kind = "icd10_prefix", prefixes = as.character(prefixes)),
                       "ee_selector")
}

lucene_query <- function(query) {
    .experimental_spec(list(kind = "lucene_query", query = as.character(query)),
                       "ee_selector")
}

analyte <- function(codes) {
    .experimental_spec(list(kind = "analyte", codes = as.character(codes)),
                       "ee_selector")
}
