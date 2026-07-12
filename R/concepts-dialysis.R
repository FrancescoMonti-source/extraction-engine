# =============================================================================
# concepts-dialysis.R -- dialysis: multi-source OR with TRANSPARENT contribution
# -----------------------------------------------------------------------------
# This slice is NOT about reconcile/precedence/corroboration. It is the same
# multi-source OR shape as diabetes (combine_channels = any_positive), used to make SOURCE
# CONTRIBUTION transparent: which channel(s) carried the signal, which were silent
# and WHY (no_candidate vs no rows for the subject vs no source), evidence refs for
# the positive channel(s), and the researcher-selected combine rule. The engine
# does not estimate clinical certainty; it exposes contribution so the researcher
# sees, e.g., that the final `1` came only from ICD-10 while documents were silent.
#
# Reconcile/precedence is deferred until a real protocol requires it.
# =============================================================================

# Binary documented-presence dialysis text definition: a thin wrapper over the
# shared binary_presence_text_definition() (R/extract.R). The concept-specific
# parts are only the status key, the engine field name, and the system prompt.
dialysis_text_definition <- function() {
    binary_presence_text_definition(
        name = "dialysis_text",
        status_key = "dialysis_status",
        field = "dialysis_mention",
        system_prompt = paste(
            "Identify only explicitly documented chronic dialysis in the snippets.",
            "Do not infer absence from silence."))
}

# Z99.2 (dialysis dependence) / N18.6 (ESRD) are synthetic code vehicles here, not a
# validated dialysis-ascertainment definition.
dialysis_concept_spec <- function() {
    concept_spec(
        name = "dialysis",
        channels = list(
            pmsi_diag_dialysis = code_channel(
                source = "pmsi_diag",
                selector = icd10(c("Z992", "N186"), match = "exact"),
                native_grain = "diagnosis_row",
                required_roles = c("subject_id", "event_id", "event_start",
                                   "event_end", "code", "source_item_id"),
                linkage = "subject"),
            text_dialysis_mentions = text_channel(
                source = "documents",
                selector = lucene_query("dialyse OR hemodialyse OR epuration"),
                native_grain = "document_sentence",
                required_roles = c("subject_id", "event_id", "point_date", "text",
                                   "source_item_id"),
                linkage = "subject")))
}

# Multi-source OR baseline. "Documented status" answer schema lives at the
# activation (text_extractor); combine is the researcher's explicit any_positive().
dialysis_status <- function(
        name, anchor, output_one_row_per = "PATID", window = c(-3650, 7),
        concept = dialysis_concept_spec()) {
    variable_spec(
        name = name,
        concept = concept,
        output_one_row_per = output_one_row_per,
        anchor = anchor,
        window = window,
        channels = list(
            pmsi_diag_dialysis = use_channel(),
            text_dialysis_mentions = use_channel(
                method = llm_after_lucene(),
                extractor = dialysis_text_definition())),
        output = bin_output(),
        combine_channels = any_positive())
}
