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
# Multi-source diabetes (binary) — SPIKE built on combine_any_source_hit above.
# Diabetes is "present" (1) if ANY selected source has positive evidence:
#   documents (LLM text path) OR pmsi (ICD-10 E10-E14) OR biology (high glucose).
# Each source is run by its OWN existing path, then REDUCED to the per-source
# {status, hit, evidence} contract the combiner consumes. This proves the
# production seam the ba9f171 proof skipped: heterogeneous real source paths
# feeding one OR-combine, scoped relative to a fixed anchor.
# =============================================================================

# Diabetes-defining high glucose over biology: the SAME analyte-threshold recipe
# as hyperkalaemia, different params. This is the 2nd consumer of that recipe, so
# it is the repetition that would justify extracting a generic
# measure_analyte_threshold() (the review's [Med] point). `threshold` here is an
# arbitrary VEHICLE, not a validated clinical glucose cutoff.
measure_diabetes_glucose <- function(biol, tasks, analytes = "GLU.GLU",
                                     threshold = 7.0, from_days = -365L, to_days = 7L) {
    measure_hyperkalaemia(biol, tasks, analytes = analytes, threshold = threshold,
                          from_days = from_days, to_days = to_days)
}

# Minimal diabetes TEXT definition for the documents source (engine plumbing only;
# the clinical prompt/type is out of scope for a seam spike). One evidenced field:
# documented => diabetes mentioned (needs evidence) -> hit; not_documented => none.
# Thin wrapper over the shared binary_presence_text_definition() (R/extract.R);
# behaviour is unchanged.
diabetes_text_definition <- function() {
    binary_presence_text_definition(
        name = "diabetes_text",
        status_key = "diabetes_status",
        field = "diabetes_mention",
        system_prompt = paste(
            "Identify only explicitly documented diabetes in the supplied snippets.",
            "Do not infer absence from silence."))
}

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
    out <- vector("list", length(task_ids)); names(out) <- task_ids
    for (tid in task_ids) {
        state <- cov$processing_state[cov$task_id == tid]
        state <- if (length(state)) state[[1]] else "no_eligible_source"
        av <- val$accepted_value[val$task_id == tid]
        av <- if (length(av)) av[[1]] else NA_character_
        sh <- .source_status_from_state(
            state, av, no_candidate_status = no_candidate_status)
        tev <- ev[ev$task_id == tid, , drop = FALSE]
        ids <- if (id_col %in% names(tev)) as.character(tev[[id_col]]) else character()
        out[[tid]] <- list(status = sh$status, hit = sh$hit,
                           evidence = tibble::tibble(source_row_id = unique(ids)))
    }
    out
}
reduce_structured_source <- function(res, task_ids) {
    .reduce_source(
        res, task_ids, "source_row_id", no_candidate_status = "complete")
}
reduce_text_source <- function(
    res,
    task_ids,
    no_candidate_status = c("unavailable", "complete")) {
    no_candidate_status <- match.arg(no_candidate_status)
    .reduce_source(
        res, task_ids, "hit_ref",
        no_candidate_status = no_candidate_status)
}

# Orchestrate the OR-combine across already-reduced sources, one combine per task.
# Returns the same three-view shape the engine uses elsewhere: per-task value +
# ascertainment, per-source status, and combined positive evidence with provenance.
combine_diabetes_any <- function(tasks, sources, incomplete_value = NA_integer_) {
    task_ids <- as.character(tasks$task_id)
    values <- vector("list", length(task_ids))
    status_l <- vector("list", length(task_ids))
    evidence_l <- list()
    for (i in seq_along(task_ids)) {
        tid <- task_ids[[i]]
        per_source <- lapply(sources, function(src) src[[tid]])
        combined <- combine_any_source_hit(per_source, incomplete_value = incomplete_value)
        values[[i]] <- tibble::tibble(task_id = tid, diabetes_any = combined$value,
                                      ascertainment = combined$ascertainment)
        status_l[[i]] <- mutate(combined$source_status, task_id = tid, .before = 1L)
        if (nrow(combined$evidence)) {
            evidence_l[[length(evidence_l) + 1L]] <-
                mutate(combined$evidence, task_id = tid, .before = 1L)
        }
    }
    list(
        values = bind_rows(values),
        source_status = bind_rows(status_l),
        evidence = if (length(evidence_l)) bind_rows(evidence_l) else
            tibble::tibble(task_id = character(), source = character(),
                           source_row_id = character()))
}
