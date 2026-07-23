# =============================================================================
# spec.R -- study-variable vocabulary and compiler
# -----------------------------------------------------------------------------
# Thin list/S3 constructors for the package architecture:
#   source_spec -> concept_spec -> channel activations -> variable_spec -> run_variable.
# Companion files: channels.R (channel + selector ctors), operators.R (windows /
# combiners / outputs / absence), run_variable.R (the execution spine).
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

# Normalize the single activation grammar:
#   alias = use_channel(channel = "concept_channel", concept = concept, ...)
#   alias = use_channel(channel = text_channel(...), ...)
# The external name is always the alias. A character `channel=` resolves only in
# the concept explicitly attached to that activation, never through another alias.
.normalize_variable_channels <- function(channels) {
    if (!is.list(channels)) {
        stop("channels must be a named list of use_channel() activations.",
             call. = FALSE)
    }
    if (!length(channels)) {
        stop("channels must activate at least one channel.", call. = FALSE)
    }
    .require_named_list(channels, "channels")
    bad <- !vapply(channels, inherits, logical(1), "ee_channel_use")
    if (any(bad)) {
        stop("Every channels entry must use alias = use_channel(channel = ...); ",
             "invalid: ", paste(names(channels)[bad], collapse = ", "), ".",
             call. = FALSE)
    }
    invisible(lapply(
        names(channels),
        function(alias) .activation_channel_definition(alias, channels[[alias]])))
    catalogs <- lapply(channels, function(activation) {
        if (is.character(activation$channel)) activation$concept else NULL
    })
    catalogs <- catalogs[!vapply(catalogs, is.null, logical(1))]
    catalog_names <- vapply(catalogs, `[[`, character(1), "name")
    duplicated_names <- unique(catalog_names[duplicated(catalog_names)])
    for (catalog_name in duplicated_names) {
        aliases <- names(catalogs)[catalog_names == catalog_name]
        reference <- catalogs[[aliases[[1L]]]]
        same_catalog <- vapply(
            catalogs[aliases], identical, logical(1), y = reference)
        if (!all(same_catalog)) {
            stop(
                "Concept name '", catalog_name,
                "' refers to non-identical catalogs in activations: ",
                paste(aliases, collapse = ", "),
                ". Within one variable, a concept name must identify one catalog.",
                call. = FALSE)
        }
    }
    channels
}

