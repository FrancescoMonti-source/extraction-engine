# =============================================================================
# channel-combine.R — cross-channel OR-combine + per-channel reduction
# -----------------------------------------------------------------------------
# The generic combine layer for run_variable()'s any_positive path. It is keyed
# by CHANNEL (the selected signal route): the caller passes a named list of
# per-channel {status, hit, evidence} results and gets back one OR decision plus
# a per-channel status table. "source" is reserved for the warehouse/raw data
# source (e.g. pmsi_diag, documents, biology); a channel reads FROM a source but
# is not the source. The only raw-source field that survives here is the durable
# evidence row key (source_row_id), which is genuine warehouse metadata.
#
# Deliberately not a concept_spec / variable_spec framework — it is the smallest
# runtime seam required by a study variable that accepts evidence from several
# channels.
# =============================================================================

suppressWarnings(suppressMessages(library(dplyr)))

combine_any_channel_hit <- function(channel_results, incomplete_value) {
    if (missing(incomplete_value) || length(incomplete_value) != 1L) {
        stop("incomplete_value must be an explicit scalar", call. = FALSE)
    }
    if (!is.list(channel_results) || !length(channel_results)) {
        stop("channel_results must be a non-empty named list", call. = FALSE)
    }

    channels <- names(channel_results)
    if (is.null(channels) || anyNA(channels) || any(!nzchar(channels)) ||
        anyDuplicated(channels)) {
        stop("channel_results must have unique non-empty channel names",
             call. = FALSE)
    }

    allowed_status <- c("complete", "unavailable", "invalid", "error")
    channel_status <- vector("list", length(channel_results))
    positive_evidence <- list()

    for (i in seq_along(channel_results)) {
        channel <- channels[[i]]
        result <- channel_results[[i]]
        required <- c("status", "hit", "evidence")
        missing_fields <- setdiff(required, names(result))
        if (length(missing_fields)) {
            stop(
                channel, " result requires: ",
                paste(required, collapse = ", "),
                "; missing: ", paste(missing_fields, collapse = ", "),
                call. = FALSE)
        }

        status <- as.character(result$status)
        hit <- result$hit
        evidence <- tibble::as_tibble(result$evidence)
        error <- if ("error" %in% names(result)) {
            as.character(result$error)
        } else {
            NA_character_
        }

        if (length(status) != 1L || !status %in% allowed_status) {
            stop(channel, " has an unknown channel status", call. = FALSE)
        }
        if (length(hit) != 1L || !is.logical(hit)) {
            stop(channel, "$hit must be one logical value", call. = FALSE)
        }
        if (identical(status, "complete") && is.na(hit)) {
            stop(channel, " complete result requires TRUE or FALSE hit",
                 call. = FALSE)
        }
        if (!identical(status, "complete") && isTRUE(hit)) {
            stop(channel, " cannot report a positive hit unless complete",
                 call. = FALSE)
        }
        if (!"source_row_id" %in% names(evidence)) {
            stop(channel, "$evidence requires source_row_id", call. = FALSE)
        }
        evidence$source_row_id <- as.character(evidence$source_row_id)
        if (anyNA(evidence$source_row_id) ||
            any(!nzchar(evidence$source_row_id)) ||
            anyDuplicated(evidence$source_row_id)) {
            stop(channel, " evidence IDs must be non-missing and unique",
                 call. = FALSE)
        }
        if (isTRUE(hit) && !nrow(evidence)) {
            stop(channel, " positive hit requires evidence", call. = FALSE)
        }

        channel_status[[i]] <- tibble::tibble(
            channel = channel,
            status = status,
            hit = hit,
            error = error)

        if (isTRUE(hit)) {
            positive_evidence[[length(positive_evidence) + 1L]] <- evidence %>%
                mutate(channel = channel, .before = 1L)
        }
    }

    channel_status <- bind_rows(channel_status)
    any_positive <- any(channel_status$hit %in% TRUE)
    all_complete <- all(channel_status$status == "complete")

    value <- if (any_positive) {
        1L
    } else if (all_complete) {
        0L
    } else {
        incomplete_value
    }

    list(
        value = value,
        ascertainment = if (all_complete) "complete" else "partial",
        channel_status = channel_status,
        evidence = if (length(positive_evidence)) {
            bind_rows(positive_evidence)
        } else {
            tibble::tibble(channel = character(), source_row_id = character())
        })
}

