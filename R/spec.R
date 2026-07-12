# =============================================================================
# spec.R -- study-variable vocabulary and compiler
# -----------------------------------------------------------------------------
# Thin list/S3 constructors for the package architecture:
#   source_spec -> concept_spec -> channels -> variable_spec -> run_variable.
# Companion files: channels.R (channel + selector ctors), operators.R (windows /
# reducers / combiners / outputs / absence), run_variable.R (the execution spine),
# concepts-diabetes.R (the first concrete concept). Keep the API experimental: we
# are validating object boundaries and execution flow, not freezing syntax.
# =============================================================================

# Internal constructor used by every authored and compiled record.
.new_spec <- function(x, class) {
    structure(x, class = c(class, "list"))
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

# Normalize a combine_channels= value into an ee_combiner. A bare string is a
# hit-set expression (combine_channels = "(a | b) & !c"); operator records pass
# through; NULL is allowed (single-channel direct specs). See hit_set_expr().
.as_combiner <- function(combine) {
    if (is.null(combine) || inherits(combine, "ee_combiner")) return(combine)
    if (is.character(combine) && length(combine) == 1L && nzchar(combine)) {
        return(hit_set_expr(combine))
    }
    stop("combine_channels must be a combiner operator or a hit-set expression ",
         "string.", call. = FALSE)
}

# Normalize the ratified window spelling (DESIGN section 7): c(from_days, to_days)
# relative to the anchor -- c(0, 180) = forward 6 months, c(-1825, 7) = 5-year
# lookback with a week of grace, c(-Inf, 0) = unbounded lookback. NULL = no
# window (whole history / event scope). Internal ee_window records pass through
# (template defaults built before merging).
.as_window <- function(window) {
    if (is.null(window) || inherits(window, "ee_window")) return(window)
    if (is.numeric(window) && length(window) == 2L && !anyNA(window) &&
        window[[1]] <= window[[2]]) {
        return(.new_spec(
            list(kind = "relative_window",
                 from_days = as.numeric(window[[1]]),
                 to_days = as.numeric(window[[2]]),
                 relation = "days_after"),
            "ee_window"))
    }
    stop("window must be NULL or c(from_days, to_days) relative to the anchor ",
         "(from <= to; e.g. c(0, 180), c(-1825, 7), c(-Inf, 0)).", call. = FALSE)
}

# Normalize the three ratified channel entry forms (DESIGN section 5) into activations
# plus variable-local inline definitions:
#   "name"                       plain activation, inherit everything
#   name = use_channel(...)      activation with local replacements
#   name = lab_channel(...) etc. INLINE definition of a variable-local channel
# Inline names must not collide with concept channels (section 14.3 overrides are the
# only deviation path for inherited channels); promote inline -> concept when a
# second variable wants the same channel.
.normalize_variable_channels <- function(channels, concept) {
    if (is.character(channels)) channels <- as.list(channels)
    if (!is.list(channels)) {
        stop("channels must be a character vector or a list (names, ",
             "use_channel() activations, inline typed definitions).",
             call. = FALSE)
    }
    nms <- names(channels)
    if (is.null(nms)) nms <- rep("", length(channels))
    act_names <- character(length(channels))
    acts <- vector("list", length(channels))
    inline <- list()
    for (i in seq_along(channels)) {
        x <- channels[[i]]
        nm <- nms[[i]]
        if (is.character(x) && length(x) == 1L && nzchar(x) && !nzchar(nm)) {
            act_names[[i]] <- x
            acts[[i]] <- use_channel()
        } else if (inherits(x, "ee_channel_use")) {
            if (!nzchar(nm)) {
                stop("use_channel() entries must be named after the channel ",
                     "they activate.", call. = FALSE)
            }
            act_names[[i]] <- nm
            acts[[i]] <- x
        } else if (inherits(x, "ee_channel")) {
            if (!nzchar(nm)) {
                stop("inline channel definitions must be named.", call. = FALSE)
            }
            if (nm %in% names(concept$channels)) {
                stop("inline channel '", nm, "' collides with a concept ",
                     "channel of the same name; override inherited channels ",
                     "with use_channel(...) replacements instead (DESIGN ",
                     "section 14.3).", call. = FALSE)
            }
            act_names[[i]] <- nm
            inline[[nm]] <- x
            acts[[i]] <- use_channel()
        } else {
            stop("channels entries must be channel names, use_channel() ",
                 "activations, or named inline typed channel definitions.",
                 call. = FALSE)
        }
    }
    if (anyDuplicated(act_names)) {
        stop("channels activates a channel more than once: ",
             paste(unique(act_names[duplicated(act_names)]), collapse = ", "),
             call. = FALSE)
    }
    list(activations = stats::setNames(acts, act_names), inline = inline)
}

# Lower any_positive() to a raw hit-set expression and enforce the combine / channel
# / output validity matrix (design note section 8). The PRESENCE of a combine encodes
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
                 "combine_channels and let output() shape the value.",
                 call. = FALSE)
        }
        combine <- hit_set_expr(paste(channel_names, collapse = " | "))
    }
    if (inherits(combine, "ee_combiner") && identical(combine$kind, "hit_set_expr")) {
        if (n < 2L) {
            stop("A combine expression needs >=2 channels; a single channel ",
                 "drops combine_channels.", call. = FALSE)
        }
        # A combine expression gates ROWS; it never produces the value itself
        # (DESIGN section 8). bin_output() lifts membership directly; num/cat read the
        # survivors' values and must declare the payload (values_from + reduce,
        # checked with the channel list in .check_output_payload); str/struct
        # behind a gate stay unshaped until a consumer arrives.
        if (!is.null(output) && !identical(output$kind, "binary")) {
            if (output$kind %in% c("number", "categorical", "date")) {
                if (!is.function(output$reduce)) {
                    stop("combine gates rows, it does not produce the value; a '",
                         output$kind, "' output behind a combine expression must ",
                         "declare its payload: values_from = <channel> + reduce = ",
                         "<function> (only bin_output() lifts membership directly).",
                         call. = FALSE)
                }
            } else {
                stop("Output '", output$kind, "' behind a combine expression is ",
                     "not shaped yet (DESIGN section 8): bin (membership) and num/cat/date ",
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
        stop("Missing combine_channels: >=2 activated channels need a hit-set ",
             "expression -- there is no reconcile rule otherwise.", call. = FALSE)
    }
    if (n == 1L && is.null(output)) {
        stop("A single-channel variable needs an output() ",
             "(binary/number/categorical/fields) to shape its value.", call. = FALSE)
    }
    combine
}

# Payload resolution for num/cat/date outputs (DESIGN section 8): values_from must name
# an activated channel; omitted, it can only default to the sole channel of a
# single-channel variable -- with several channels the pick is real, non-derivable
# information. Returns the output with values_from normalized, so the runner and
# provenance always see the executed payload channel.
.check_output_payload <- function(output, channel_names) {
    if (is.null(output) || !output$kind %in% c("number", "categorical", "date")) {
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
# spec errors, surfaced at build time. One exemption: the output's payload channel
# (values_from) may stay out of the expression -- it does not define the qualifying
# keys, but its rows are still scoped by them (DESIGN sections 8 and 14.9).
.check_expr_channels <- function(combine, activated, payload_channel = NULL) {
    if (!inherits(combine, "ee_combiner") ||
        !identical(combine$kind, "hit_set_expr")) {
        return(invisible(TRUE))
    }
    missing_ch <- setdiff(combine$channels, activated)
    if (length(missing_ch)) {
        stop("combine expression references non-activated channel(s): ",
             paste(missing_ch, collapse = ", "), call. = FALSE)
    }
    unused <- setdiff(activated, c(combine$channels, payload_channel))
    if (length(unused)) {
        stop("activated channel(s) not used by the combine expression: ",
             paste(unused, collapse = ", "), call. = FALSE)
    }
    invisible(TRUE)
}

# combine_at_level (DESIGN section 7): the key at which the expression is evaluated;
# qualifying keys exists-lift to the output grain. NULL = the output grain (the
# default, today's semantics). Declared, it must sit ON the identity spine and at
# the output grain or finer -- evaluating coarser would leak hits across output
# rows. It rides the combine: a single-channel variable has no algebra to place.
.check_combine_at_level <- function(level, combine, output_one_row_per) {
    if (is.null(level)) return(NULL)
    if (!is.character(level) || length(level) != 1L || !nzchar(level)) {
        stop("combine_at_level must be one non-empty column name.", call. = FALSE)
    }
    if (!inherits(combine, "ee_combiner") ||
        !identical(combine$kind, "hit_set_expr")) {
        stop("combine_at_level needs a combine expression: a single channel's ",
             "filtered rows are already the surviving set; there is no algebra ",
             "to evaluate at a level.", call. = FALSE)
    }
    spine <- c(PATID = 1L, EVTID = 2L, ELTID = 3L)
    if (!level %in% names(spine)) {
        stop("combine_at_level must be an identity-spine key (",
             paste(names(spine), collapse = "/"), "); got '", level, "'.",
             call. = FALSE)
    }
    if (output_one_row_per %in% names(spine) &&
        spine[[level]] < spine[[output_one_row_per]]) {
        stop("combine_at_level ('", level, "') must be the output grain or a ",
             "finer spine key: evaluating above '", output_one_row_per,
             "' would leak hits across output rows.", call. = FALSE)
    }
    level
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
    .new_spec(list(name = name, channels = channels), "ee_concept_spec")
}

# use_channel() is the per-channel activation record placed inside a variable_spec.
#   method    -> variable-owned extraction strategy (e.g. llm_after_lucene())
#   extractor -> optional override of the concept-owned answer definition
use_channel <- function(method = NULL, extractor = NULL, selector = NULL,
                        reducer = NULL) {
    if (!is.null(reducer)) {
        stop("use_channel() no longer takes reducer: reduction lives on the ",
              "output -- num_output(values_from =, reduce =) / ",
              "cat_output(levels, values_from =, reduce =).", call. = FALSE)
    }
    if (!is.null(method) && !inherits(method, "ee_extraction_method")) {
        stop("use_channel() method must be created with llm_after_lucene().",
             call. = FALSE)
    }
    if (!is.null(extractor)) .check_task_definition(extractor)
    if (!is.null(selector) && !inherits(selector, "ee_selector")) {
        stop("use_channel() selector must be created with a selector constructor.",
             call. = FALSE)
    }
    .new_spec(
        list(method = method, extractor = extractor, selector = selector),
        "ee_channel_use")
}

# Turn a builder's declared channel selection into per-channel use_channel()
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
    stats::setNames(uses, channel_names)
}

# A variable_spec is the concrete executable definition of one analytical variable.
# Reuse is an ordinary R function that calls this constructor.
variable_spec <- function(name, concept, output_one_row_per = "PATID",
                           anchor = NULL, window = NULL, channels = list(),
                           output = NULL, combine_channels = NULL,
                           combine_at_level = NULL) {
    if (!is.character(name) || length(name) != 1L || !nzchar(name)) {
        stop("variable_spec() requires one non-empty name.", call. = FALSE)
    }
    if (!inherits(concept, "ee_concept_spec")) {
        stop("variable_spec() requires a concept_spec().", call. = FALSE)
    }
    if (!inherits(output, "ee_output_type")) {
        stop("variable_spec() output must be created with an output constructor.",
             call. = FALSE)
    }
    if (!is.null(anchor) && !inherits(anchor, "ee_index_event") &&
        (!is.character(anchor) || length(anchor) != 1L || !nzchar(anchor))) {
        stop("variable_spec() anchor must be NULL, one task column, or index_event().",
             call. = FALSE)
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
    normalized <- .normalize_variable_channels(channels, concept)
    channels <- normalized$activations
    inline_channels <- normalized$inline

    unknown <- setdiff(names(channels),
                       c(names(concept$channels), names(inline_channels)))
    if (length(unknown)) {
        stop("Selected channel(s) not declared by concept_spec or inline: ",
             paste(unknown, collapse = ", "), call. = FALSE)
    }

    window <- .as_window(window)
    if (!is.null(window) && is.null(anchor)) {
        stop("A relative window requires an explicit anchor task column or ",
             "index_event().", call. = FALSE)
    }

    combine <- .as_combiner(combine_channels)   # bare string -> hit_set_expr()
    combine <- .resolve_variable_combine(combine, names(channels), output)
    combine_at_level <- .check_combine_at_level(combine_at_level, combine,
                                                output_one_row_per)
    # Payload first: values_from is normalized there (defaults to the sole
    # channel), and the expression check exempts the payload channel from the
    # dead-weight rule -- a payload-only channel is legitimate (section 14.9).
    output <- .check_output_payload(output, names(channels))
    .check_expr_channels(combine, names(channels),
                         payload_channel = output$values_from)

    .new_spec(
        list(name = name, concept = concept, output_one_row_per = output_one_row_per,
              anchor = anchor,
              window = window, channels = channels,
              inline_channels = inline_channels, output = output,
              combine = combine, combine_at_level = combine_at_level),
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
    .new_spec(
        list(name = x$name,
             channels = lapply(x$channels, inspect)),
        "ee_concept_inspection")
}

inspect.ee_channel <- function(x, ...) {
    .new_spec(
        list(type = x$type,
             source = x$source,
             selector = x$selector,
             native_grain = x$native_grain,
             required_roles = x$required_roles,
              linkage = x$linkage,
              extractor = x$extractor,
              default_method = x$default_method,
              group_at_level = x$group_at_level,
              keep_group_when = x$keep_group_when),
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

.check_channel_required_roles <- function(channel) {
    required <- channel$required_roles
    if (!length(required)) return(invisible(TRUE))
    spec <- EE_SOURCES[[channel$source]]
    if (is.null(spec)) {
        stop("Cannot validate required_roles for unregistered prepared source '",
             channel$source, "'.", call. = FALSE)
    }
    available <- names(source_roles(spec))
    # Text content lives in the corpus/pre-retrieved candidate payload rather
    # than the typed docs_index. It is the one channel-runtime role not bound by
    # the prepared source_spec itself.
    if (identical(channel$type, "text")) available <- c(available, "text")
    missing <- setdiff(required, available)
    if (length(missing)) {
        stop("Channel '", channel$name, "' requires source role(s) not bound by '",
             channel$source, "': ", paste(missing, collapse = ", "), ".",
             call. = FALSE)
    }
    invisible(TRUE)
}

# `catalog` is the variable's full channel catalog: concept channels plus any
# variable-local inline definitions (they resolve identically; an inline definer
# binds wherever it appears, DESIGN section 5).
.resolve_channel_activation <- function(name, catalog, channel_use) {
    channel_def <- catalog[[name]]
    if (is.null(channel_def)) {
        stop("Cannot resolve unknown channel: ", name, call. = FALSE)
    }
    method <- .inherit_from_activation(channel_def, channel_use, "method",
                                       "default_method")
    extractor <- .inherit_from_activation(channel_def, channel_use, "extractor")
    # The selector inherits like every other activation field (DESIGN section 14.3): a
    # use_channel(selector = ...) override IS the executed definition, so the
    # resolved view -- and the provenance built from it -- must record it, not the
    # concept baseline.
    selector <- .inherit_from_activation(channel_def, channel_use, "selector")

    .new_spec(
        list(
            name = name,
            type = channel_def$type,
            source = channel_def$source,
            selector = selector$value,
            selector_source = selector$source,
            native_grain = channel_def$native_grain,
            required_roles = channel_def$required_roles,
            linkage = channel_def$linkage,
            produces = channel_def$produces,
            group_at_level = channel_def$group_at_level,
            keep_group_when = channel_def$keep_group_when,
            method = method$value,
            method_source = method$source,
            extractor = extractor$value,
            extractor_source = extractor$source),
        "ee_resolved_channel")
}

resolve_variable_spec <- function(variable) {
    if (inherits(variable, "ee_resolved_variable_spec")) return(variable)
    if (!inherits(variable, "ee_variable_spec")) {
        stop("resolve_variable_spec() requires a variable_spec().", call. = FALSE)
    }
    catalog <- c(variable$concept$channels, variable$inline_channels)
    resolved_channels <- lapply(
        names(variable$channels),
        function(name) .resolve_channel_activation(
            name, catalog, variable$channels[[name]]))
    names(resolved_channels) <- names(variable$channels)
    invisible(lapply(resolved_channels, .check_channel_required_roles))

    combine_rule <- if (inherits(variable$combine, "ee_combiner") &&
                        !is.null(variable$combine$expr)) {
        variable$combine$expr
    } else {
        NA_character_
    }

    .new_spec(
        list(
            name = variable$name,
            concept = variable$concept$name,
            output_one_row_per = variable$output_one_row_per,
            anchor = variable$anchor,
            window = variable$window,
            output = variable$output,
            combine = variable$combine,
            combine_rule = combine_rule,
            combine_at_level = variable$combine_at_level,
            channels = resolved_channels),
        "ee_resolved_variable_spec")
}
