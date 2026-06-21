# =============================================================================
# extract.R — reusable, variable-agnostic structured extraction (synthesis)
# -----------------------------------------------------------------------------
# Owns the generic plumbing only:
#   - one fresh structured call per task (bounded retry for transient provider
#     failures only; NEVER for structural invalidity, which is deterministic);
#   - evidence materialization snippet_id -> stored provenance, with the
#     provenance-integrity assertion (every cited ID resolves to exactly one
#     snippet);
#   - the four views: coverage / values / evidence / attempts.
#
# Each variable supplies three functions (see R/types/<variable>.R):
#   type_builder(snippet_ids)        -> ellmer type for that task
#   prompt_builder(task, candidates) -> character prompt
#   parse_result(raw, snippet_ids)   -> list(values = 1-row tibble incl.
#                                        task_valid + task_reason + summary,
#                                        evidence = tibble(field, snippet_id))
# The engine never inspects clinical field meanings.
# =============================================================================

suppressWarnings(suppressMessages({
    library(dplyr)
    stopifnot(requireNamespace("ellmer", quietly = TRUE))
}))

# Fresh chat per task; bounded retry only for transient provider failures.
make_ollama_caller <- function(model = "gemma3:4b", system_prompt = NULL,
                               seed = 20260621L) {
    force(model); force(system_prompt); force(seed)
    function(prompt, type) {
        chat <- ellmer::chat_ollama(
            model = model, system_prompt = system_prompt,
            params = ellmer::params(temperature = 0, seed = seed), echo = "none"
        )
        chat$chat_structured(prompt, type = type)
    }
}

.call_with_retry <- function(model_caller, prompt, type, max_try = 3L) {
    out <- NULL
    for (k in seq_len(max_try)) {
        out <- tryCatch(
            list(raw = model_caller(prompt, type), error = NA_character_, tries = k),
            error = function(e) list(raw = NULL, error = conditionMessage(e), tries = k)
        )
        if (is.na(out$error)) break
        Sys.sleep(min(5L * k, 15L))  # let a crashed local server reload
    }
    out
}

# Numbered snippet block shown to the model: "S01: <snippet_text>".
format_snippet_block <- function(candidates_task) {
    paste(sprintf("%s: %s", candidates_task$snippet_id,
                  candidates_task$snippet_text), collapse = "\n\n")
}

# Shared helper for the common evidenced-field shape {status, value, evidence}.
# Returns the authoritative value (NA unless documented), n_refs, validity, reason.
evidenced_field <- function(status, raw_value, evidence_ids, is_integer = FALSE) {
    st <- if (length(status) == 1L) as.character(status) else NA_character_
    ids <- unique(as.character(unlist(evidence_ids)))
    ids <- ids[!is.na(ids) & nzchar(ids)]
    present <- !is.null(raw_value) && length(raw_value) == 1L && !is.na(raw_value)
    # status is authoritative: a value is meaningful only when documented.
    value <- if (identical(st, "documented") && present) {
        if (is_integer) as.integer(raw_value) else trimws(as.character(raw_value))
    } else {
        if (is_integer) NA_integer_ else NA_character_
    }
    has_value <- !is.na(value) && (is_integer || nzchar(value))
    reason <- character()
    if (!st %in% c("documented", "not_documented", "unusable")) {
        reason <- c(reason, "invalid status")
    } else if (identical(st, "documented") && (!has_value || !length(ids))) {
        reason <- c(reason, "documented without value or evidence")
    } else if (identical(st, "unusable") && !length(ids)) {
        reason <- c(reason, "unusable without evidence")
    }
    list(status = st, value = value, evidence_ids = ids,
         n_refs = length(ids), valid = !length(reason),
         reason = paste(reason, collapse = "; "))
}

run_extraction <- function(coverage, candidates, model_caller, model_name,
                           type_builder, prompt_builder, parse_result,
                           sample_n = 0L) {
    task_ids <- coverage$task_id[coverage$coverage_state == "candidate"]
    if (sample_n > 0L) task_ids <- head(task_ids, sample_n)

    values_list <- list(); evidence_list <- list(); attempts_list <- list()

    for (i in seq_along(task_ids)) {
        tid <- task_ids[i]
        cand_t <- candidates[candidates$task_id == tid, , drop = FALSE]
        snippet_ids <- cand_t$snippet_id
        t0 <- Sys.time()
        call <- .call_with_retry(model_caller,
                                 prompt_builder(coverage[coverage$task_id == tid, ], cand_t),
                                 type_builder(snippet_ids))
        lat <- as.numeric(difftime(Sys.time(), t0, units = "secs")) * 1000
        attempt_status <- if (is.na(call$error)) "completed" else "error"
        task_valid <- NA

        if (attempt_status == "completed") {
            parsed <- parse_result(call$raw, snippet_ids)
            vr <- parsed$values
            vr$task_id <- tid; vr$model <- model_name
            values_list[[length(values_list) + 1L]] <- vr
            task_valid <- isTRUE(vr$task_valid)

            ev <- parsed$evidence
            if (nrow(ev)) {
                ev$task_id <- tid
                mat <- inner_join(ev, cand_t, by = c("task_id", "snippet_id"))
                # provenance integrity: every cited ID resolves to exactly one snippet.
                if (nrow(mat) != nrow(ev)) {
                    stop(sprintf("provenance integrity: task %s cited an unresolved/duplicated snippet ID",
                                 tid), call. = FALSE)
                }
                evidence_list[[length(evidence_list) + 1L]] <-
                    mat %>% select(task_id, field, snippet_id, hit_ref, ELTID,
                                   sentence, hit_text, snippet_text, RECDATE, RECTYPE)
            }
        }

        attempts_list[[length(attempts_list) + 1L]] <- tibble::tibble(
            task_id = tid, model = model_name, attempt_status = attempt_status,
            n_tries = call$tries, latency_ms = round(lat),
            task_valid = task_valid, error = call$error
        )
    }

    values   <- if (length(values_list))   bind_rows(values_list)   else tibble::tibble()
    evidence <- if (length(evidence_list)) bind_rows(evidence_list) else tibble::tibble()
    attempts <- if (length(attempts_list)) bind_rows(attempts_list) else tibble::tibble(
        task_id = character(), model = character(), attempt_status = character(),
        n_tries = integer(), latency_ms = double(), task_valid = logical(),
        error = character()
    )

    final_coverage <- coverage %>%
        left_join(select(attempts, task_id, attempt_status, task_valid), by = "task_id") %>%
        mutate(processing_state = case_when(
            coverage_state == "no_candidate"   ~ "no_candidate",
            is.na(attempt_status)              ~ "not_called",
            attempt_status == "error"          ~ "model_error",
            task_valid %in% TRUE               ~ "valid",
            TRUE                               ~ "invalid"
        )) %>%
        select(-attempt_status, -task_valid)

    list(coverage = final_coverage, values = values,
         evidence = evidence, attempts = attempts)
}
