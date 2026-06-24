# =============================================================================
# channels.R -- experimental channel + selector constructors
# -----------------------------------------------------------------------------
# A channel is ONE source-specific route for resurfacing signals related to a
# concept. It does not interpret clinical meaning. `type` (code / text / lab) is
# the dispatch key the runner uses to pick an execution path; `produces` is the
# signal shape; `selector` is the source-specific identity rule. The text channel
# may also carry the concept-owned answer `extractor` (its response definition),
# because the answer schema belongs to the concept, not to each variable.
# =============================================================================

channel <- function(source, selector, produces, type = "generic",
                    native_grain = NA_character_, required_roles = character(),
                    linkage = character(), ...) {
    for (arg in c("source", "produces", "type")) {
        val <- get(arg)
        if (!is.character(val) || length(val) != 1L || !nzchar(val)) {
            stop(arg, " must be one non-empty string.", call. = FALSE)
        }
    }
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

code_channel <- function(source, selector, produces = "code_hit", ...) {
    channel(source, selector, produces, type = "code", ...)
}

text_channel <- function(source, selector, produces = "text_candidate", ...) {
    channel(source, selector, produces, type = "text", ...)
}

lab_channel <- function(source, selector, produces = "numeric_measurement", ...) {
    channel(source, selector, produces, type = "lab", ...)
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
