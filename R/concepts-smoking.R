# =============================================================================
# concepts-smoking.R -- internal example concept and plain variable builder
# -----------------------------------------------------------------------------
# smoking_concept_spec() is deliberately neutral ("where smoking text lives"), not
# a current-status taxonomy: the concept could later feed pack-years or lifetime
# smoking, which need different answer shapes. So the channel declares only the
# text route (the Lucene query selector) and carries NO answer schema.
#
# "Documented current status" is a TEMPLATE/ACTIVATION choice, not a concept fact:
# the template supplies the categorical answer schema (smoking_definition, from
# types/smoking.R) as the channel's text_extractor and the categorical output. A
# different smoking variable could activate the same channel with a different
# extractor/output without touching the concept.
#
# This is a different concept SHAPE from diabetes: text-dominant, single-channel
# (combine_channels = NULL; the categorical output drives assembly), model parser/schema
# behaviour, evidence-sentence grounding, and invalid / citation_warning /
# no_candidate semantics.
# =============================================================================

# Smoking text-retrieval query (peri-op smoking terms + pack-year forms) -- the
# concept's Lucene selector (moved here from the retired adapter_smoking.R).
SMOKING_QUERY <- paste(
    "tabac*", "tabagi*", "fumeu*", "sevr*", "cigarette*", "paquet*",
    "<(0* OR 1* OR 2* OR 3* OR 4* OR 5* OR 6* OR 7* OR 8* OR 9*) PA>",
    "(0*PA OR 1*PA OR 2*PA OR 3*PA OR 4*PA OR 5*PA OR 6*PA OR 7*PA OR 8*PA OR 9*PA)",
    sep = " OR ")

smoking_concept_spec <- function() {
    concept_spec(
        name = "smoking",
        channels = list(
            text_smoking_mentions = text_channel(
                source = "documents",
                selector = lucene_query(SMOKING_QUERY),
                native_grain = "document_sentence",
                required_roles = c("subject_id", "event_id", "point_date", "text",
                                   "source_item_id"),
                linkage = "subject")))
}

# Peri-operative documented smoking status:
# the status documented in [anchor - 365d, anchor + 7d]. Concept-specific
# quickstart -- "documented status" lives here (extractor + categorical output;
# single channel, so combine_channels = NULL), not in the neutral concept.
documented_smoking_status_periop <- function(
        name, anchor, output_one_row_per = "PATID", window = c(-365, 7),
        concept = smoking_concept_spec()) {
    variable_spec(
        name = name,
        concept = concept,
        output_one_row_per = output_one_row_per,
        anchor = anchor,
        window = window,
        channels = list(text_smoking_mentions = use_channel(
            method = llm_after_lucene(function(x) x),
            extractor = smoking_definition())),
        output = cat_output(SMOKING_STATUSES))
}
