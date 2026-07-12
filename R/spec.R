# =============================================================================
# spec.R -- study-variable vocabulary and compiler
# -----------------------------------------------------------------------------
# Thin list/S3 constructors for the package architecture:
#   source_spec -> concept_spec -> channels -> variable_spec -> run_variable.
# Companion files: channels.R (channel + selector ctors), operators.R (windows /
# reducers / combiners / outputs / absence), run_variable.R (the execution spine).
# Keep the API experimental: we are validating object boundaries and execution
# flow, not freezing syntax.
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
# Text methods are ordinary strings; the study-owned prompt stays directly beside
# the method that consumes it. Ellmer schemas and parsing remain engine work.
use_channel <- function(method = NULL, prompt = NULL, system_prompt = NULL,
                        max_candidates = NULL, selector = NULL,
                        keep_when = NULL, reducer = NULL) {
    if (!is.null(reducer)) {
        stop("use_channel() no longer takes reducer: reduction lives on the ",
              "output -- num_output(values_from =, reduce =) / ",
              "cat_output(levels, values_from =, reduce =).", call. = FALSE)
    }
    if (!is.null(method) &&
        (!is.character(method) || length(method) != 1L || is.na(method) ||
         !method %in% c("lucene", "lucene_llm"))) {
        stop("use_channel() method must be 'lucene', 'lucene_llm', or NULL.",
             call. = FALSE)
    }
    for (field in c("prompt", "system_prompt")) {
        value <- get(field)
        if (!is.null(value) &&
            (!is.character(value) || length(value) != 1L || is.na(value) ||
             !nzchar(trimws(value)))) {
            stop("use_channel() ", field, " must be one non-empty string or NULL.",
                 call. = FALSE)
        }
    }
    if (!is.null(max_candidates)) {
        if (!is.numeric(max_candidates) || length(max_candidates) != 1L ||
            is.na(max_candidates) || !is.finite(max_candidates) ||
            max_candidates < 1 || max_candidates != floor(max_candidates) ||
            max_candidates > .Machine$integer.max) {
            stop("use_channel() max_candidates must be one positive integer or NULL.",
                 call. = FALSE)
        }
        max_candidates <- as.integer(max_candidates)
    }
    llm_args <- !is.null(prompt) || !is.null(system_prompt) ||
        !is.null(max_candidates)
    if (!identical(method, "lucene_llm") && llm_args) {
        stop("prompt, system_prompt, and max_candidates are valid only with ",
             "method = 'lucene_llm'.", call. = FALSE)
    }
    if (identical(method, "lucene_llm") && is.null(prompt)) {
        stop("method = 'lucene_llm' requires prompt = <non-empty string>.",
             call. = FALSE)
    }
    if (!is.null(selector) && !inherits(selector, "ee_selector")) {
        stop("use_channel() selector must be created with a selector constructor.",
             call. = FALSE)
    }
    if (!is.null(keep_when)) {
        if (!is.function(keep_when) || !length(formals(keep_when))) {
            stop("use_channel() keep_when must be a function naming the source ",
                 "row columns it reads.", call. = FALSE)
        }
        if (!is.null(selector)) {
            stop("use_channel() takes either selector or keep_when, not both; ",
                 "keep_when extends the inherited analyte selector.",
                 call. = FALSE)
        }
    }
    .new_spec(
        list(method = method, prompt = prompt, system_prompt = system_prompt,
             max_candidates = max_candidates, selector = selector,
             keep_when = keep_when),
        "ee_channel_use")
}

# Text execution has two deliberately narrow public modes. Retrieval-only Lucene
# produces binary membership; Lucene + LLM produces one grammar-gated category.
.check_text_channel_uses <- function(channels, catalog, output) {
    text_names <- names(channels)[vapply(
        names(channels),
        function(name) identical(catalog[[name]]$type, "text"),
        logical(1))]
    for (name in text_names) {
        method <- channels[[name]]$method
        if (is.null(method)) {
            stop("Text channel '", name, "' requires use_channel(method = ",
                 "'lucene' or 'lucene_llm').", call. = FALSE)
        }
        if (identical(method, "lucene") &&
            !identical(output$kind, "binary")) {
            stop("Text method 'lucene' produces presence and requires bin_output().",
                 call. = FALSE)
        }
        if (identical(method, "lucene_llm") &&
            (!identical(output$kind, "categorical") ||
             is.function(output$reduce))) {
            stop("Text method 'lucene_llm' requires cat_output(levels) without ",
                 "a payload reducer.", call. = FALSE)
        }
    }
    any(vapply(text_names, function(name) {
        identical(channels[[name]]$method, "lucene_llm")
    }, logical(1)))
}

