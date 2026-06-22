# =============================================================================
# types/smoking.R — response-type library entry for peri-operative smoking
# Flat single-variable shape. Parser OWNS validity with smoking's OWN rule
# (definitive status => >=1 evidence; indetermine may abstain with none) — it
# deliberately does NOT use standard_field_validity, which would wrongly reject a
# valid abstention. This is the lesson from the c563740 review.
# =============================================================================

suppressWarnings(suppressMessages(library(dplyr)))

SMOKING_STATUSES <- c("actif", "sevre", "non_fumeur", "indetermine")

SMOKING_SYSTEM_PROMPT <- paste(
    "Tu es un assistant d'extraction clinique. Determine le statut tabagique du",
    "patient au moment de la chirurgie, en te basant UNIQUEMENT sur les extraits.",
    "- actif: fume encore au moment de la chirurgie.",
    "- sevre: ancien fumeur / sevre / arret avant la chirurgie.",
    "- non_fumeur: non-fumeur, jamais fume, ou absence de tabagisme.",
    "- indetermine: extraits contradictoires ou insuffisants.",
    "Ignore les mentions concernant la famille ou l'entourage.",
    "evidence_ids: cite le plus petit ensemble suffisant d'extraits (prefere un",
    "seul S..) justifiant la reponse ; n'invente jamais d'identifiant ; mets []",
    "uniquement si indetermine sans extrait pertinent.",
    "decision_note: explication clinique tres courte, surtout en cas de conflit.",
    sep = "\n"
)

type_smoking <- function(snippet_ids) {
    ellmer::type_object(
        smoking_status = ellmer::type_enum(
            SMOKING_STATUSES, "Statut tabagique au moment de la chirurgie."),
        evidence_ids = ellmer::type_array(
            ellmer::type_enum(snippet_ids),
            "Identifiants S.. justifiant la reponse ; [] seulement si indetermine."),
        decision_note = ellmer::type_string(
            "Explication clinique tres courte, surtout en cas de conflit ou d'ambiguite."))
}

prompt_smoking <- function(task, candidates) {
    paste(
        sprintf("Date de chirurgie: %s", format(task$anchor_date[[1]], "%Y-%m-%d")),
        "Chaque extrait = contexte avant [phrase declenchante] contexte apres.",
        "Tout l'extrait est citable par son identifiant S...",
        "", "Extraits numerotes:", format_snippet_block(candidates),
        sep = "\n")
}

parse_smoking <- function(result, snippet_ids) {
    status <- if (length(result$smoking_status) == 1L) as.character(result$smoking_status) else NA_character_
    ids <- intersect(unique(as.character(unlist(result$evidence_ids))), snippet_ids)
    note <- if (is.null(result$decision_note) || !length(result$decision_note)) NA_character_
            else trimws(as.character(result$decision_note[[1]]))
    reason <- character()
    if (!status %in% SMOKING_STATUSES) {
        reason <- c(reason, "invalid status")
    } else if (status != "indetermine" && !length(ids)) {
        reason <- c(reason, "definitive status without evidence")
    }
    fields <- tibble::tibble(
        field = "smoking_status", status = status, normalized_value = status,
        evidence_ids = list(ids),
        field_validity = if (length(reason)) "invalid" else "valid",
        validity_reason = paste(reason, collapse = "; "))
    list(fields = fields, summary = note)
}

smoking_definition <- function() {
    new_task_definition(
        name = "smoking", system_prompt = SMOKING_SYSTEM_PROMPT,
        type_builder = type_smoking, prompt_builder = prompt_smoking,
        parser = parse_smoking, summary_field = NULL, summary_required = FALSE)
}
