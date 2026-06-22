# =============================================================================
# types/smoking.R — response-type library entry for peri-operative smoking
# A flat single-variable shape (enum value + evidence + note), NOT the nested
# evidenced-field shape anastomoses uses. The same engine consumes it because
# parse_smoking() normalizes to the engine's (values, evidence) contract.
# Demonstrates: one type_object != one fixed shape across variables.
# =============================================================================

suppressWarnings(suppressMessages(library(dplyr)))

# indetermine is a legitimate 4th value (contradictory OR insufficient), not a null.
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
            "Explication clinique tres courte, surtout en cas de conflit ou d'ambiguite.")
    )
}

prompt_smoking <- function(task, candidates) {
    paste(
        sprintf("Date de chirurgie: %s", format(task$anchor_date[[1]], "%Y-%m-%d")),
        "Chaque extrait = contexte avant [phrase declenchante] contexte apres.",
        "Tout l'extrait est citable par son identifiant S...",
        "",
        "Extraits numerotes:",
        format_snippet_block(candidates),
        sep = "\n"
    )
}

# Normalize to the engine contract. Single field 'smoking_status'. A definitive
# status (not indetermine) requires >=1 evidence; indetermine may cite none.
parse_smoking <- function(raw, snippet_ids) {
    status <- if (length(raw$smoking_status) == 1L) as.character(raw$smoking_status) else NA_character_
    ids <- unique(as.character(unlist(raw$evidence_ids)))
    ids <- intersect(ids[!is.na(ids) & nzchar(ids)], snippet_ids)
    note <- if (is.null(raw$decision_note) || !length(raw$decision_note)) NA_character_
            else trimws(as.character(raw$decision_note[[1]]))

    reasons <- character()
    if (!status %in% SMOKING_STATUSES) {
        reasons <- c(reasons, "invalid status")
    } else if (status != "indetermine" && !length(ids)) {
        reasons <- c(reasons, "definitive status without evidence")
    }

    list(
        values = tibble::tibble(
            smoking_status = status, decision_note = note,
            task_valid = !length(reasons),
            task_reason = paste(reasons, collapse = " | ")
        ),
        evidence = if (length(ids)) {
            tibble::tibble(field = "smoking_status", snippet_id = ids)
        } else {
            tibble::tibble(field = character(), snippet_id = character())
        }
    )
}