# A variable_spec is the concrete executable definition of one analytical variable.
# Reuse is an ordinary R function that calls this constructor.
variable_spec <- function(name, concept, output_one_row_per = "PATID",
                           anchor = NULL, window = NULL, channels = list(),
                           output = NULL, combine_channels = NULL,
                           combine_at_level = NULL, model = NULL,
                           model_params = list()) {
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
    if (!is.null(model) &&
        (!is.character(model) || length(model) != 1L || is.na(model) ||
         !nzchar(model))) {
        stop("variable_spec() model must be one non-empty model name or NULL.",
             call. = FALSE)
    }
    if (is.null(model_params)) model_params <- list()
    if (!is.list(model_params)) {
        stop("variable_spec() model_params must be a named list.",
             call. = FALSE)
    }
    if (length(model_params) &&
        (is.null(names(model_params)) || anyNA(names(model_params)) ||
         any(!nzchar(names(model_params))) || anyDuplicated(names(model_params)))) {
        stop("variable_spec() model_params must be a named list with unique ",
             "non-empty names.", call. = FALSE)
    }
    if (is.null(model) && length(model_params)) {
        stop("variable_spec() model_params require model = <model name>.",
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
    catalog <- c(concept$channels, inline_channels)
    needs_chat <- .check_text_channel_uses(channels, catalog, output)
    if (!is.null(model) && !needs_chat) {
        stop("variable_spec() model has no effect without a selected ",
             "method = 'lucene_llm' channel.",
             call. = FALSE)
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
              combine = combine, combine_at_level = combine_at_level,
              model = model, model_params = model_params),
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
              evidence_scope = x$evidence_scope,
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

.one_line <- function(x) paste(deparse(x, width.cutoff = 500L), collapse = " ")

.print_selector <- function(selector, indent = "    ") {
    if (is.null(selector)) return(invisible(NULL))
    if (identical(selector$kind, "analyte")) {
        cat(indent, "analyte: ", paste(selector$codes, collapse = ", "), "\n",
            sep = "")
        if (!is.null(selector$keep_when)) {
            cat(indent, "rule: ", .one_line(selector$keep_when), "\n", sep = "")
        } else if (!is.null(selector$gt) || !is.null(selector$lt)) {
            bounds <- c(
                if (!is.null(selector$gt)) paste0("value > ", selector$gt),
                if (!is.null(selector$lt)) paste0("value < ", selector$lt))
            cat(indent, "rule: ", paste(bounds, collapse = " and "), "\n", sep = "")
        }
    } else if (identical(selector$kind, "code")) {
        cat(indent, "codes: ", paste(selector$codes, collapse = ", "),
            " (", selector$match, ")\n", sep = "")
    } else if (identical(selector$kind, "lucene_query")) {
        cat(indent, "query: ", selector$query, "\n", sep = "")
    } else if (identical(selector$kind, "doc_meta")) {
        filters <- paste(names(selector$filters), selector$filters,
                         sep = "=", collapse = ", ")
        cat(indent, "filters: ", filters, "\n", sep = "")
    }
    invisible(NULL)
}

.print_evidence_scope <- function(evidence_scope, indent = "    ") {
    if (is.null(evidence_scope)) return(invisible(NULL))
    scope <- if (identical(evidence_scope, "event")) {
        "same PATID + EVTID"
    } else {
        "same PATID"
    }
    cat(indent, "scope: ", scope, "\n", sep = "")
    invisible(NULL)
}

print.ee_concept_spec <- function(x, ...) {
    cat("Concept: ", x$name, "\n", sep = "")
    cat("Channels:\n")
    for (name in names(x$channels)) {
        channel <- x$channels[[name]]
        cat("  ", name, "\n", sep = "")
        cat("    type: ", channel$type, "\n", sep = "")
        cat("    source: ", channel$source, "\n", sep = "")
        .print_selector(channel$selector)
        .print_evidence_scope(channel$evidence_scope)
    }
    invisible(x)
}

print.ee_variable_spec <- function(x, ...) {
    resolved <- resolve_variable_spec(x)
    cat("Study variable: ", resolved$name, "\n", sep = "")
    cat("Concept: ", resolved$concept, "\n", sep = "")
    cat("Output: ", resolved$output$kind, ", one row per ",
        resolved$output_one_row_per, "\n", sep = "")
    if (!is.null(resolved$model)) {
        cat("Model: ", resolved$model, "\n", sep = "")
    }
    if (is.null(resolved$window)) {
        cat("Window: whole available history at the declared grain\n")
    } else {
        cat("Window: ", resolved$window$from_days, " to ",
            resolved$window$to_days, " days from ",
            if (is.character(resolved$anchor)) resolved$anchor else "index event",
            "\n", sep = "")
    }
    cat("\nChannels:\n")
    for (name in names(resolved$channels)) {
        channel <- resolved$channels[[name]]
        cat("  ", name, "\n", sep = "")
        cat("    source: ", channel$source, "\n", sep = "")
        .print_selector(channel$selector)
        .print_evidence_scope(channel$evidence_scope)
        if (!is.null(channel$method)) {
            cat("    method: ", channel$method, "\n", sep = "")
        }
        if (identical(channel$method, "lucene_llm")) {
            candidate_rule <- if (is.null(channel$max_candidates)) {
                "all matches"
            } else {
                paste("first", channel$max_candidates, "matches")
            }
            cat("    candidates after Lucene: ", candidate_rule, "\n", sep = "")
            prompt <- gsub("\\s+", " ", channel$prompt)
            cat("    llm prompt: ", trimws(prompt), "\n", sep = "")
            cat("    system prompt: ",
                if (is.null(channel$system_prompt)) "package default" else "override",
                "\n", sep = "")
            cat("    response: categorical value + evidence ids ",
                "(engine generated)\n", sep = "")
        }
    }
    combine <- resolved$combine_rule
    if (length(combine) == 1L && !is.na(combine)) {
        cat("\nCombine: ", combine, "\n", sep = "")
    }
    invisible(x)
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

.extend_analyte_selector <- function(selector, keep_when, channel_name) {
    if (is.null(keep_when)) return(selector)
    if (is.null(selector) || !identical(selector$kind, "analyte")) {
        stop("Channel '", channel_name,
             "': use_channel(keep_when =) can extend only an inherited analyte ",
             "selector.", call. = FALSE)
    }
    if (!is.null(selector$gt) || !is.null(selector$lt) ||
        !is.null(selector$keep_when)) {
        stop("Channel '", channel_name,
             "' already carries a value rule; keep_when cannot silently replace ",
             "it.", call. = FALSE)
    }
    selector$gt <- NULL
    selector$lt <- NULL
    selector$unit <- selector$unit %||% NULL
    selector$keep_when <- keep_when
    selector
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
    # The selector inherits like every other activation field (DESIGN section 14.3): a
    # use_channel(selector = ...) override IS the executed definition, so the
    # resolved view -- and the provenance built from it -- must record it, not the
    # concept baseline.
    selector <- .inherit_from_activation(channel_def, channel_use, "selector")
    selector$value <- .extend_analyte_selector(
        selector$value, channel_use$keep_when, name)
    if (!is.null(channel_use$keep_when)) {
        selector$source <- "channel + activation keep_when"
    }

    .new_spec(
        list(
            name = name,
            type = channel_def$type,
            source = channel_def$source,
            selector = selector$value,
            selector_source = selector$source,
            native_grain = channel_def$native_grain,
            required_roles = channel_def$required_roles,
            evidence_scope = channel_def$evidence_scope,
            produces = channel_def$produces,
            group_at_level = channel_def$group_at_level,
            keep_group_when = channel_def$keep_group_when,
            method = channel_use$method,
            prompt = channel_use$prompt,
            system_prompt = channel_use$system_prompt,
            max_candidates = channel_use$max_candidates),
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
            model = variable$model,
            model_params = variable$model_params,
            channels = resolved_channels),
        "ee_resolved_variable_spec")
}
