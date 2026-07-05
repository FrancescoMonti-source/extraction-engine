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

# Lower any_positive() to a raw hit-set expression and enforce the combine / channel
# / output validity matrix (design note §8). The PRESENCE of a combine encodes
# multi-channel hit-set algebra: with >=2 channels combine MUST be an expression
# (any_positive() is sugar that lowers to "a | b | ..."); with a single channel
# there is no hit-algebra, so combine MUST be NULL and the value is shaped by
# output(). All cross-channel combine is hit-set algebra -- there is no reconcile
# rule, so combine = NULL over >=2 channels is an error.
.resolve_variable_combine <- function(combine, channel_names, output) {
    n <- length(channel_names)
    if (inherits(combine, "ee_combiner") && identical(combine$kind, "any_positive")) {
        if (n < 2L) {
            stop("any_positive() needs >=2 channels; for a single channel drop ",
                 "combine (combine = NULL) and let output() shape the value.",
                 call. = FALSE)
        }
        combine <- hit_set_expr(paste(channel_names, collapse = " | "))
    }
    if (inherits(combine, "ee_combiner") && identical(combine$kind, "hit_set_expr")) {
        if (n < 2L) {
            stop("A combine expression needs >=2 channels; a single channel must ",
                 "use combine = NULL.", call. = FALSE)
        }
        # A combine expression gates ROWS; it never produces the value itself
        # (DESIGN §8). bin_output() lifts membership directly; num/cat read the
        # survivors' values and must declare the payload (values_from + reduce,
        # checked with the channel list in .check_output_payload); str/struct
        # behind a gate stay unshaped until a consumer arrives.
        if (!is.null(output) && !identical(output$kind, "binary")) {
            if (output$kind %in% c("number", "categorical")) {
                if (!is.function(output$reduce)) {
                    stop("combine gates rows, it does not produce the value; a '",
                         output$kind, "' output behind a combine expression must ",
                         "declare its payload: values_from = <channel> + reduce = ",
                         "<function> (only bin_output() lifts membership directly).",
                         call. = FALSE)
                }
            } else {
                stop("Output '", output$kind, "' behind a combine expression is ",
                     "not shaped yet (DESIGN §8): bin (membership) and num/cat ",
                     "(values_from/reduce payload) are; revisit with a consumer.",
                     call. = FALSE)
            }
        }
        return(combine)
    }
    if (inherits(combine, "ee_combiner")) {
        stop("Unsupported combiner '", combine$kind, "'. Cross-channel combine is ",
             "hit-set algebra only; single-channel assembly is driven by output(), ",
             "not combine.", call. = FALSE)
    }
    # combine is NULL from here.
    if (n >= 2L) {
        stop("combine = NULL requires a single channel; supply a combine ",
             "expression (hit-set algebra) for >=2 channels -- there is no ",
             "reconcile rule otherwise.", call. = FALSE)
    }
    if (n == 1L && is.null(output)) {
        stop("A single-channel variable needs an output() ",
             "(binary/number/categorical/fields) to shape its value.", call. = FALSE)
    }
    combine
}

