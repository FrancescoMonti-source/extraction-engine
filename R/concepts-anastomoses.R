# =============================================================================
# concepts-anastomoses.R -- recipient transplant anastomoses (multi-field text)
# -----------------------------------------------------------------------------
# A third concept SHAPE: one extraction task -> SEVERAL related fields (arterial /
# venous durations, types, locations) from one operative report, with FIELD-LEVEL
# acceptance (a valid grounded field survives an invalid sibling). It is also
# EVENT-scoped (same surgical event), not date-windowed -- so the variable declares
# no window; eligibility is resolved upstream (link by subject + event).
#
# Like smoking, the concept is neutral (it declares the operative-report text
# route); the multi-field answer schema (anastomoses_definition, from
# types/anastomoses.R) is supplied at the template/activation layer, and the output
# is a SET of cohort columns (struct_output). It is single-channel, so combine =
# NULL and the struct output drives the multi-field assembly.
# =============================================================================

# Operative-report retrieval query (broad recall; the model + evidence do the
# precision) -- the concept's Lucene selector (moved here from adapter_anastomoses.R).
ANASTOMOSES_QUERY <- paste(
    "anastom*", "gregoir*", "ureter*", "reimplant*",
    "<veine iliaque>", "<artere iliaque>",
    sep = " OR ")

anastomoses_concept_spec <- function() {
    concept_spec(
        name = "transplant_anastomoses",
        channels = list(
            text_operative_report = text_channel(
                source = "documents",
                selector = lucene_query(ANASTOMOSES_QUERY),
                native_grain = "document_sentence",
                required_roles = c("subject_id", "event_id", "point_date", "text",
                                   "source_item_id"),
                linkage = c("subject", "event"))))            # EVENT scope, not a date window
}

recipient_anastomoses <- function(
        name, anchor = NULL, output_one_row_per = "PATID",
        concept = anastomoses_concept_spec()) {
    variable_spec(
        name = name,
        concept = concept,
        output_one_row_per = output_one_row_per,
        anchor = anchor,
        window = NULL,
        channels = list(text_operative_report = use_channel(
            method = llm_after_lucene(),
            extractor = anastomoses_definition())),
        output = struct_output(names(ANASTOMOSES_FIELDS)))
}
