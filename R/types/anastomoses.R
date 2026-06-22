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

# Call-wide behaviour only. Per-field clinical rules live in the value
# descriptions inside type_anastomoses(); the status/evidence contract lives in
# the shared nested-field descriptions.
ANASTOMOSES_SYSTEM_PROMPT <- paste(
    "Tu es un assistant d'extraction clinique sur des comptes rendus operatoires",
    "de transplantation renale chez le RECEVEUR.",
    "Base-toi UNIQUEMENT sur les extraits fournis ; ignore le donneur et la duree",
    "operatoire totale de la greffe.",
    "Pour chaque champ: choisis d'abord le statut, puis la valeur, puis les preuves.",
    sep = "\n"
)

# Per-field value semantics (the rules that used to sit in the system prompt).
ANASTOMOSES_VALUE_DESCRIPTIONS <- c(
    transplantation_duree_anastomose_arterielle = paste(
        "Duree de l'anastomose ARTERIELLE en minutes entieres explicites.",
        "'unusable' si seule une duree combinee arterio-veineuse non separable est donnee.",
        "Ne jamais utiliser une duree d'ischemie tiede ou froide."),
    transplantation_type_anastomose_arterielle = paste(
        "Type d'anastomose arterielle, libelle court normalise (ex: termino-laterale,",
        "latero-laterale). 'unusable' si plusieurs anastomoses arterielles sans",
        "anastomose principale identifiable."),
    transplantation_localisation_anastomose_arterielle = paste(
        "Site de l'anastomose arterielle, court normalise (ex: artere iliaque externe,",
        "aorte). Meme regle d'anastomose principale que le type."),
    transplantation_duree_anastomose_veineuse = paste(
        "Duree de l'anastomose VEINEUSE en minutes entieres explicites.",
        "'unusable' si seule une duree combinee non separable est donnee."),
    transplantation_type_anastomose_ureterale = paste(
        "Technique d'anastomose ureterale, court normalise (ex: Gregoir,",
        "Politano-Leadbetter), seulement si explicitement nommee.")
)

type_anastomoses <- function(snippet_ids) {
    evidenced <- function(kind, value_desc) {
        vt <- if (kind == "integer") {
            ellmer::type_integer(value_desc, required = FALSE)
        } else {
            ellmer::type_string(value_desc, required = FALSE)
        }
        ellmer::type_object(
            status = ellmer::type_enum(
                c("documented", "not_documented", "unusable"),
                "documented = valeur explicite utilisable; not_documented = absente; unusable = presente mais inexploitable selon la regle du champ."),
            value = vt,
            evidence_ids = ellmer::type_array(
                ellmer::type_enum(snippet_ids),
                paste("Plus petit ensemble suffisant d'extraits (S..) justifiant la decision;",
                      "pour 'unusable' cite OBLIGATOIREMENT l'extrait qui cause le null;",
                      "[] seulement pour 'not_documented'. N'invente jamais d'identifiant.")))
    }
    args <- setNames(
        lapply(names(ANASTOMOSES_FIELDS),
               function(f) evidenced(ANASTOMOSES_FIELDS[[f]], ANASTOMOSES_VALUE_DESCRIPTIONS[[f]])),
        names(ANASTOMOSES_FIELDS))
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
