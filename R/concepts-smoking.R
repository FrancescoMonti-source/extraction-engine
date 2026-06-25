# =============================================================================
# concepts-smoking.R -- a NEUTRAL smoking concept + a documented-status template
# -----------------------------------------------------------------------------
# smoking_concept_spec() is deliberately neutral ("where smoking text lives"), not
# a current-status taxonomy: the concept could later feed pack-years or lifetime
# smoking, which need different answer shapes. So the channel declares only the
# text route (the Lucene query selector) and carries NO answer schema.
#
# "Documented current status" is a TEMPLATE/ACTIVATION choice, not a concept fact:
# the template supplies the categorical answer schema (smoking_definition, from
# types/smoking.R) as the channel's text_extractor, the categorical output, and the
# documented_status() collapse. A different smoking variable could activate the same
# channel with a different extractor/output without touching the concept.
#
# This is a different concept SHAPE from diabetes: text-dominant, categorical
# output, a non-`any` collapse, model parser/schema behaviour, evidence-sentence
# grounding, and invalid / citation_warning / no_candidate semantics.
# =============================================================================

smoking_concept_spec <- function() {
    concept_spec(
        name = "smoking",
        channels = list(
            text_smoking_mentions = text_channel(
                source = "documents",
                selector = lucene_query(SMOKING_QUERY),   # from adapter_smoking.R
                native_grain = "document_sentence",
                required_roles = c("subject", "event", "date", "text",
                                   "native_ref"),
                linkage = "subject")))
}

# Peri-operative documented smoking status (the D0840 `tabac_statut` shape):
# the status documented in [anchor - 365d, anchor + 7d]. Concept-specific
# quickstart -- "documented status" lives here (extractor + categorical output +
# documented_status collapse), not in the neutral concept.
documented_smoking_status_periop_template <- function(concept = smoking_concept_spec()) {
    variable_template(
        name = "documented_smoking_status_periop_template",
        concept = concept,
        defaults = list(
            window = before_anchor(days = 365L, grace_days = 7L),
            channels = c("text_smoking_mentions"),
            text_method = llm_after_lucene(),
            text_extractor = smoking_definition(),   # categorical answer schema (types/smoking.R)
            output = categorical_output(SMOKING_STATUSES),
            combine = documented_status(),
            absence_policy = open_world()))   # build = .default_template_build(concept)
}
