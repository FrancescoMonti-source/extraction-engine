# =============================================================================
# spec.R -- experimental study-variable vocabulary (core constructors)
# -----------------------------------------------------------------------------
# Thin list/S3 constructors for the formalized architecture. This is NOT a stable
# public DSL; it is the smallest executable surface needed to test the boundary:
#   source_spec -> concept_spec -> channels -> variable_template -> variable_spec
#   -> run_variable.
# Companion files: channels.R (channel + selector ctors), operators.R (windows /
# reducers / combiners / outputs / absence), run_variable.R (the execution spine),
# concepts-diabetes.R (the first concrete concept). Keep the API experimental: we
# are validating object boundaries and execution flow, not freezing syntax.
# =============================================================================

suppressWarnings(suppressMessages(library(dplyr)))

# Every spec object is tagged so a reader (and a test) can see the API is not yet
# frozen, and so the runner can dispatch on class rather than on a name string.
.experimental_spec <- function(x, class) {
    structure(x, class = c(class, "ee_experimental", "list"),
              api_status = "experimental")
}

.require_named_list <- function(x, what) {
    if (!is.list(x)) stop(what, " must be a list.", call. = FALSE)
    nms <- names(x)
    if (is.null(nms) || anyNA(nms) || any(!nzchar(nms)) || anyDuplicated(nms)) {
        stop(what, " must be a named list with unique non-empty names.",
             call. = FALSE)
    }
    invisible(TRUE)
}

# Normalize a combine= value into an ee_combiner. A bare string is a hit-set
# expression (combine = "(a | b) & !c"); operator records pass through; NULL is
# allowed (single-channel direct specs). See hit_set_expr() in operators.R.
.as_combiner <- function(combine) {
    if (is.null(combine) || inherits(combine, "ee_combiner")) return(combine)
    if (is.character(combine) && length(combine) == 1L && nzchar(combine)) {
        return(hit_set_expr(combine))
    }
    stop("combine must be a combiner operator or a hit-set expression string.",
         call. = FALSE)
}

# A hit-set expression's referenced channels must be exactly the variable's
# activated channels: a referenced channel that is not activated is an unknown
# symbol; an activated channel absent from the expression is dead weight. Both are
# spec errors, surfaced at build time.
.check_expr_channels <- function(combine, activated) {
    if (!inherits(combine, "ee_combiner") ||
        !identical(combine$kind, "hit_set_expr")) {
        return(invisible(TRUE))
    }
    missing_ch <- setdiff(combine$channels, activated)
    if (length(missing_ch)) {
        stop("combine expression references non-activated channel(s): ",
             paste(missing_ch, collapse = ", "), call. = FALSE)
    }
    unused <- setdiff(activated, combine$channels)
    if (length(unused)) {
        stop("activated channel(s) not used by the combine expression: ",
             paste(unused, collapse = ", "), call. = FALSE)
    }
    invisible(TRUE)
}

# A concept_spec declares the signal channels available for a clinical concept.
# It does not interpret meaning and it does not activate any channel by default.
concept_spec <- function(name, channels) {
    if (!is.character(name) || length(name) != 1L || !nzchar(name)) {
        stop("concept_spec() requires one non-empty name.", call. = FALSE)
    }
    .require_named_list(channels, "channels")
    bad <- !vapply(channels, inherits, logical(1), "ee_channel")
    if (any(bad)) {
        stop("All concept channels must be created with channel constructors.",
             call. = FALSE)
    }
    .experimental_spec(list(name = name, channels = channels), "ee_concept_spec")
}

# use_channel() is the per-channel activation record placed inside a variable_spec.
#   method    -> variable-owned extraction strategy (e.g. llm_after_lucene())
#   reducer   -> variable-owned within-channel reduction (e.g. max_value())
#   extractor -> optional override of the concept-owned answer definition
use_channel <- function(method = NULL, reducer = NULL, extractor = NULL,
                        prompt = NULL, ...) {
    .experimental_spec(
        c(list(method = method, reducer = reducer, extractor = extractor,
               prompt = prompt), list(...)),
        "ee_channel_use")
}

