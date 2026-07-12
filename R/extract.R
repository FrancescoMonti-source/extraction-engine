# =============================================================================
# extract.R — reusable structured extraction core (integrated baseline)
# -----------------------------------------------------------------------------
# Generic plumbing only. Each variable supplies a `definition` bundle whose
# parser OWNS its validity rules (so e.g. smoking `indetermine` may abstain with
# no evidence, which a single generic validator would wrongly reject). The core
# does: classified-retry calls, PER-TASK error isolation (one bad task never
# aborts the batch), FIELD-LEVEL acceptance gating, evidence materialization with
# the provenance assertion, the four views, and a generic physician review view.
# =============================================================================

# A task definition bundles everything variable-specific.
# parser(result, snippet_ids) must return:
#   list(fields = tibble(field, status, normalized_value, evidence_ids (list-col),
#                        field_validity in {"valid","invalid"}, validity_reason),
#        summary = scalar character or NA)
new_task_definition <- function(name, system_prompt, type_builder, prompt_builder,
                                parser, summary_field = NULL, summary_required = FALSE) {
    list(name = name, system_prompt = system_prompt, type_builder = type_builder,
         prompt_builder = prompt_builder, parser = parser,
         summary_field = summary_field, summary_required = summary_required)
}

scalar_present <- function(x) {
    !is.null(x) && length(x) == 1L && !is.na(x) && nzchar(trimws(as.character(x)))
}

# Numbered snippet block shown to the model: "S001: <snippet_text>".
format_snippet_block <- function(task_snippets) {
    paste(sprintf("%s: %s", task_snippets$snippet_id, task_snippets$snippet_text),
          collapse = "\n\n")
}

# Shared helper parsers may call for the standard {documented/not_documented/
# unusable} shape. Smoking deliberately does NOT use this (its enum abstains).
standard_field_validity <- function(status, normalized_value, evidence_ids) {
    ids <- evidence_ids[!is.na(evidence_ids) & nzchar(evidence_ids)]
    reason <- character()
    if (!status %in% c("documented", "not_documented", "unusable")) {
        reason <- c(reason, "invalid status")
    } else if (identical(status, "documented") &&
               (!scalar_present(normalized_value) || !length(ids))) {
        reason <- c(reason, "documented without value or evidence")
    } else if (identical(status, "unusable") && !length(ids)) {
        reason <- c(reason, "unusable without evidence")
    }
    list(field_validity = if (length(reason)) "invalid" else "valid",
         validity_reason = paste(reason, collapse = "; "))
}

# Shared citation resolution for ALL text parsers (D1 keep-and-flag, owner-ratified).
# Splits the model's returned evidence ids into those actually supplied (`real_ids` --
# the only ids that can ground a value or materialize as evidence) and those that were
# never supplied (`invented_ids`, i.e. hallucinated). An invented citation does NOT
# invalidate a value already grounded by >=1 real id; it is surfaced as a structured
# `citation_warning` so the researcher sees it -- rather than the value being silently
# dropped (binary-presence) or wrongly failed closed (anastomoses, pre-#3). A value
# grounded ONLY by invented ids has no real grounding and is rejected by each parser's
# OWN evidence rule (`real_ids` is empty there). Invented ids never materialize as
# evidence: .materialize_task_evidence joins on the supplied snippet ids only.
resolve_cited_ids <- function(evidence_ids, snippet_ids) {
    returned <- unique(as.character(unlist(evidence_ids)))
    returned <- returned[!is.na(returned) & nzchar(returned)]
    invented <- setdiff(returned, snippet_ids)
    list(
        real_ids = intersect(returned, snippet_ids),
        invented_ids = invented,
        citation_warning = length(invented) > 0L,
        citation_warning_reason = if (length(invented))
            "model cited >=1 unsupplied snippet id (value kept, flagged)"
            else NA_character_)
}

