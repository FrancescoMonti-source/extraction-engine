# =============================================================================
# concepts-diabetes.R -- internal example concept and plain variable builder
# -----------------------------------------------------------------------------
# diabetes_concept_spec() declares the diabetes signal channels (it does not say
# whether a patient has diabetes, and activates nothing by default). The text
# channel carries the CONCEPT-OWNED answer definition (diabetes_text_definition,
# defined below) because the response schema belongs to the concept.
#
# diabetes_baseline_status_template() is a CONCEPT-SPECIFIC quickstart (not a
# generic computation pattern). Concrete variable_specs are written in study code,
# e.g. diabete_pre_greffe (from this template) and perioperative_max_glucose
# (written directly, reducing the glucose channel with a plain function) -- see tests.
# =============================================================================

# The diabetes concept's TEXT answer schema (one evidenced field -- documented =>
# diabetes mentioned (needs evidence) -> hit; not_documented => none). Thin wrapper
# over the shared, neutral binary_presence_text_definition() (R/extract.R). The
# response schema belongs to the concept, so it lives here.
diabetes_text_definition <- function() {
    binary_presence_text_definition(
        name = "diabetes_text",
        status_key = "diabetes_status",
        field = "diabetes_mention",
        system_prompt = paste(
            "Identify only explicitly documented diabetes in the supplied snippets.",
            "Do not infer absence from silence."))
}

diabetes_concept_spec <- function() {
    concept_spec(
        name = "diabetes",
        channels = list(
            pmsi_diag_e10_e14 = code_channel(
                source = "pmsi_diag",
                selector = icd10("^E1[0-4]"),
                native_grain = "diagnosis_row",
                required_roles = c("subject_id", "event_id", "event_start",
                                   "event_end", "code", "source_item_id"),
                linkage = "subject"),
            text_diabetes_mentions = text_channel(
                source = "documents",
                selector = lucene_query(
                    "diabete OR diabetique OR insulinotherapie OR insuline"),
                extractor = diabetes_text_definition(),
                native_grain = "document_sentence",
                required_roles = c("subject_id", "event_id", "point_date", "text",
                                   "source_item_id"),
                linkage = "subject"),
            glucose_measurements = lab_channel(
                source = "biology",
                selector = analyte("GLU.GLU"),
                native_grain = "lab_result",
                required_roles = c("subject_id", "event_id", "point_date",
                                   "value_num", "value_str", "analyte",
                                   "source_item_id", "source_result_id"),
                linkage = "subject")))
}

diabetes_baseline_status <- function(
        name, anchor, output_one_row_per = "PATID", window = c(-1825, 7),
        concept = diabetes_concept_spec()) {
    variable_spec(
        name = name,
        concept = concept,
        output_one_row_per = output_one_row_per,
        anchor = anchor,
        window = window,
        channels = list(
            pmsi_diag_e10_e14 = use_channel(),
            text_diabetes_mentions = use_channel(
                method = llm_after_lucene(function(x) x))),
        output = bin_output(),
        combine_channels = any_positive())
}
