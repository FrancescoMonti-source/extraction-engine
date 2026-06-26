# =============================================================================
# multisource.R — experimental cross-source derivation contract
# -----------------------------------------------------------------------------
# This is deliberately not a concept_spec / variable_spec framework. It tests
# the smallest runtime seam required by a study variable that accepts evidence
# from several sources.
# =============================================================================

suppressWarnings(suppressMessages(library(dplyr)))

combine_any_source_hit <- function(source_results, incomplete_value) {
    if (missing(incomplete_value) || length(incomplete_value) != 1L) {
        stop("incomplete_value must be an explicit scalar", call. = FALSE)
    }
    if (!is.list(source_results) || !length(source_results)) {
        stop("source_results must be a non-empty named list", call. = FALSE)
    }

    sources <- names(source_results)
    if (is.null(sources) || anyNA(sources) || any(!nzchar(sources)) ||
        anyDuplicated(sources)) {
        stop("source_results must have unique non-empty source names",
             call. = FALSE)
    }

    allowed_status <- c("complete", "unavailable", "invalid", "error")
    source_status <- vector("list", length(source_results))
    positive_evidence <- list()

    for (i in seq_along(source_results)) {
        source <- sources[[i]]
        result <- source_results[[i]]
        required <- c("status", "hit", "evidence")
        missing_fields <- setdiff(required, names(result))
        if (length(missing_fields)) {
            stop(
                source, " result requires: ",
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
            stop(source, " has an unknown source status", call. = FALSE)
        }
        if (length(hit) != 1L || !is.logical(hit)) {
            stop(source, "$hit must be one logical value", call. = FALSE)
        }
        if (identical(status, "complete") && is.na(hit)) {
            stop(source, " complete result requires TRUE or FALSE hit",
                 call. = FALSE)
        }
        if (!identical(status, "complete") && isTRUE(hit)) {
            stop(source, " cannot report a positive hit unless complete",
                 call. = FALSE)
        }
        if (!"source_row_id" %in% names(evidence)) {
            stop(source, "$evidence requires source_row_id", call. = FALSE)
        }
        evidence$source_row_id <- as.character(evidence$source_row_id)
        if (anyNA(evidence$source_row_id) ||
            any(!nzchar(evidence$source_row_id)) ||
            anyDuplicated(evidence$source_row_id)) {
            stop(source, " evidence IDs must be non-missing and unique",
                 call. = FALSE)
        }
        if (isTRUE(hit) && !nrow(evidence)) {
            stop(source, " positive hit requires evidence", call. = FALSE)
        }

        source_status[[i]] <- tibble::tibble(
            source = source,
            status = status,
            hit = hit,
            error = error)

        if (isTRUE(hit)) {
            positive_evidence[[length(positive_evidence) + 1L]] <- evidence %>%
                mutate(source = source, .before = 1L)
        }
    }

    source_status <- bind_rows(source_status)
    any_positive <- any(source_status$hit %in% TRUE)
    all_complete <- all(source_status$status == "complete")

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
        source_status = source_status,
        evidence = if (length(positive_evidence)) {
            bind_rows(positive_evidence)
        } else {
            tibble::tibble(source = character(), source_row_id = character())
        })
}

# =============================================================================
# Per-source reduction to the {status, hit, evidence} contract that
# combine_any_source_hit() consumes (via run_variable()'s any_positive path).
#
# The pre-spine diabetes multi-source orchestration helpers
# (measure_diabetes_glucose / reduce_structured_source / reduce_text_source /
# combine_diabetes_any) were removed once run_variable() subsumed them; the OR-combine
# is now driven by variable_spec activations + combine = any_positive() and exercised
# at the spine level (see test-slice-diabetes-spec.R, test-slice-dialysis-spec.R).
# =============================================================================

# Map an engine processing_state (text OR structured vocabulary) + the source's
# accepted value into the {status, hit} the combiner expects. These mappings are
# RECIPE decisions, surfaced deliberately rather than hidden:
#   - no_candidate                          -> caller-selected complete/unavailable
#   - no data for the subject at all        -> UNAVAILABLE (neither + nor -; partial)
#   - rows present but unusable             -> INVALID (not a negative)
#   - model/processing failure              -> ERROR
.source_status_from_state <- function(
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

# Reduce one source's full result (the engine's coverage/values/evidence views) to
# a per-task {status, hit, evidence} list keyed by task_id. `id_col` is the durable
# row key in that source's evidence: source_row_id (structured) or hit_ref (text).
.reduce_source <- function(
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
        sh <- .source_status_from_state(
            state, av, no_candidate_status = no_candidate_status)
        tev <- if (has_ev) ev[ev$task_id == tid, , drop = FALSE] else ev[0, ]
        ids <- if (id_col %in% names(tev)) as.character(tev[[id_col]]) else character()
        out[[tid]] <- list(status = sh$status, hit = sh$hit,
                           evidence = tibble::tibble(source_row_id = unique(ids)))
    }
    out
}