# Shared binary documented-presence text definition: one evidenced field whose
# model output is {documented, not_documented}, normalized to present/absent.
# Concept-specific text definitions (diabetes, dialysis, ...) are thin wrappers
# that supply only the model's status key, the engine field name, and the
# concept-specific system prompt. This factors the schema + parser pattern without
# adding any new semantics: behaviour is identical to the hand-written definitions.
binary_presence_text_definition <- function(name, status_key, field, system_prompt,
                                            evidence_max_items = 5L) {
    parser <- function(result, snippet_ids) {
        status <- if (length(result[[status_key]]) == 1L)
            as.character(result[[status_key]]) else NA_character_
        cite <- resolve_cited_ids(result$evidence_ids, snippet_ids)
        ids <- cite$real_ids
        nv <- dplyr::case_when(identical(status, "documented") ~ "present",
                               identical(status, "not_documented") ~ "absent",
                               TRUE ~ NA_character_)
        v <- standard_field_validity(status, nv, ids)
        # D1 keep-and-flag (owner-ratified): an invented citation is surfaced via
        # citation_warning, not silently dropped. A value grounded only by invented
        # ids has empty real ids, so standard_field_validity already rejects it.
        fields <- tibble::tibble(
            field = field, status = status, normalized_value = nv,
            evidence_ids = list(ids), field_validity = v$field_validity,
            validity_reason = v$validity_reason,
            citation_warning = cite$citation_warning,
            citation_warning_reason = cite$citation_warning_reason)
        list(fields = fields, summary = NA_character_)
    }
    new_task_definition(
        name = name,
        system_prompt = system_prompt,
        type_builder = function(ids) {
            schema <- list(
                type = "object",
                additionalProperties = FALSE,
                required = as.list(c(status_key, "evidence_ids")),
                properties = setNames(
                    list(
                        list(type = "string",
                             enum = as.list(c("documented", "not_documented"))),
                        list(type = "array",
                             maxItems = evidence_max_items,
                             items = list(type = "string", enum = as.list(ids)))),
                    c(status_key, "evidence_ids")))
            ellmer::type_from_schema(
                text = jsonlite::toJSON(schema, auto_unbox = TRUE))
        },
        prompt_builder = function(task, cands) {
            paste(
                paste0("Input row: ", task$task_id[[1]]),
                "Snippets:",
                format_snippet_block(cands),
                sep = "\n")
        },
        parser = parser, summary_field = NULL, summary_required = FALSE)
}

make_ollama_caller <- function(model = "gemma3:4b", seed = 20260621L, max_tokens = 1024L) {
    force(model); force(seed); force(max_tokens)
    function(prompt, type, system_prompt) {
        chat <- ellmer::chat_ollama(
            model = model, system_prompt = system_prompt,
            params = ellmer::params(temperature = 0, seed = seed, max_tokens = max_tokens),
            echo = "none")
        tryCatch(
            chat$chat_structured(prompt, type = type),
            error = function(e) {
                # The error itself carries no body, but the chat retains the partial
                # output; capture it here (chat is local) so a truncation is
                # diagnosable from artifacts. output >= max_tokens => length-truncation.
                partial <- tryCatch(
                    paste(vapply(chat$last_turn()@contents,
                                 function(co) tryCatch(co@string, error = function(...) ""),
                                 character(1)), collapse = ""),
                    error = function(...) NA_character_)
                out_tok <- tryCatch({
                    tk <- utils::tail(chat$get_tokens(), 1L)
                    if (nrow(tk)) as.numeric(tk$output[[1]]) else NA_real_
                }, error = function(...) NA_real_)
                rlang::abort(
                    conditionMessage(e), class = "engine_call_error", parent = e,
                    partial_response = partial, output_tokens = out_tok,
                    inferred_finish_reason =
                        if (!is.na(out_tok) && out_tok >= max_tokens) "length" else NA_character_)
            })
    }
}