# Turn a template's declared channel selection into per-channel use_channel()
# records. Generic: a text-type channel receives the template's text method and,
# when the concept is neutral (no answer schema on the channel), the template's
# text_extractor -- so "which documented status" is a template/activation choice,
# not baked into the concept. Other channels are activated with defaults. If the
# caller already supplied a named list of use_channel() (a direct override), it is
# returned unchanged.
.activate_channels <- function(concept, channels, text_method = NULL,
                               text_extractor = NULL) {
    if (is.list(channels) && !is.null(names(channels))) return(channels)
    channel_names <- as.character(channels)
    uses <- lapply(channel_names, function(nm) {
        if (identical(concept$channels[[nm]]$type, "text")) {
            use_channel(method = text_method, extractor = text_extractor)
        } else {
            use_channel()
        }
    })
    setNames(uses, channel_names)
}

# The default template build(): map the merged params 1:1 into a variable_spec,
# activating the declared channels with the template's text method/extractor. Every
# concept template (diabetes, smoking, dialysis, anastomoses) used this SAME closure --
# the only per-concept difference (whether a text_extractor is supplied) is already
# just a param, NULL when absent -- so it is factored here instead of copy-pasted into
# each concept. A template needing a genuinely different assembly can still pass its
# own build = to variable_template().
.default_template_build <- function(concept) {
    function(params) {
        variable_spec(
            name = params$name,
            concept = concept,
            unit = params$unit,
            anchor = params$anchor,
            window = params$window,
            channels = .activate_channels(
                concept, params$channels,
                text_method = params$text_method,
                text_extractor = params$text_extractor),
            output = params$output,
            combine = params$combine,
            absence_policy = params$absence_policy,
            template_name = params$template_name)
    }
}

# A variable_template is a CONCEPT-SPECIFIC parametric quickstart (not a generic
# computation pattern). Its build() turns merged parameters into a variable_spec; when
# omitted it defaults to the 1:1 .default_template_build() above (the common case).
variable_template <- function(name, concept, defaults = list(), build = NULL) {
    if (!is.character(name) || length(name) != 1L || !nzchar(name)) {
        stop("variable_template() requires one non-empty name.", call. = FALSE)
    }
    if (!inherits(concept, "ee_concept_spec")) {
        stop("variable_template() requires a concept_spec().", call. = FALSE)
    }
    if (is.null(build)) build <- .default_template_build(concept)
    if (!is.function(build)) {
        stop("variable_template() build= must be a function.", call. = FALSE)
    }
    .experimental_spec(
        list(name = name, concept = concept, defaults = defaults, build = build),
        "ee_variable_template")
}

# A variable_spec is the concrete executable definition of one analytical variable.
# It may be built from a template (template=) or written directly (concept=).
variable_spec <- function(name = NULL, concept = NULL, unit = NULL, anchor = NULL,
                          window = NULL, channels = list(), output = NULL,
                          combine = NULL, absence_policy = NULL, template = NULL,
                          template_name = NULL, ...) {
    if (!is.null(template)) {
        if (!inherits(template, "ee_variable_template")) {
            stop("template must be created with variable_template().", call. = FALSE)
        }
        overrides <- list(...)
        if (!missing(name)) overrides$name <- name
        if (!missing(unit)) overrides$unit <- unit
        if (!missing(anchor)) overrides$anchor <- anchor
        if (!missing(window)) overrides$window <- window
        if (!missing(channels)) overrides$channels <- channels
        if (!missing(output)) overrides$output <- output
        if (!missing(combine)) overrides$combine <- combine
        if (!missing(absence_policy)) overrides$absence_policy <- absence_policy
        params <- utils::modifyList(template$defaults, overrides, keep.null = TRUE)
        params$template_name <- template$name
        return(template$build(params))
    }

    if (!is.character(name) || length(name) != 1L || !nzchar(name)) {
        stop("variable_spec() requires one non-empty name.", call. = FALSE)
    }
    if (!inherits(concept, "ee_concept_spec")) {
        stop("variable_spec() requires a concept_spec().", call. = FALSE)
    }
    .require_named_list(channels, "channels")
    bad <- !vapply(channels, inherits, logical(1), "ee_channel_use")
    if (any(bad)) stop("channels must use use_channel().", call. = FALSE)

    unknown <- setdiff(names(channels), names(concept$channels))
    if (length(unknown)) {
        stop("Selected channel(s) not declared by concept_spec: ",
             paste(unknown, collapse = ", "), call. = FALSE)
    }

    combine <- .as_combiner(combine)            # bare string -> hit_set_expr()
    .check_expr_channels(combine, names(channels))

    .experimental_spec(
        list(name = name, concept = concept, unit = unit, anchor = anchor,
             window = window, channels = channels, output = output,
             combine = combine, absence_policy = absence_policy,
             template = template_name),
        "ee_variable_spec")
}