# Enforce the combine / channel / output validity matrix (design note section 8).
# The PRESENCE of a combine encodes multi-channel hit-set algebra: with >=2
# channels combine MUST be built by combine_channels(); with a single channel
# there is no hit-algebra, so combine MUST be NULL and the value is shaped by the
# output. All cross-channel combine is hit-set algebra -- there is no reconcile
# rule, so combine = NULL over >=2 channels is an error.
.resolve_variable_combine <- function(combine, channel_names, output) {
    n <- length(channel_names)
    if (inherits(combine, "ee_combiner") && identical(combine$kind, "hit_set_expr")) {
        if (n < 2L) {
            stop("A combine expression needs >=2 channels; a single channel ",
                 "uses combine = NULL.", call. = FALSE)
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
        stop("Missing combine: >=2 activated channels need ",
             "combine_channels(expr, by) -- there is no reconcile rule otherwise.",
             call. = FALSE)
    }
    if (n == 1L && is.null(output)) {
        stop("A single-channel variable needs bin_output() or from_channel().",
             call. = FALSE)
    }
    combine
}

# Validate the payload alias and cross-grain filtering contract. The channel
# definition itself is checked later, once aliases have been resolved.
.check_output_contract <- function(output, channel_names, combine) {
    if (identical(output$kind, "binary")) return(output)
    if (!identical(output$kind, "from_channel")) {
        stop("Unsupported output contract '", output$kind,
             "'; use bin_output() or from_channel().", call. = FALSE)
    }
    if (!output$channel %in% channel_names) {
        stop("from_channel() must name an activated alias: got '",
             output$channel, "'; activated: ",
             paste(channel_names, collapse = ", "), ".", call. = FALSE)
    }

    has_combine <- inherits(combine, "ee_combiner") &&
        identical(combine$kind, "hit_set_expr")
    filter_level <- output$filter_by_qualified
    if (!has_combine) {
        if (!is.null(filter_level)) {
            stop("from_channel() filter_by_qualified requires combine = ",
                 "combine_channels(expr, by).", call. = FALSE)
        }
        return(output)
    }

    spine <- c(PATID = 1L, EVTID = 2L, ELTID = 3L)
    combine_rank <- unname(spine[[combine$by]])
    output_rank <- unname(spine[[output$group_by]])
    is_fine_to_coarse <- combine_rank > output_rank

    if (!is_fine_to_coarse && !is.null(filter_level)) {
        stop("from_channel() filter_by_qualified must be NULL unless combine$by ",
             "is finer than output$group_by.", call. = FALSE)
    }
    if (is_fine_to_coarse && is.null(filter_level)) {
        stop("from_channel() requires filter_by_qualified when combine$by ('",
             combine$by, "') is finer than output$group_by ('",
             output$group_by, "').", call. = FALSE)
    }
    endpoints <- c(combine$by, output$group_by)
    if (!is.null(filter_level) && !filter_level %in% endpoints) {
        stop("from_channel() filter_by_qualified must equal combine$by ('",
             combine$by, "') or output$group_by ('", output$group_by,
             "'); got '", filter_level, "'.", call. = FALSE)
    }
    output
}

# A hit-set expression's referenced channels must be exactly the variable's
# activated channels: a referenced channel that is not activated is an unknown
# symbol; an activated channel absent from the expression is dead weight. Both are
# spec errors, surfaced at build time. One exemption: the output's payload channel
# may stay out of the expression -- it does not define the qualifying
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

.response_field_names <- function(response) {
    properties <- tryCatch(S7::props(response)$properties,
                           error = function(cnd) NULL)
    names(properties) %||% character()
}

.LLM_RESERVED_RESPONSE_FIELDS <- c(
    "rationale", "evidence_ids",
    "task_id", "PATID", "EVTID", "ELTID", "source_EVTID",
    "variable", "channel", "source", "origin", "origin_kind",
    "origin_concept", "origin_channel",
    "field", "value", "accepted_value", "n_payload_rows",
    "status", "coverage_state", "processing_state", "channel_coverage",
    "selection_status", "evidence_kind",
    "needs_review", "review_reason", "field_validity", "validity_reason",
    "task_validity", "task_validity_reason", "citation_warning",
    "citation_warning_reason", "provider", "model", "params",
    "attempt_status", "processing_status", "call_status", "response_status",
    "transport_attempts", "raw_response",
    "partial_response", "prompt_hash", "schema_hash", "query_hash",
    "error", "n_tries", "started_at", "latency_ms", "output_tokens",
    "inferred_finish_reason", "temperature", "seed", "max_tokens",
    "definition", "model_candidate_rank", "anchor_date",
    "snippet_id", "hit_ref", "source_row_id", "evidence_ref")

# use_channel() is the complete variable-local activation. A named catalog
# channel carries its concept explicitly; an inline channel is self-contained.
use_channel <- function(channel, concept = NULL, selector = NULL,
                        filter_rows = NULL,
                        group_by = NULL, filter_groups = NULL,
                        search_within = NULL, window = NULL, method = NULL,
                        model = NULL, model_params = list(),
                        response = NULL, rationale = TRUE,
                        user_prompt = NULL, system_prompt = NULL,
                        max_candidates = NULL) {
    rationale_missing <- missing(rationale)
    filter_rows <- rlang::enquo(filter_rows)
    filter_groups <- rlang::enquo(filter_groups)
    if (rlang::quo_is_null(filter_rows)) filter_rows <- NULL
    if (rlang::quo_is_null(filter_groups)) filter_groups <- NULL
    if (missing(channel)) {
        stop("use_channel() requires channel = <concept-channel name or inline channel>.",
             call. = FALSE)
    }
    valid_origin <- inherits(channel, "ee_channel") ||
        (is.character(channel) && length(channel) == 1L && !is.na(channel) &&
         nzchar(channel))
    if (!valid_origin) {
        stop("use_channel() channel must be one concept-channel name or an inline ",
             "channel definition.", call. = FALSE)
    }
    if (is.character(channel) && !inherits(concept, "ee_concept_spec")) {
        stop("use_channel() with a character channel requires ",
             "concept = <concept_spec>.", call. = FALSE)
    }
    if (is.character(channel) && !channel %in% names(concept$channels)) {
        stop("use_channel() references unknown channel '", channel,
             "' in concept '", concept$name, "'.", call. = FALSE)
    }
    if (inherits(channel, "ee_channel") && !is.null(concept)) {
        stop("use_channel() with an inline channel must not declare concept; ",
             "the inline definition is already self-contained.", call. = FALSE)
    }
    if (!is.null(method) &&
        (!is.character(method) || length(method) != 1L || is.na(method) ||
         !method %in% c("lucene", "lucene_llm"))) {
        stop("use_channel() method must be 'lucene', 'lucene_llm', or NULL.",
              call. = FALSE)
    }
    if (!is.null(model) &&
        (!is.character(model) || length(model) != 1L || is.na(model) ||
         !nzchar(model))) {
        stop("use_channel() model must be one non-empty model name or NULL.",
             call. = FALSE)
    }
    if (is.null(model_params)) model_params <- list()
    if (!is.list(model_params)) {
        stop("use_channel() model_params must be a named list.",
             call. = FALSE)
    }
    if (length(model_params) &&
        (is.null(names(model_params)) || anyNA(names(model_params)) ||
         any(!nzchar(names(model_params))) || anyDuplicated(names(model_params)))) {
        stop("use_channel() model_params must be a named list with unique ",
             "non-empty names.", call. = FALSE)
    }
    if (is.null(model) && length(model_params)) {
        stop("use_channel() model_params require model = <model name>.",
             call. = FALSE)
    }
    for (field in c("user_prompt", "system_prompt")) {
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
    if (!is.null(selector) && !inherits(selector, "ee_selector")) {
        stop("use_channel() selector must be created with a selector constructor.",
             call. = FALSE)
    }
    has_group <- !is.null(group_by)
    has_group_rule <- !is.null(filter_groups)
    if (has_group != has_group_rule) {
        stop(if (has_group)
                 "use_channel() group_by requires filter_groups."
             else "use_channel() filter_groups requires group_by.",
             call. = FALSE)
    }
    if (has_group) {
        if (!is.character(group_by) || length(group_by) != 1L ||
            is.na(group_by) ||
            !group_by %in% c("PATID", "EVTID", "ELTID")) {
            stop("use_channel() group_by must be PATID, EVTID, or ELTID.",
                 call. = FALSE)
        }
    }
    if (!is.null(search_within) &&
        (!is.character(search_within) ||
         length(search_within) != 1L || is.na(search_within) ||
         !search_within %in% c("PATID", "EVTID"))) {
        stop("use_channel() search_within must be PATID, EVTID, or NULL.",
             call. = FALSE)
    }
    window <- .as_window(window)

    is_llm <- identical(method, "lucene_llm")
    llm_only_args <- !is.null(model) || length(model_params) ||
        !is.null(response) || !is.null(user_prompt) ||
        !is.null(system_prompt) || !is.null(max_candidates) || !rationale_missing
    if (!is_llm && llm_only_args) {
        stop("model, model_params, response, rationale, user_prompt, system_prompt, ",
             "and max_candidates are valid only with method = 'lucene_llm'.",
             call. = FALSE)
    }
    if (is_llm) {
        if (!inherits(response, "ellmer::TypeObject")) {
            stop("method = 'lucene_llm' requires response = ellmer::type_object(...).",
                 call. = FALSE)
        }
        collisions <- intersect(.response_field_names(response),
                                .LLM_RESERVED_RESPONSE_FIELDS)
        if (length(collisions)) {
            stop("LLM response field(s) reserved by the engine: ",
                 paste(collisions, collapse = ", "), ".", call. = FALSE)
        }
        if (isTRUE(rationale)) {
            rationale <- DEFAULT_RATIONALE_DESCRIPTION
        } else if (isFALSE(rationale) || is.null(rationale)) {
            rationale <- NULL
        } else if (!is.character(rationale) || length(rationale) != 1L ||
                   is.na(rationale) || !nzchar(trimws(rationale))) {
            stop("use_channel() rationale must be TRUE, FALSE, NULL, or one ",
                 "non-empty string.", call. = FALSE)
        }
    } else {
        rationale <- NULL
    }
    .new_spec(
        list(channel = channel, concept = concept,
             selector = selector, filter_rows = filter_rows,
             group_by = group_by, filter_groups = filter_groups,
             search_within = search_within, window = window,
             method = method, model = model, model_params = model_params,
             response = response, rationale = rationale,
             user_prompt = user_prompt, system_prompt = system_prompt,
             max_candidates = max_candidates),
        "ee_channel_use")
}

.activation_channel_definition <- function(alias, activation) {
    origin <- activation$channel
    if (inherits(origin, "ee_channel")) {
        return(list(
            definition = origin,
            origin_concept = NULL,
            origin_channel = alias,
            origin_kind = "inline"))
    }
    concept <- activation$concept
    if (!inherits(concept, "ee_concept_spec")) {
        stop("Activation '", alias, "' uses character channel '", origin,
             "' without a concept_spec().", call. = FALSE)
    }
    definition <- concept$channels[[origin]]
    if (is.null(definition)) {
        stop("Activation '", alias, "' references unknown channel '", origin,
             "' in concept '", concept$name, "'. Activation aliases cannot point ",
             "to other aliases.", call. = FALSE)
    }
    list(
        definition = definition,
        origin_concept = concept$name,
        origin_channel = origin,
        origin_kind = "concept")
}

.check_text_channel_uses <- function(channels) {
    needs_chat <- FALSE
    for (alias in names(channels)) {
        activation <- channels[[alias]]
        definition <- .activation_channel_definition(alias, activation)$definition
        is_text <- identical(definition$type, "text")
        if (is_text && is.null(activation$method)) {
            stop("Text activation '", alias, "' requires method = 'lucene' or ",
                 "'lucene_llm'.", call. = FALSE)
        }
        if (!is_text && !is.null(activation$method)) {
            stop("Activation '", alias, "' uses method = '", activation$method,
                 "', but its channel is not a text channel.", call. = FALSE)
        }
        if (!is_text && !is.null(activation$search_within)) {
            stop("Activation '", alias,
                 "' declares search_within, but its channel is not textual.",
                 call. = FALSE)
        }
        if (is_text && is.null(activation$search_within)) {
            stop("Text activation '", alias,
                 "' requires search_within = 'PATID' or 'EVTID'.",
                 call. = FALSE)
        }
        needs_chat <- needs_chat || identical(activation$method, "lucene_llm")
    }
    needs_chat
}

.check_llm_grain_collisions <- function(channels, output_group_by) {
    for (alias in names(channels)) {
        activation <- channels[[alias]]
        if (!identical(activation$method, "lucene_llm")) next
        collisions <- intersect(
            .response_field_names(activation$response), output_group_by)
        if (length(collisions)) {
            stop("LLM activation '", alias,
                 "' authors the output grain field '", collisions[[1]],
                 "'; grain keys are engine-owned.", call. = FALSE)
        }
    }
    invisible(TRUE)
}

# ELTID identifies one element only inside its prepared source. It is therefore
# safe as a relational key between activation aliases of the same source, but it
# must never be treated as a cross-source identifier. Coarser projection to
# EVTID/PATID remains valid because those are the shared relational keys.
.check_eltid_identity_domain <- function(combine, channels, output) {
    if (!inherits(combine, "ee_combiner") ||
        !identical(combine$kind, "hit_set_expr") ||
        !identical(combine$by, "ELTID")) {
        return(invisible(TRUE))
    }

    aliases <- combine$channels
    sources <- vapply(channels[aliases], `[[`, character(1), "source")
    domains <- unique(unname(sources))
    if (length(domains) != 1L) {
        detail <- paste(paste0(names(sources), "=", sources), collapse = ", ")
        stop("combine_channels(..., by = 'ELTID') requires all referenced ",
             "activations to use the same source identity domain; got ", detail,
             ". Project the relation to EVTID or PATID before combining ",
             "different sources.", call. = FALSE)
    }

    payload_uses_eltid <- identical(output$kind, "from_channel") &&
        (identical(output$group_by, "ELTID") ||
         identical(output$filter_by_qualified, "ELTID"))
    if (payload_uses_eltid) {
        payload_source <- channels[[output$channel]]$source
        if (!identical(payload_source, domains[[1]])) {
            stop("from_channel() cannot apply ELTID-qualified keys from source '",
                 domains[[1]], "' to payload channel '", output$channel,
                 "' from source '", payload_source,
                 "'. Project qualification to EVTID or PATID instead.",
                 call. = FALSE)
        }
    }
    invisible(TRUE)
}

# A structured LLM response is a record, not boolean membership. Until authors
# can declare how a response becomes a hit, accepting every valid response would
# silently make the combine expression mean something different from its text.
.check_llm_combine_channels <- function(combine, channels) {
    if (!inherits(combine, "ee_combiner") ||
        !identical(combine$kind, "hit_set_expr")) {
        return(invisible(TRUE))
    }

    llm_aliases <- names(channels)[vapply(
        channels,
        function(channel) identical(channel$method, "lucene_llm"),
        logical(1))]
    referenced <- intersect(combine$channels, llm_aliases)

    if (length(referenced)) {
        stop(
            "combine_channels() cannot currently use lucene_llm activation(s): ",
            paste(referenced, collapse = ", "), ". A valid structured response ",
            "does not define whether the channel hit. Publish the LLM response ",
            "with from_channel(), or use method = 'lucene' for Lucene-hit ",
            "membership; an explicit response-to-hit rule such as hit_when is ",
            "not implemented.",
            call. = FALSE)
    }

    invisible(TRUE)
}

.check_output_channel_type <- function(output, channels) {
    if (!identical(output$kind, "from_channel")) return(invisible(TRUE))
    activation <- channels[[output$channel]]
    definition <- .activation_channel_definition(
        output$channel, activation)$definition
    if (identical(activation$method, "lucene_llm")) {
        if (!is.null(output$value)) {
            stop("from_channel() value is for deterministic source rows; omit it ",
                 "to publish the complete structured LLM record.", call. = FALSE)
        }
        if (!is.null(output$filter_by_qualified) &&
            !identical(output$filter_by_qualified, output$group_by)) {
            stop("An LLM response is already one row per output task; in a ",
                 "fine-to-coarse combine, from_channel() must use ",
                 "filter_by_qualified = output$group_by ('", output$group_by,
                 "'), not '", output$filter_by_qualified, "'.", call. = FALSE)
        }
        return(invisible(TRUE))
    }
    if (identical(definition$type, "text")) {
        stop("from_channel() cannot publish retrieval-only text activation '",
             output$channel, "'; use bin_output() for Lucene membership.",
             call. = FALSE)
    }
    if (is.null(output$value)) {
        stop("from_channel() must declare value = <data-masked expression> for ",
             "deterministic activation '", output$channel, "'.", call. = FALSE)
    }
    invisible(TRUE)
}

# A variable_spec is the concrete executable definition of one analytical variable.
# Reuse is an ordinary R function that calls this constructor.
variable_spec <- function(name, anchor = NULL, channels = list(),
                          combine = NULL, output = NULL) {
    if (!is.character(name) || length(name) != 1L || is.na(name) ||
        !nzchar(trimws(name))) {
        stop("variable_spec() requires one non-empty name.", call. = FALSE)
    }
    if (!inherits(output, "ee_output_type")) {
        stop("variable_spec() output must be created with an output constructor.",
             call. = FALSE)
    }
    if (!is.null(anchor) && !inherits(anchor, "ee_index_event") &&
        (!is.character(anchor) || length(anchor) != 1L || !nzchar(anchor))) {
        stop("variable_spec() anchor must be NULL, one cohort date column, or index_event().",
             call. = FALSE)
    }
    channels <- .normalize_variable_channels(channels)
    .check_text_channel_uses(channels)
    .check_llm_grain_collisions(channels, output$group_by)

    windowed <- names(channels)[vapply(
        channels, function(x) !is.null(x$window), logical(1))]
    if (length(windowed) && is.null(anchor)) {
        stop("A channel window requires an explicit variable anchor cohort column ",
             "or index_event(); activation(s): ",
             paste(windowed, collapse = ", "), ".", call. = FALSE)
    }

    if (!is.null(combine) && !inherits(combine, "ee_combiner")) {
        stop("variable_spec() combine must be NULL or created with ",
             "combine_channels(expr, by).", call. = FALSE)
    }
    combine <- .resolve_variable_combine(combine, names(channels), output)
    output <- .check_output_contract(output, names(channels), combine)
    .check_output_channel_type(output, channels)
    .check_expr_channels(combine, names(channels),
                         payload_channel = output$channel)
    .check_llm_combine_channels(combine, channels)

    event_search <- names(channels)[vapply(
        channels,
        function(x) identical(x$search_within, "EVTID"),
        logical(1))]
    if (length(event_search) &&
        !identical(output$group_by, "EVTID") &&
        !inherits(anchor, "ee_index_event")) {
        stop("search_within = 'EVTID' requires EVTID-bearing tasks via ",
             "output group_by = 'EVTID' or index_event(); activation(s): ",
             paste(event_search, collapse = ", "), ".", call. = FALSE)
    }

    .new_spec(
        list(name = name, anchor = anchor, channels = channels,
             combine = combine, output = output),
        "ee_variable_spec")
}

# --- inspection / resolution --------------------------------------------------
# Read-only helpers for understanding what will execute after each activation's
# concept defaults and local overrides are combined. They are intentionally
# lightweight: the return value is an experimental list/S3 view, not a frozen
# public schema.

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
             required_roles = x$required_roles),
        "ee_channel_inspection")
}