# Payload resolution for num/cat outputs (DESIGN §8): values_from must name an
# activated channel; omitted, it can only default to the sole channel of a
# single-channel variable -- with several channels the pick is real, non-derivable
# information. Returns the output with values_from normalized, so the runner and
# provenance always see the executed payload channel.
.check_output_payload <- function(output, channel_names) {
    if (is.null(output) || !output$kind %in% c("number", "categorical")) {
        return(output)
    }
    if (!is.function(output$reduce)) return(output)   # extraction-flavor cat
    if (is.null(output$values_from)) {
        if (length(channel_names) != 1L) {
            stop("A payload output over several channels must declare values_from ",
                 "= <channel>: the payload pick is not derivable.", call. = FALSE)
        }
        output$values_from <- channel_names[[1]]
    } else if (!output$values_from %in% channel_names) {
        stop("values_from must name an activated channel: got '",
             output$values_from, "'; activated: ",
             paste(channel_names, collapse = ", "), ".", call. = FALSE)
    }
    output
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
#   extractor -> optional override of the concept-owned answer definition
use_channel <- function(method = NULL, extractor = NULL,
                        selector = NULL, prompt = NULL, ...) {
    extra <- list(...)
    # An activation NEVER carries source: the name binding IS the reference to the
    # concept-declared channel, and re-declaring the source there lets definitions
    # drift (DESIGN §6). Rejected loudly rather than silently ignored.
    if ("source" %in% names(extra)) {
        stop("use_channel() does not take source: an activation references a ",
             "declared channel by name; source lives on the channel definition.",
             call. = FALSE)
    }
    # Reduction is the variable's question, not a channel property: it lives on the
    # output (num_output/cat_output(values_from =, reduce =), DESIGN §8, wired
    # 2026-07-05). The old activation spelling is rejected, not silently carried.
    if ("reducer" %in% names(extra)) {
        stop("use_channel() no longer takes reducer: reduction lives on the ",
             "output -- num_output(values_from =, reduce =) / ",
             "cat_output(levels, values_from =, reduce =).", call. = FALSE)
    }
    if (length(extra) && (is.null(names(extra)) || any(!nzchar(names(extra))))) {
        stop("use_channel() extra arguments must be named.", call. = FALSE)
    }
    .experimental_spec(
        c(list(method = method, extractor = extractor,
               selector = selector, prompt = prompt), extra),
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
            output_one_row_per = params$output_one_row_per,
            anchor = params$anchor,
            window = params$window,
            channels = .activate_channels(
                concept, params$channels,
                text_method = params$text_method,
                text_extractor = params$text_extractor),
            output = params$output,
            combine = params$combine,
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
variable_spec <- function(name = NULL, concept = NULL, output_one_row_per = "PATID",
                          anchor = NULL, window = NULL, channels = list(),
                          output = NULL, combine = NULL, template = NULL,
                          template_name = NULL, ...) {
    if (!is.null(template)) {
        if (!inherits(template, "ee_variable_template")) {
            stop("template must be created with variable_template().", call. = FALSE)
        }
        overrides <- list(...)
        if ("absence_policy" %in% names(overrides)) {
            stop("absence_policy is no longer a variable_spec() argument; ",
                 "use output type plus channel coverage/audit status instead.",
                 call. = FALSE)
        }
        if (!missing(name)) overrides$name <- name
        if (!missing(output_one_row_per)) overrides$output_one_row_per <- output_one_row_per
        if (!missing(anchor)) overrides$anchor <- anchor
        if (!missing(window)) overrides$window <- window
        if (!missing(channels)) overrides$channels <- channels
        if (!missing(output)) overrides$output <- output
        if (!missing(combine)) overrides$combine <- combine
        params <- utils::modifyList(template$defaults, overrides, keep.null = TRUE)
        params$template_name <- template$name
        return(template$build(params))
    }

    unused <- names(list(...))
    if (length(unused)) {
        stop("Unused variable_spec() argument(s): ",
             paste(unused, collapse = ", "), call. = FALSE)
    }

    if (!is.character(name) || length(name) != 1L || !nzchar(name)) {
        stop("variable_spec() requires one non-empty name.", call. = FALSE)
    }
    if (!inherits(concept, "ee_concept_spec")) {
        stop("variable_spec() requires a concept_spec().", call. = FALSE)
    }
    # output_one_row_per is the OUTPUT GRAIN: the concrete task column one output row
    # represents ("PATID" = one row per patient, "EVTID" = one row per stay). It is
    # the group-by the engine honors (the task universe is supplied at this grain) and
    # what run_variable checks the tasks frame against. NULL from a template default
    # coalesces to patient grain.
    if (is.null(output_one_row_per)) output_one_row_per <- "PATID"
    if (!is.character(output_one_row_per) || length(output_one_row_per) != 1L ||
        !nzchar(output_one_row_per)) {
        stop("variable_spec() output_one_row_per must be one non-empty column name ",
             "(e.g. \"PATID\" or \"EVTID\").", call. = FALSE)
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
    combine <- .resolve_variable_combine(combine, names(channels), output)
    .check_expr_channels(combine, names(channels))
    output <- .check_output_payload(output, names(channels))

    .experimental_spec(
        list(name = name, concept = concept, output_one_row_per = output_one_row_per,
             anchor = anchor,
             window = window, channels = channels, output = output,
             combine = combine, template = template_name),
        "ee_variable_spec")
}

# --- inspection / resolution --------------------------------------------------
# Read-only helpers for understanding what will execute after concept defaults and
# variable activations are combined. They are intentionally lightweight: the return
# value is an experimental list/S3 view, not a frozen public schema.

inspect <- function(x, ...) {
    UseMethod("inspect")
}

inspect.ee_variable_spec <- function(x, ...) {
    resolve_variable_spec(x)
}

inspect.ee_concept_spec <- function(x, ...) {
    .experimental_spec(
        list(name = x$name,
             channels = lapply(x$channels, inspect)),
        "ee_concept_inspection")
}

inspect.ee_channel <- function(x, ...) {
    .experimental_spec(
        list(type = x$type,
             source = x$source,
             selector = x$selector,
             native_grain = x$native_grain,
             required_roles = x$required_roles,
             linkage = x$linkage,
             extractor = x$extractor),
        "ee_channel_inspection")
}

inspect.ee_resolved_variable_spec <- function(x, ...) {
    x
}

inspect.default <- function(x, ...) {
    stop("No inspect() method for objects of class: ",
         paste(class(x), collapse = ", "), call. = FALSE)
}

.inherit_from_activation <- function(channel_def, channel_use, field,
                                     channel_field = field) {
    value <- channel_use[[field]]
    source <- "activation"
    if (is.null(value)) {
        value <- channel_def[[channel_field]]
        source <- "channel"
    }
    if (is.null(value)) {
        value <- NULL
        source <- "none"
    }
    list(value = value, source = source)
}

.resolve_channel_activation <- function(name, concept, channel_use) {
    channel_def <- concept$channels[[name]]
    if (is.null(channel_def)) {
        stop("Cannot resolve unknown channel: ", name, call. = FALSE)
    }
    method <- .inherit_from_activation(channel_def, channel_use, "method",
                                       "default_method")
    extractor <- .inherit_from_activation(channel_def, channel_use, "extractor")
    # The selector inherits like every other activation field (DESIGN §14.3): a
    # use_channel(selector = ...) override IS the executed definition, so the
    # resolved view -- and the provenance built from it -- must record it, not the
    # concept baseline.
    selector <- .inherit_from_activation(channel_def, channel_use, "selector")

    .experimental_spec(
        list(
            name = name,
            type = channel_def$type,
            source = channel_def$source,
            selector = selector$value,
            selector_source = selector$source,
            native_grain = channel_def$native_grain,
            required_roles = channel_def$required_roles,
            linkage = channel_def$linkage,
            method = method$value,
            method_source = method$source,
            extractor = extractor$value,
            extractor_source = extractor$source,
            activation = channel_use,
            channel = channel_def),
        "ee_resolved_channel")
}

resolve_variable_spec <- function(variable) {
    if (!inherits(variable, "ee_variable_spec")) {
        stop("resolve_variable_spec() requires a variable_spec().", call. = FALSE)
    }
    resolved_channels <- lapply(
        names(variable$channels),
        function(name) .resolve_channel_activation(
            name, variable$concept, variable$channels[[name]]))
    names(resolved_channels) <- names(variable$channels)

    combine_rule <- if (inherits(variable$combine, "ee_combiner") &&
                        !is.null(variable$combine$expr)) {
        variable$combine$expr
    } else {
        NA_character_
    }

    .experimental_spec(
        list(
            name = variable$name,
            concept = variable$concept$name,
            output_one_row_per = variable$output_one_row_per,
            anchor = variable$anchor,
            window = variable$window,
            template = variable$template,
            output = variable$output,
            combine = variable$combine,
            combine_rule = combine_rule,
            channels = resolved_channels),
        "ee_resolved_variable_spec")
}
