# =============================================================================
# concepts-dialysis.R -- dialysis: multi-source OR with TRANSPARENT contribution
# -----------------------------------------------------------------------------
# This slice is NOT about reconcile/precedence/corroboration. It is the same
# multi-source OR shape as diabetes (combine = any_positive), used to make SOURCE
# CONTRIBUTION transparent: which channel(s) carried the signal, which were silent
# and WHY (no_candidate vs no rows for the subject vs no source), evidence refs for
# the positive channel(s), and the researcher-selected combine rule. The engine
# does not estimate clinical certainty; it exposes contribution so the researcher
# sees, e.g., that the final `1` came only from ICD-10 while documents were silent.
#
# Reconcile/precedence is deferred until a real protocol requires it.
# =============================================================================

# Minimal binary documented-presence text definition (mirrors
# diabetes_text_definition in multisource.R). Temporary adapter; the duplication of
# these two now justifies a later generic binary-presence text definition.
dialysis_text_definition <- function() {
    parser <- function(result, snippet_ids) {
        status <- if (length(result$dialysis_status) == 1L)
            as.character(result$dialysis_status) else NA_character_
        returned <- unique(as.character(unlist(result$evidence_ids)))
        ids <- intersect(returned[!is.na(returned) & nzchar(returned)], snippet_ids)
        nv <- dplyr::case_when(identical(status, "documented") ~ "present",
                               identical(status, "not_documented") ~ "absent",
                               TRUE ~ NA_character_)
        v <- standard_field_validity(status, nv, ids)
        fields <- tibble::tibble(
            field = "dialysis_mention", status = status, normalized_value = nv,
            evidence_ids = list(ids), field_validity = v$field_validity,
            validity_reason = v$validity_reason)
        list(fields = fields, summary = NA_character_)
    }
    new_task_definition(
        name = "dialysis_text",
        system_prompt = paste(
            "Identify only explicitly documented chronic dialysis in the snippets.",
            "Do not infer absence from silence."),
        type_builder = function(ids) {
            schema <- list(
                type = "object", additionalProperties = FALSE,
                required = as.list(c("dialysis_status", "evidence_ids")),
                properties = list(
                    dialysis_status = list(
                        type = "string",
                        enum = as.list(c("documented", "not_documented"))),
                    evidence_ids = list(
                        type = "array", maxItems = 5L,
                        items = list(type = "string", enum = as.list(ids)))))
            ellmer::type_from_schema(
                text = jsonlite::toJSON(schema, auto_unbox = TRUE))
        },
        prompt_builder = function(task, cands) {
            paste(paste0("Input row: ", task$task_id[[1]]),
                  "Snippets:", format_snippet_block(cands), sep = "\n")
        },
        parser = parser, summary_field = NULL, summary_required = FALSE)
}

# Z99.2 (dialysis dependence) / N18.6 (ESRD) are synthetic code vehicles here, not a
# validated dialysis-ascertainment definition.
dialysis_concept_spec <- function() {
    concept_spec(
        name = "dialysis",
        channels = list(
            pmsi_diag_dialysis = code_channel(
                source = "pmsi_diag",
                selector = icd10(c("Z992", "N186")),
                native_grain = "diagnosis_row",
                required_roles = c("subject", "event", "interval_start",
                                   "interval_end", "code", "native_ref"),
                linkage = "subject"),
            text_dialysis_mentions = text_channel(
                source = "documents",
                selector = lucene_query("dialyse OR hemodialyse OR epuration"),
                native_grain = "document_sentence",
                required_roles = c("subject", "event", "date", "text",
                                   "native_ref"),
                linkage = "subject")))
}

# Multi-source OR baseline. "Documented status" answer schema lives at the
# activation (text_extractor); combine is the researcher's explicit any_positive().
dialysis_status_template <- function(concept = dialysis_concept_spec()) {
    variable_template(
        name = "dialysis_status_template",
        concept = concept,
        defaults = list(
            window = before_anchor(days = 3650L, grace_days = 7L),
            channels = c("pmsi_diag_dialysis", "text_dialysis_mentions"),
            text_method = llm_after_lucene(),
            text_extractor = dialysis_text_definition(),
            output = binary_output(),
            combine = any_positive(),
            absence_policy = open_world()),
        build = function(params) {
            variable_spec(
                name = params$name,
                concept = concept,
                unit = params$unit,
                anchor = params$anchor,
                window = params$window,
                channels = .activate_channels(
                    concept, params$channels,
                    text_method = params$text_method,
                    text_extractor = params$text_extractor),
                output = params$output,
                combine = params$combine,
                absence_policy = params$absence_policy,
                template_name = params$template_name)
        })
}