# =============================================================================
# Per-channel reduction to the {status, hit, evidence} contract that
# combine_any_channel_hit() consumes (via run_variable()'s any_positive path).
#
# The pre-spine diabetes multi-source orchestration helpers
# (measure_diabetes_glucose / reduce_structured_source / reduce_text_source /
# combine_diabetes_any) were removed once run_variable() subsumed them; the OR-combine
# is now driven by variable_spec activations + combine = any_positive() and exercised
# at the spine level (see test-slice-diabetes-spec.R, test-slice-dialysis-spec.R).
# =============================================================================

# Map an engine processing_state (text OR structured vocabulary) + the channel's
# accepted value into the {status, hit} the combiner expects. These mappings are
# RECIPE decisions, surfaced deliberately rather than hidden:
#   - no_candidate                          -> caller-selected complete/unavailable
#   - no data for the subject at all        -> UNAVAILABLE (neither + nor -; partial)
#   - rows present but unusable             -> INVALID (not a negative)
#   - model/processing failure              -> ERROR
.channel_status_from_state <- function(
    processing_state,
    accepted_value,
    no_candidate_status = c("complete", "unavailable")) {
    no_candidate_status <- match.arg(no_candidate_status)
    hit_present <- identical(as.character(accepted_value), "present")
    switch(processing_state,
        measured             = list(status = "complete",    hit = hit_present),
        valid                = list(status = "complete",    hit = hit_present),
        no_candidate         = list(
            status = no_candidate_status,
            hit = if (identical(no_candidate_status, "complete")) FALSE else NA),
        invalid              = list(status = "invalid",     hit = NA),
        no_eligible_source   = list(status = "unavailable", hit = NA),
        no_eligible_document = list(status = "unavailable", hit = NA),
        not_called           = list(status = "unavailable", hit = NA),
        model_error          = list(status = "error",       hit = NA),
        processing_error     = list(status = "error",       hit = NA),
        list(status = "unavailable", hit = NA))
}

# Reduce one channel's full result (the engine's coverage/values/evidence views) to
# a per-task {status, hit, evidence} list keyed by task_id. `id_col` is the durable
# row key in that channel's evidence: source_row_id (structured) or hit_ref (text).
.reduce_channel_result <- function(
    res,
    task_ids,
    id_col,
    no_candidate_status = c("complete", "unavailable")) {
    no_candidate_status <- match.arg(no_candidate_status)
    cov <- res$coverage; val <- res$values; ev <- res$evidence
    # run_extraction returns COLUMN-LESS empty tibbles when no task produced a value
    # (e.g. every task no_candidate); guard so $task_id access on such a tibble does
    # not warn ("Unknown or uninitialised column"). Behaviour is unchanged.
    has_val <- nrow(val) > 0L && all(c("task_id", "accepted_value") %in% names(val))
    has_ev  <- nrow(ev) > 0L && "task_id" %in% names(ev)
    out <- vector("list", length(task_ids)); names(out) <- task_ids
    for (tid in task_ids) {
        state <- cov$processing_state[cov$task_id == tid]
        state <- if (length(state)) state[[1]] else "no_eligible_source"
        av <- if (has_val) val$accepted_value[val$task_id == tid] else character()
        av <- if (length(av)) av[[1]] else NA_character_
        sh <- .channel_status_from_state(
            state, av, no_candidate_status = no_candidate_status)
        tev <- if (has_ev) ev[ev$task_id == tid, , drop = FALSE] else ev[0, ]
        ids <- if (id_col %in% names(tev)) as.character(tev[[id_col]]) else character()
        out[[tid]] <- list(status = sh$status, hit = sh$hit,
                           evidence = tibble::tibble(source_row_id = unique(ids)))
    }
    out
}
