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
