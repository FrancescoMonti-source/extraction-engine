# =============================================================================
# extract.R — reusable structured extraction core (integrated baseline)
# -----------------------------------------------------------------------------
# Generic plumbing only. A study author supplies a prompt with llm_task(); the
# engine compiles the declared output into the runtime schema, prompt envelope,
# result adapter, evidence checks, and provenance records.
# =============================================================================

# Public authoring surface: the study owns the detailed instruction. Candidate
# formatting, ellmer types, parsing, and evidence materialization are engine work.
llm_task <- function(prompt) {
    if (!is.character(prompt) || length(prompt) != 1L || is.na(prompt) ||
        !nzchar(trimws(prompt))) {
        stop("llm_task() requires one non-empty prompt.", call. = FALSE)
    }
    structure(list(prompt = prompt), class = c("ee_llm_task", "list"))
}

# Private runtime bundle retained for the executor and older internal recipes.
# It is deliberately not exported: ordinary variable specs never write these
# functions themselves.
.llm_definition <- function(name, system_prompt, type_builder, prompt_builder,
                            parser, summary_field = NULL,
                            summary_required = FALSE) {
    if (!is.character(name) || length(name) != 1L || !nzchar(name) ||
        !is.character(system_prompt) || length(system_prompt) != 1L ||
        !nzchar(system_prompt)) {
        stop("Internal LLM definitions require non-empty name and system_prompt.",
             call. = FALSE)
    }
    for (value in list(type_builder = type_builder,
                       prompt_builder = prompt_builder, parser = parser)) {
        if (!is.function(value)) {
            stop("type_builder, prompt_builder, and parser must be functions.",
                 call. = FALSE)
        }
    }
    if (!is.logical(summary_required) || length(summary_required) != 1L ||
        is.na(summary_required)) {
        stop("summary_required must be TRUE or FALSE.", call. = FALSE)
    }
    structure(
        list(name = name, system_prompt = system_prompt,
             type_builder = type_builder, prompt_builder = prompt_builder,
             parser = parser, summary_field = summary_field,
             summary_required = summary_required),
        class = c("ee_llm_definition", "list"))
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

# Shared citation resolution. Only IDs actually supplied to the model may
# materialize as evidence; unexpected IDs remain visible as an execution warning.
resolve_cited_ids <- function(evidence_ids, snippet_ids) {
    returned <- unique(as.character(unlist(evidence_ids)))
    returned <- returned[!is.na(returned) & nzchar(returned)]
    invented <- setdiff(returned, snippet_ids)
    list(
        real_ids = intersect(returned, snippet_ids),
        invented_ids = invented,
        citation_warning = length(invented) > 0L,
        citation_warning_reason = if (length(invented))
            "model cited >=1 unsupplied snippet id"
            else NA_character_)
}

# Compile the ordinary prompt-only task against the variable's categorical
# output. The value enum comes from cat_output(); the evidence enum is rebuilt for
# each task from the snippet IDs that the model actually receives.
.compile_llm_task <- function(task, variable) {
    if (inherits(task, "ee_llm_definition")) {
        .check_llm_definition(task)
        return(task)
    }
    .check_llm_task(task)
    output <- variable$output
    if (is.null(output) || !identical(output$kind, "categorical") ||
        is.function(output$reduce)) {
        stop("llm_task(prompt = ...) currently requires cat_output(levels) ",
             "without a payload reducer.", call. = FALSE)
    }

    levels <- output$levels
    field <- variable$name
    authored_prompt <- task$prompt

    .llm_definition(
        name = variable$name,
        system_prompt = paste(
            "You are a structured information extraction assistant.",
            "Use only the supplied excerpts and return the requested structure."),
        type_builder = function(snippet_ids) {
            ellmer::type_object(
                value = ellmer::type_enum(levels),
                evidence_ids = ellmer::type_array(
                    ellmer::type_enum(snippet_ids)))
        },
        prompt_builder = function(task_row, candidates) {
            paste(
                authored_prompt,
                "",
                "Extraits numerotes :",
                format_snippet_block(candidates),
                sep = "\n")
        },
        parser = function(result, snippet_ids) {
            value <- if (!is.null(result$value) && length(result$value) == 1L) {
                as.character(result$value)
            } else {
                NA_character_
            }
            cited <- if (is.null(result$evidence_ids)) {
                character()
            } else {
                result$evidence_ids
            }
            citations <- resolve_cited_ids(cited, snippet_ids)
            valid <- !is.na(value) && value %in% levels
            fields <- tibble::tibble(
                field = field,
                status = if (valid) "extracted" else "invalid",
                normalized_value = if (valid) value else NA_character_,
                evidence_ids = list(citations$real_ids),
                field_validity = if (valid) "valid" else "invalid",
                validity_reason = if (valid) "" else
                    "value does not match the declared categorical output",
                citation_warning = citations$citation_warning,
                citation_warning_reason = citations$citation_warning_reason)
            list(fields = fields, summary = NA_character_)
        })
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
    .llm_definition(
        name = name,
        system_prompt = system_prompt,
        type_builder = function(ids) {
            schema <- list(
                type = "object",
                additionalProperties = FALSE,
                required = as.list(c(status_key, "evidence_ids")),
                properties = stats::setNames(
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

APPROVED_MODELS <- c("gemma3:4b")

# A variable owns its model choice; the engine owns transport construction.
# Kept behind a tiny seam so package tests can verify orchestration without
# starting a real Ollama request.
.create_ollama_chat <- function(model, params) {
    ellmer::chat_ollama(model = model, params = params)
}

.variable_needs_chat <- function(variable) {
    any(vapply(variable$channels, function(channel) {
        identical(channel$type, "text")
    }, logical(1)))
}

.resolve_variable_chat <- function(variable, chat) {
    if (!is.null(chat) || !.variable_needs_chat(variable)) return(chat)
    if (is.null(variable$model)) {
        stop("Text variable '", variable$name,
             "' must declare model = <Ollama model> in variable_spec() ",
             "or receive chat = <ellmer Chat> in run_variable().",
             call. = FALSE)
    }
    .create_ollama_chat(variable$model, variable$model_params)
}

.chat_metadata <- function(chat) {
    if (is.null(chat)) {
        return(list(provider = NA_character_, model = NA_character_, params = list(),
                    temperature = NA_real_, seed = NA_integer_,
                    max_tokens = NA_real_))
    }
    if (!inherits(chat, "Chat") || !is.function(chat$chat_structured) ||
        !is.function(chat$clone) || !is.function(chat$get_provider)) {
        stop("chat must be an ellmer Chat object.", call. = FALSE)
    }
    provider <- chat$get_provider()
    params <- tryCatch(provider@params, error = function(...) list())
    if (is.null(params)) params <- list()
    model <- as.character(chat$get_model())
    if (length(model) != 1L || is.na(model) || !nzchar(model)) {
        stop("The ellmer Chat must expose one non-empty model name.",
             call. = FALSE)
    }
    scalar_num <- function(name) {
        value <- params[[name]]
        if (is.null(value) || length(value) != 1L) NA_real_ else as.numeric(value)
    }
    list(
        provider = tryCatch(as.character(provider@name),
                            error = function(...) NA_character_),
        model = model,
        params = params,
        temperature = scalar_num("temperature"),
        seed = as.integer(scalar_num("seed")),
        max_tokens = scalar_num("max_tokens"))
}

.require_gated_chat <- function(metadata) {
    if (identical(tolower(metadata$provider), "test")) return(invisible(TRUE))
    if (!metadata$model %in% APPROVED_MODELS &&
        !nzchar(Sys.getenv("ALLOW_UNGATED_MODEL"))) {
        stop("Model '", metadata$model,
             "' has not passed the structured-output grammar gate. Approved: ",
             paste(APPROVED_MODELS, collapse = ", "),
             ". Set ALLOW_UNGATED_MODEL=1 to override.", call. = FALSE)
    }
    invisible(TRUE)
}

.chat_partial_response <- function(chat) {
    if (is.null(chat)) return(NA_character_)
    tryCatch(
        paste(vapply(chat$last_turn()@contents,
                     function(content) tryCatch(content@string,
                                                  error = function(...) ""),
                     character(1)), collapse = ""),
        error = function(...) NA_character_)
}

.chat_output_tokens <- function(chat) {
    if (is.null(chat)) return(NA_real_)
    tryCatch({
        tokens <- utils::tail(chat$get_tokens(), 1L)
        if (nrow(tokens)) as.numeric(tokens$output[[1]]) else NA_real_
    }, error = function(...) NA_real_)
}

.condition_value <- function(error, name, default) {
    value <- tryCatch(error[[name]], error = function(...) NULL)
    if (is.null(value) || length(value) != 1L) default else value
}

.call_chat <- function(chat, prompt, type, system_prompt, metadata) {
    started <- Sys.time()
    task_chat <- NULL
    out <- tryCatch({
        task_chat <- chat$clone(deep = TRUE)
        task_chat$set_turns(list())
        task_chat$set_system_prompt(system_prompt)
        list(status = "completed",
             result = task_chat$chat_structured(prompt, type = type),
             error = NA_character_)
    }, error = function(error) {
        output_tokens <- as.numeric(.condition_value(
            error, "output_tokens", .chat_output_tokens(task_chat)))
        finish_reason <- as.character(.condition_value(
            error, "inferred_finish_reason", NA_character_))
        if (is.na(finish_reason) && !is.na(output_tokens) &&
            !is.na(metadata$max_tokens) && output_tokens >= metadata$max_tokens) {
            finish_reason <- "length"
        }
        list(
            status = "error", result = NULL, error = conditionMessage(error),
            partial_response = as.character(.condition_value(
                error, "partial_response", .chat_partial_response(task_chat))),
            output_tokens = output_tokens,
            inferred_finish_reason = finish_reason)
    })
    out$n_tries <- 1L
    out$errors <- if (identical(out$status, "error")) out$error else character()
    out$started_at <- started
    out$latency_ms <- as.numeric(difftime(Sys.time(), started, units = "secs")) * 1000
    if (is.null(out$partial_response)) out$partial_response <- NA_character_
    if (is.null(out$output_tokens)) out$output_tokens <- NA_real_
    if (is.null(out$inferred_finish_reason)) {
        out$inferred_finish_reason <- NA_character_
    }
    out
}

.select_task_candidates <- function(selector, rows, task_id) {
    selected <- selector(rows)
    if (!is.data.frame(selected) || !all(c("task_id", "snippet_id") %in% names(selected))) {
        stop("Post-Lucene candidate selection must return candidate rows.",
             call. = FALSE)
    }
    if (!nrow(selected)) {
        stop("Post-Lucene candidate selection kept no row for the current task.",
             call. = FALSE)
    }
    ids <- as.character(selected$snippet_id)
    if (anyNA(ids) || anyDuplicated(ids)) {
        stop("Post-Lucene candidate selection returned missing or duplicate snippet ids.",
             call. = FALSE)
    }
    index <- match(ids, as.character(rows$snippet_id))
    if (anyNA(index) || any(as.character(selected$task_id) != task_id)) {
        stop("Post-Lucene candidate selection may only select/reorder supplied rows.",
             call. = FALSE)
    }
    rows[index, , drop = FALSE]
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

run_extraction <- function(coverage, candidates, definition, chat,
                           candidate_selector, query = NA_character_,
                           sample_n = 0L) {
    .check_llm_definition(definition)
    if (!is.function(candidate_selector)) {
        stop("candidate_selector must be a function.", call. = FALSE)
    }
    metadata <- .chat_metadata(chat)
    .require_gated_chat(metadata)
    task_ids <- coverage$task_id[coverage$coverage_state == "candidate"]
    if (sample_n > 0L) task_ids <- utils::head(task_ids, sample_n)

    query_hash <- substr(rlang::hash(query), 1L, 12L)   # audit: retrieval-query fingerprint
    values_l <- list(); evidence_l <- list(); attempts_l <- list()
    selected_l <- list()

    for (tid in task_ids) {
        ts <- candidates[candidates$task_id == tid, , drop = FALSE]
        ts <- .select_task_candidates(candidate_selector, ts, tid)
        ts$model_candidate_rank <- seq_len(nrow(ts))
        selected_l[[length(selected_l) + 1L]] <- ts
        task_row <- coverage[coverage$task_id == tid, , drop = FALSE]
        prompt <- definition$prompt_builder(task_row, ts)
        type   <- definition$type_builder(ts$snippet_id)
        call <- .call_chat(chat, prompt, type, definition$system_prompt, metadata)
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
                f$model <- metadata$model
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
            task_id = tid, provider = metadata$provider, model = metadata$model,
            temperature = metadata$temperature, seed = metadata$seed,
            max_tokens = metadata$max_tokens, params = list(metadata$params),
            definition = definition$name, attempt_status = call$status,
            processing_status = proc, n_tries = call$n_tries,
            started_at = call$started_at, latency_ms = round(call$latency_ms),
            prompt_hash = prompt_hash, schema_hash = schema_hash, query_hash = query_hash,
            task_validity = tvalid, error = ifelse(nzchar(err), err, NA_character_),
            output_tokens = call$output_tokens,
            inferred_finish_reason = call$inferred_finish_reason,
            partial_response = call$partial_response,
            raw_response = list(if (identical(call$status, "completed")) call$result else NULL))
    }

    values   <- if (length(values_l))   bind_rows(values_l)   else tibble::tibble()
    evidence <- if (length(evidence_l)) bind_rows(evidence_l) else tibble::tibble()
    model_candidates <- if (length(selected_l)) bind_rows(selected_l) else candidates[0, ]
    attempts <- if (length(attempts_l)) bind_rows(attempts_l) else tibble::tibble(
        task_id = character(), provider = character(), model = character(),
        temperature = double(), seed = integer(), max_tokens = double(), params = list(),
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
         attempts = attempts, candidates = candidates,
         model_candidates = model_candidates)
}