# Retry only TRANSIENT provider failures (crash/timeout/connection). Permanent
# errors (schema/parse/config) are deterministic under temp=0+seed -> no retry.
# NB: a "premature EOF" is a deterministic truncated-JSON / max-token failure, not
# a transport disconnect, so it is deliberately NOT treated as transient.
.is_transient <- function(msg) {
    grepl("HTTP 5|timeout|timed out|connection|terminated|CUDA|reset|socket",
          msg, ignore.case = TRUE)
}

call_with_retry <- function(caller, prompt, type, system_prompt, max_tries = 3L) {
    started <- Sys.time(); errors <- character(); out <- NULL
    for (k in seq_len(max_tries)) {
        out <- tryCatch(
            list(status = "completed", result = caller(prompt, type, system_prompt),
                 error = NA_character_, n_tries = k),
            error = function(e) list(status = "error", result = NULL,
                                     error = conditionMessage(e), n_tries = k,
                                     partial_response = e$partial_response,
                                     output_tokens = e$output_tokens,
                                     inferred_finish_reason = e$inferred_finish_reason))
        if (identical(out$status, "completed")) break
        errors <- c(errors, out$error)
        if (k < max_tries && .is_transient(out$error)) Sys.sleep(min(5L * k, 15L)) else break
    }
    out$errors <- errors
    out$started_at <- started
    out$latency_ms <- as.numeric(difftime(Sys.time(), started, units = "secs")) * 1000
    # observability fields are absent on completed calls and plain-stop fakes
    if (is.null(out$partial_response)) out$partial_response <- NA_character_
    if (is.null(out$output_tokens))   out$output_tokens   <- NA_real_
    if (is.null(out$inferred_finish_reason)) {
        out$inferred_finish_reason <- NA_character_
    }
    out
}

# Materialize one task's evidence; asserts every cited ID resolves to exactly one
# snippet (caught per-task by the caller, so a failure never aborts the batch).
.materialize_task_evidence <- function(fields, task_snippets, summary_field) {
    links <- fields %>% select(field, evidence_ids) %>%
        tidyr::unnest_longer(evidence_ids, values_to = "snippet_id", keep_empty = FALSE) %>%
        distinct(field, snippet_id)
    if (!nrow(links)) return(tibble::tibble())
    ev <- links %>% left_join(task_snippets, by = "snippet_id")
    if (nrow(ev) != nrow(links) || anyNA(ev$hit_ref)) {
        stop("evidence ID does not resolve to exactly one snippet", call. = FALSE)
    }
    if (!is.null(summary_field)) {
        ev <- bind_rows(ev, ev %>% distinct(snippet_id, .keep_all = TRUE) %>%
                                mutate(field = summary_field))
    }
    ev %>% select(any_of(c("field", "snippet_id", "hit_ref", "ELTID", "EVTID",
                           "sentence", "hit_text", "snippet_text", "RECDATE",
                           "RECTYPE")))
}

