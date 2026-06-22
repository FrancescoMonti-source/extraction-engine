# =============================================================================
# types/anastomoses.R — response-type library entry for recipient anastomoses
# Nested evidenced fields + summary. Parser OWNS validity via the shared
# standard_field_validity helper and returns the engine's fields/summary contract.
# =============================================================================

suppressWarnings(suppressMessages(library(dplyr)))

ANASTOMOSES_FIELDS <- c(
    transplantation_duree_anastomose_arterielle        = "integer",
    transplantation_type_anastomose_arterielle         = "string",
    transplantation_localisation_anastomose_arterielle = "string",
    transplantation_duree_anastomose_veineuse          = "integer",
    transplantation_type_anastomose_ureterale          = "string"
)
ANASTOMOSES_SUMMARY <- "transplantation_resume_anastomoses"

ANASTOMOSES_SYSTEM_PROMPT <- paste(
    "Tu es un assistant d'extraction clinique sur des comptes rendus operatoires",
    "de transplantation renale chez le RECEVEUR. Base-toi UNIQUEMENT sur les",
    "extraits fournis ; ignore le donneur et la duree operatoire totale.",
    "Pour chaque champ choisis d'abord le statut, puis la valeur, puis les preuves.",
    "Statuts: documented = valeur explicite utilisable ; not_documented = absent ;",
    "unusable = information presente mais inexploitable selon les regles.",
    "Regles:",
    "- Durees arterielle/veineuse: minutes entieres explicites uniquement.",
    "- Une seule duree combinee arterio-veineuse non separable => 'unusable' pour",
    "  LES DEUX durees.",
    "- Jamais l'ischemie tiede/froide comme duree d'anastomose.",
    "- Plusieurs anastomoses arterielles: type/localisation seulement si une",
    "  anastomose principale est identifiable ; sinon 'unusable'.",
    "- Technique ureterale: seulement si explicitement nommee.",
    "- evidence_ids: cite le plus petit ensemble suffisant (prefere un seul S..).",
    "  Pour 'unusable' cite OBLIGATOIREMENT l'extrait qui cause le null ; pour",
    "  'not_documented' mets []. N'invente jamais d'identifiant.",
    sep = "\n"
)

type_anastomoses <- function(snippet_ids) {
    evidenced <- function(kind) {
        vt <- if (kind == "integer") {
            ellmer::type_integer("Minutes entieres si documented, sinon null.", required = FALSE)
        } else {
            ellmer::type_string("Libelle court normalise si documented, sinon null.", required = FALSE)
        }
        ellmer::type_object(
            status = ellmer::type_enum(
                c("documented", "not_documented", "unusable"),
                "documented=utilisable; not_documented=absent; unusable=present mais inexploitable"),
            value = vt,
            evidence_ids = ellmer::type_array(
                ellmer::type_enum(snippet_ids),
                "Identifiants S.. justifiant la decision; [] seulement si not_documented."))
    }
    args <- setNames(lapply(unname(ANASTOMOSES_FIELDS), evidenced), names(ANASTOMOSES_FIELDS))
    args[[ANASTOMOSES_SUMMARY]] <- ellmer::type_string(
        "Resume clinique tres court des preuves retenues et des nulls consequents.")
    do.call(ellmer::type_object, args)
}

prompt_anastomoses <- function(task, candidates) {
    paste(
        sprintf("Date de chirurgie receveur: %s", format(task$anchor_date[[1]], "%Y-%m-%d")),
        "Chaque extrait = contexte avant [phrase declenchante] contexte apres.",
        "Tout l'extrait est citable par son identifiant S...",
        "", "Extraits numerotes:", format_snippet_block(candidates),
        sep = "\n")
}

# Returns the engine contract: fields tibble (+ field_validity) and summary.
parse_anastomoses <- function(result, snippet_ids) {
    rows <- lapply(names(ANASTOMOSES_FIELDS), function(f) {
        node <- result[[f]]
        status <- if (length(node$status) == 1L) as.character(node$status) else NA_character_
        ids <- intersect(unique(as.character(unlist(node$evidence_ids))), snippet_ids)
        is_int <- ANASTOMOSES_FIELDS[[f]] == "integer"
        raw <- node$value
        present <- !is.null(raw) && length(raw) == 1L && !is.na(raw)
        # status-authoritative: a value is meaningful only when documented.
        nv <- if (identical(status, "documented") && present) {
            if (is_int) as.character(as.integer(raw)) else trimws(as.character(raw))
        } else NA_character_
        v <- standard_field_validity(status, nv, ids)
        tibble::tibble(field = f, status = status, normalized_value = nv,
                       evidence_ids = list(ids),
                       field_validity = v$field_validity, validity_reason = v$validity_reason)
    })
    summary <- result[[ANASTOMOSES_SUMMARY]]
    summary <- if (is.null(summary) || !length(summary)) NA_character_ else trimws(as.character(summary[[1]]))
    list(fields = bind_rows(rows), summary = summary)
}

anastomoses_definition <- function() {
    new_task_definition(
        name = "anastomoses", system_prompt = ANASTOMOSES_SYSTEM_PROMPT,
        type_builder = type_anastomoses, prompt_builder = prompt_anastomoses,
        parser = parse_anastomoses, summary_field = ANASTOMOSES_SUMMARY,
        summary_required = TRUE)
}
