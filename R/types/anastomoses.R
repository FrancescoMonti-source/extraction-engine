# =============================================================================
# types/anastomoses.R — response-type library entry for recipient anastomoses
# A per-task BUILDER (legal snippet_ids are task-specific), plus the prompt and
# the deterministic parser/validator the engine calls. Exact D0840 field names.
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

# Per-task structured type. Each clinical field is a nested {status, value,
# evidence_ids}; the summary is a plain string (its evidence is the R-side union).
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
                "Identifiants S.. justifiant la decision; [] seulement si not_documented.")
        )
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
        "",
        "Extraits numerotes:",
        format_snippet_block(candidates),
        sep = "\n"
    )
}

# Deterministic parse + validate. Returns one-row values tibble (+ task_valid /
# task_reason / summary) and a (field, snippet_id) evidence tibble.
parse_anastomoses <- function(raw, snippet_ids) {
    fields <- names(ANASTOMOSES_FIELDS)
    vr <- list(); ev <- list(); reasons <- character(); all_refs <- character()
    for (f in fields) {
        node <- raw[[f]]
        ef <- evidenced_field(node$status, node$value, node$evidence_ids,
                              is_integer = ANASTOMOSES_FIELDS[[f]] == "integer")
        ids <- intersect(ef$evidence_ids, snippet_ids)
        vr[[f]] <- ef$value
        vr[[paste0(f, "_status")]] <- ef$status
        if (!ef$valid) reasons <- c(reasons, sprintf("%s: %s", f, ef$reason))
        if (length(ids)) {
            ev[[length(ev) + 1L]] <- tibble::tibble(field = f, snippet_id = ids)
            all_refs <- union(all_refs, ids)
        }
    }
    summary <- raw[[ANASTOMOSES_SUMMARY]]
    summary <- if (is.null(summary) || !length(summary)) NA_character_ else trimws(as.character(summary[[1]]))
    if (is.na(summary) || !nzchar(summary)) { summary <- NA_character_; reasons <- c(reasons, "summary missing") }
    if (length(all_refs)) ev[[length(ev) + 1L]] <- tibble::tibble(field = ANASTOMOSES_SUMMARY, snippet_id = all_refs)

    vr[[ANASTOMOSES_SUMMARY]] <- summary
    vr$task_valid <- !length(reasons)
    vr$task_reason <- paste(reasons, collapse = " | ")
    list(
        values = tibble::as_tibble(vr),
        evidence = if (length(ev)) bind_rows(ev) else tibble::tibble(field = character(), snippet_id = character())
    )
}
