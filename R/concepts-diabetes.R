# =============================================================================
# concepts-diabetes.R -- the first concrete concept + its baseline template
# -----------------------------------------------------------------------------
# diabetes_concept_spec() declares the diabetes signal channels (it does not say
# whether a patient has diabetes, and activates nothing by default). The text
# channel carries the CONCEPT-OWNED answer definition (diabetes_text_definition,
# defined below) because the response schema belongs to the concept.
#
# diabetes_baseline_status_template() is a CONCEPT-SPECIFIC quickstart (not a
# generic computation pattern). Concrete variable_specs are written in study code,
# e.g. diabete_pre_greffe (from this template) and perioperative_max_glucose
# (written directly, using the max_value() operator) -- see tests.
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
                selector = icd10(c("E10", "E11", "E12", "E13", "E14")),
                native_grain = "diagnosis_row",
                required_roles = c("subject", "event", "interval_start",
                                   "interval_end", "code", "native_ref"),
                linkage = "subject"),
            text_diabetes_mentions = text_channel(
                source = "documents",
                selector = lucene_query(
                    "diabete OR diabetique OR insulinotherapie OR insuline"),
                extractor = diabetes_text_definition(),
                native_grain = "document_sentence",
                required_roles = c("subject", "event", "date", "text",
                                   "native_ref"),
                linkage = "subject"),
            glucose_measurements = lab_channel(
                source = "biology",
                selector = analyte("GLU.GLU"),
                native_grain = "lab_result",
                required_roles = c("subject", "event", "date", "value",
                                   "analyte", "native_ref"),
                linkage = "subject")))
}

diabetes_baseline_status_template <- function(concept = diabetes_concept_spec()) {
    variable_template(
        name = "diabetes_baseline_status_template",
        concept = concept,
        defaults = list(
            window = before_anchor(days = 1825L, grace_days = 7L),
            channels = c("pmsi_diag_e10_e14", "text_diabetes_mentions"),
            text_method = llm_after_lucene(top_n = 20L),
            output = binary_output(),
            combine = any_positive(),
            absence_policy = open_world()))   # build = .default_template_build(concept)
}

# --- diabetes: thin clinically-named caller of the neutral measure_code_presence()
# core (R/structured.R). ICD-10 E10-E14 over the diagnosis source, default 5-year
# lookback. Kept for backward compatibility (direct structured callers/tests/scripts);
# the generic run_variable() code branch calls the neutral core directly.
DIABETES_CODES <- c("E10", "E11", "E12", "E13", "E14")

measure_diabetes <- function(diag, tasks, codes = DIABETES_CODES,
                             from_days = -1825L, to_days = 7L,
                             missing_datsort = c("use_start", "exclude")) {
    measure_code_presence(
        diag, tasks, codes = codes, from_days = from_days, to_days = to_days,
        missing_datsort = missing_datsort,
        field = "diabetes_status", source = "diagnosis")
}