inspect.ee_resolved_variable_spec <- function(x, ...) {
    x
}

inspect.default <- function(x, ...) {
    stop("No inspect() method for objects of class: ",
         paste(class(x), collapse = ", "), call. = FALSE)
}

.one_line <- function(x) {
    if (rlang::is_quosure(x)) x <- rlang::get_expr(x)
    paste(deparse(x, width.cutoff = 500L), collapse = " ")
}

.print_selector <- function(selector, indent = "    ") {
    if (is.null(selector)) return(invisible(NULL))
    if (identical(selector$kind, "analyte")) {
        cat(indent, "analyte: ", paste(selector$codes, collapse = ", "), "\n",
            sep = "")
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

.print_search_within <- function(search_within, indent = "    ") {
    if (is.null(search_within)) return(invisible(NULL))
    cat(indent, "search within: ", search_within, "\n", sep = "")
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
    }
    invisible(x)
}

print.ee_variable_spec <- function(x, ...) {
    resolved <- resolve_variable_spec(x)
    cat("Study variable: ", resolved$name, "\n", sep = "")
    cat("\nChannels:\n")
    for (name in names(resolved$channels)) {
        channel <- resolved$channels[[name]]
        cat("  ", name, "\n", sep = "")
        origin <- if (identical(channel$origin_kind, "concept")) {
            paste0("concept:", channel$origin_concept, "/",
                   channel$origin_channel)
        } else {
            paste0("inline:", channel$origin_channel)
        }
        cat("    origin: ", origin, "\n", sep = "")
        cat("    source: ", channel$source, "\n", sep = "")
        .print_selector(channel$selector)
        if (!is.null(channel$filter_rows)) {
            cat("    filter rows: ", .one_line(channel$filter_rows), "\n", sep = "")
        }
        if (!is.null(channel$filter_groups)) {
            cat("    intermediate filter groups by ", channel$group_by, ": ",
                .one_line(channel$filter_groups), "\n", sep = "")
        }
        .print_search_within(channel$search_within)
        if (!is.null(channel$window)) {
            cat("    window: ", channel$window$from_days, " to ",
                channel$window$to_days, " days from ",
                if (is.character(resolved$anchor)) resolved$anchor else "index event",
                "\n", sep = "")
        }
        if (!is.null(channel$method)) {
            cat("    method: ", channel$method, "\n", sep = "")
        }
        if (identical(channel$method, "lucene_llm")) {
            cat("    declared model: ",
                channel$model %||% "run_variable(chat=) override required",
                "\n", sep = "")
            candidate_rule <- if (is.null(channel$max_candidates)) {
                "all matches"
            } else {
                paste("first", channel$max_candidates, "matches")
            }
            cat("    candidates after Lucene: ", candidate_rule, "\n", sep = "")
            if (!is.null(channel$user_prompt)) {
                prompt <- gsub("\\s+", " ", channel$user_prompt)
                cat("    user prompt prefix: ", trimws(prompt), "\n", sep = "")
            }
            cat("    system prompt: ",
                if (is.null(channel$system_prompt)) "package default" else "override",
                "\n", sep = "")
            cat("    response fields: ",
                paste(.response_field_names(channel$response), collapse = ", "),
                if (is.null(channel$rationale)) "" else ", rationale",
                " (+ evidence_ids for audit)\n", sep = "")
        }
    }
    combine <- resolved$combine
    if (inherits(combine, "ee_combiner") && !is.null(combine$expr)) {
        cat("\nCombine: ", combine$expr, "\n", sep = "")
        cat("Combine by: ", resolved$combine$by, "\n", sep = "")
    }
    cat("Output: ", resolved$output$kind, "\n", sep = "")
    if (identical(resolved$output$kind, "from_channel")) {
        cat("Payload alias: ", resolved$output$channel, "\n", sep = "")
        cat("Payload value: ",
            if (is.null(resolved$output$value)) "all LLM fields" else
                .one_line(resolved$output$value),
            "\n", sep = "")
        if (!is.null(resolved$output$filter_by_qualified)) {
            cat("Filter by qualified: ",
                resolved$output$filter_by_qualified, "\n", sep = "")
        }
    }
    cat("Group by: ", resolved$output$group_by, "\n", sep = "")
    invisible(x)
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
    # than the typed tCorpus metadata view. It is the one channel-runtime role
    # not bound by the prepared source_spec itself.
    if (identical(channel$type, "text")) available <- c(available, "text")
    missing <- setdiff(required, available)
    if (length(missing)) {
        stop("Channel '", channel$name, "' requires source role(s) not bound by '",
             channel$source, "': ", paste(missing, collapse = ", "), ".",
             call. = FALSE)
    }
    invisible(TRUE)
}

.resolve_channel_activation <- function(name, channel_use) {
    origin <- .activation_channel_definition(name, channel_use)
    channel_def <- origin$definition
    original_selector <- channel_def$selector
    selector <- channel_use$selector %||% original_selector
    expected_selector <- switch(
        channel_def$type,
        code = "code", act = "code", lab = "analyte",
        text = "lucene_query", doc = "doc_meta")
    if (is.null(expected_selector) || !identical(selector$kind, expected_selector)) {
        stop("Activation '", name, "' selector kind '", selector$kind,
             "' is incompatible with channel type '", channel_def$type, "'.",
             call. = FALSE)
    }
    .new_spec(
        list(
            name = name,
            origin_concept = origin$origin_concept,
            origin_channel = origin$origin_channel,
            origin_kind = origin$origin_kind,
            type = channel_def$type,
            source = channel_def$source,
            original_selector = original_selector,
            selector = selector,
            selector_source = if (is.null(channel_use$selector))
                origin$origin_kind else "activation",
            native_grain = channel_def$native_grain,
            required_roles = channel_def$required_roles,
            produces = channel_def$produces,
            filter_rows = channel_use$filter_rows,
            group_by = channel_use$group_by,
            filter_groups = channel_use$filter_groups,
            search_within = channel_use$search_within,
            window = channel_use$window,
            method = channel_use$method,
            model = channel_use$model,
            model_params = channel_use$model_params,
            response = channel_use$response,
            rationale = channel_use$rationale,
            user_prompt = channel_use$user_prompt,
            system_prompt = channel_use$system_prompt,
            max_candidates = channel_use$max_candidates),
        "ee_resolved_channel")
}

resolve_variable_spec <- function(variable) {
    if (inherits(variable, "ee_resolved_variable_spec")) return(variable)
    if (!inherits(variable, "ee_variable_spec")) {
        stop("resolve_variable_spec() requires a variable_spec().", call. = FALSE)
    }
    resolved_channels <- lapply(
        names(variable$channels),
        function(name) .resolve_channel_activation(
            name, variable$channels[[name]]))
    names(resolved_channels) <- names(variable$channels)
    invisible(lapply(resolved_channels, .check_channel_required_roles))
    .check_eltid_identity_domain(
        variable$combine, resolved_channels, variable$output)

    .new_spec(
        list(
            name = variable$name,
            anchor = variable$anchor,
            channels = resolved_channels,
            combine = variable$combine,
            output = variable$output),
        "ee_resolved_variable_spec")
}