run_extraction <- function(coverage, candidates, definition, caller, model_name,
                           provider = "local", seed = NA_integer_, query = NA_character_,
                           sample_n = 0L, max_tries = 3L) {
    task_ids <- coverage$task_id[coverage$coverage_state == "candidate"]
    if (sample_n > 0L) task_ids <- head(task_ids, sample_n)

    query_hash <- substr(rlang::hash(query), 1L, 12L)   # audit: retrieval-query fingerprint
    values_l <- list(); evidence_l <- list(); attempts_l <- list()

    for (tid in task_ids) {
        ts <- candidates[candidates$task_id == tid, , drop = FALSE]
        task_row <- coverage[coverage$task_id == tid, , drop = FALSE]
        prompt <- definition$prompt_builder(task_row, ts)
        type   <- definition$type_builder(ts$snippet_id)
        call <- call_with_retry(caller, prompt, type, definition$system_prompt, max_tries)
        prompt_hash <- substr(rlang::hash(prompt), 1L, 12L)
        schema_hash <- substr(rlang::hash(type), 1L, 12L)
        proc <- NA_character_; tvalid <- NA_character_; err <- paste(call$errors, collapse = " || ")

        if (identical(call$status, "completed")) {
            res <- tryCatch({
                parsed <- definition$parser(call$result, ts$snippet_id)
                f <- parsed$fields
                summary_ok <- !isTRUE(definition$summary_required) || scalar_present(parsed$summary)
                tv <- if (all(f$field_validity == "valid") && summary_ok) "valid" else "invalid"
                treason <- paste(unique(c(
                    f$validity_reason[f$field_validity == "invalid"],
                    if (!summary_ok) "required summary missing")), collapse = " | ")
                # FIELD-LEVEL acceptance: a valid grounded field is accepted even if a
                # sibling field is invalid.
                f$accepted_value <- ifelse(f$field_validity == "valid", f$normalized_value, NA_character_)
                f$task_id <- tid; f$task_validity <- tv; f$task_validity_reason <- treason
                f$task_summary <- if (scalar_present(parsed$summary)) as.character(parsed$summary[[1]]) else NA_character_
                f$model <- model_name
                ev <- .materialize_task_evidence(f, ts, definition$summary_field)
                if (nrow(ev)) ev$task_id <- tid
                list(values = f, evidence = ev, task_validity = tv)
            }, error = function(e) list(error = conditionMessage(e)))

            if (is.null(res$error)) {
                proc <- "processed"; tvalid <- res$task_validity
                values_l[[length(values_l) + 1L]] <- res$values
                if (nrow(res$evidence)) evidence_l[[length(evidence_l) + 1L]] <- res$evidence
            } else {
                proc <- "processing_error"
                err <- paste(c(err, res$error), collapse = " || ")
            }
        }

        attempts_l[[length(attempts_l) + 1L]] <- tibble::tibble(
            task_id = tid, provider = provider, model = model_name, seed = seed,
            definition = definition$name, attempt_status = call$status,
            processing_status = proc, n_tries = call$n_tries,
            started_at = call$started_at, latency_ms = round(call$latency_ms),
            prompt_hash = prompt_hash, schema_hash = schema_hash, query_hash = query_hash,
            task_validity = tvalid, error = ifelse(nzchar(err), err, NA_character_),
            output_tokens = call$output_tokens,
            inferred_finish_reason = call$inferred_finish_reason,
            partial_response = call$partial_response,   # PHI-ish: run.rds only, not the workbook
            raw_response = list(if (identical(call$status, "completed")) call$result else NULL))
    }

    values   <- if (length(values_l))   bind_rows(values_l)   else tibble::tibble()
    evidence <- if (length(evidence_l)) bind_rows(evidence_l) else tibble::tibble()
    attempts <- if (length(attempts_l)) bind_rows(attempts_l) else tibble::tibble(
        task_id = character(), provider = character(), model = character(), seed = integer(),
        definition = character(), attempt_status = character(), processing_status = character(),
        n_tries = integer(), started_at = as.POSIXct(character()), latency_ms = double(),
        prompt_hash = character(), schema_hash = character(), query_hash = character(),
        task_validity = character(), error = character(), output_tokens = double(),
        inferred_finish_reason = character(), partial_response = character(),
        raw_response = list())

    final_coverage <- coverage %>%
        left_join(distinct(attempts, task_id, attempt_status, processing_status, task_validity),
                  by = "task_id") %>%
        mutate(processing_state = case_when(
            coverage_state == "no_eligible_document" ~ "no_eligible_document",
            coverage_state == "no_candidate"         ~ "no_candidate",
            is.na(attempt_status)                    ~ "not_called",
            attempt_status == "error"                ~ "model_error",
            processing_status == "processing_error"  ~ "processing_error",
            task_validity == "valid"                 ~ "valid",
            TRUE                                     ~ "invalid")) %>%
        select(-attempt_status, -processing_status, -task_validity)

    list(coverage = final_coverage, values = values, evidence = evidence,
         attempts = attempts, candidates = candidates)
}
