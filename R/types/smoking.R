# =============================================================================
# types/smoking.R — response-type library entry for peri-operative smoking
# Flat single-variable shape. Parser OWNS validity with smoking's OWN rule
# (definitive status => >=1 evidence; indetermine may abstain with none) — it
# deliberately does NOT use standard_field_validity, which would wrongly reject a
# valid abstention. This is the lesson from the c563740 review.
# =============================================================================

suppressWarnings(suppressMessages(library(dplyr)))

SMOKING_STATUSES <- c("actif", "sevre", "non_fumeur", "indetermine")
# Output bounds (study knobs). ellmer's type_*() builders cannot express maxItems/
# maxLength, and unbounded array/string outputs are the truncation root cause, so the
# type below is assembled as JSON Schema and constrained via type_from_schema().
SMOKING_EVIDENCE_MAX_ITEMS <- 5L
SMOKING_NOTE_MAX_LEN <- 300L

# Call-wide behaviour only. Field meanings live in the type descriptions below.
# Project scope is applied before the call and is not repeated to the model.
SMOKING_SYSTEM_PROMPT <- paste(
    "Tu es un assistant d'extraction clinique.",
    "Base-toi UNIQUEMENT sur les extraits fournis.",
    "Evalue le patient cible, jamais sa famille ni son entourage.",
    sep = "\n"
)

type_smoking <- function(snippet_ids) {
    # Bounded JSON Schema (see SMOKING_*_MAX above). Per-task dynamic snippet enum
    # stays (one call per task). Descriptions are unchanged from the builder version.
    schema <- list(
        type = "object", additionalProperties = FALSE,
        required = as.list(c("smoking_status", "evidence_ids", "decision_note")),
        properties = list(
            smoking_status = list(
                type = "string", enum = as.list(SMOKING_STATUSES),
                description = paste(
                    "Statut tabagique explicitement documente pour le patient cible.",
                    "actif = tabagisme actuel explicitement documente;",
                    "sevre = ancien fumeur, sevrage ou arret documente;",
                    "non_fumeur = statut non-fumeur ou absence de tabagisme explicitement documente;",
                    "indetermine = preuves contradictoires ou insuffisantes.",
                    "Ne jamais deduire non_fumeur du silence.")),
            evidence_ids = list(
                type = "array", maxItems = SMOKING_EVIDENCE_MAX_ITEMS,
                items = list(type = "string", enum = as.list(snippet_ids)),
                description = paste(
                    "Plus petit ensemble suffisant d'extraits (S..) soutenant directement le statut;",
                    "prefere un seul. Vide uniquement pour indetermine sans extrait pertinent.",
                    "N'invente jamais d'identifiant.")),
            decision_note = list(
                type = "string", maxLength = SMOKING_NOTE_MAX_LEN,
                description = "Explication clinique tres courte, surtout en cas de conflit ou d'ambiguite.")))
    ellmer::type_from_schema(text = jsonlite::toJSON(schema, auto_unbox = TRUE))
}

prompt_smoking <- function(task, candidates) {
    paste(
        "Chaque extrait = contexte avant [phrase declenchante] contexte apres.",
        "Tout l'extrait est citable par son identifiant S...",
        "", "Extraits numerotes:", format_snippet_block(candidates),
        sep = "\n")
}

parse_smoking <- function(result, snippet_ids) {
    status <- if (length(result$smoking_status) == 1L) as.character(result$smoking_status) else NA_character_
    cite <- resolve_cited_ids(result$evidence_ids, snippet_ids)   # shared D1 helper
    ids <- cite$real_ids
    note <- if (is.null(result$decision_note) || !length(result$decision_note)) NA_character_
            else trimws(as.character(result$decision_note[[1]]))
    reason <- character()
    if (!status %in% SMOKING_STATUSES) {
        reason <- c(reason, "invalid status")
    } else if (status != "indetermine" && !length(ids)) {
        reason <- c(reason, "definitive status without evidence")
    }
    # D1 keep-and-flag (owner-ratified): see resolve_cited_ids(). An invented citation
    # does NOT invalidate a value already grounded by >=1 real id; a value grounded
    # ONLY by an invented id is already rejected above ("definitive status without
    # evidence", ids empty). The invented id never materializes as evidence.
    fields <- tibble::tibble(
        field = "smoking_status", status = status, normalized_value = status,
        evidence_ids = list(ids),
        field_validity = if (length(reason)) "invalid" else "valid",
        validity_reason = paste(reason, collapse = "; "),
        citation_warning = cite$citation_warning,
        citation_warning_reason = cite$citation_warning_reason)
    list(fields = fields, summary = note)
}

smoking_definition <- function() {
    new_task_definition(
        name = "smoking", system_prompt = SMOKING_SYSTEM_PROMPT,
        type_builder = type_smoking, prompt_builder = prompt_smoking,
        parser = parse_smoking, summary_field = NULL, summary_required = FALSE)
}
