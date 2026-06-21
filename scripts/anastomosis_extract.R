#!/usr/bin/env Rscript
# =============================================================================
# Anastomosis (recipient transplant event) — Claude independent build
# STRUCTURED EXTRACTION (ellmer + local Ollama). Consumes the candidates from
# scripts/anastomosis_retrieval.R and produces the four contract views:
#   coverage (from retrieval) / values / evidence / attempts.
#
# Per-field evidence (contract 651e5d7): every clinical field carries its own
# status + value + evidence_ids. Decide-before-cite: schema order is
# status -> value -> evidence_ids. Two null kinds:
#   not_documented  -> value null, evidence may be empty
#   unusable        -> value null, MUST cite the evidence that caused the null
# resume_anastomoses evidence = deterministic R-side UNION of the five field
# reference arrays (never model-selected).
#
# PRIVACY: console prints AGGREGATES ONLY. Values/evidence/notes (PHI) and the
# per-call detail -> gitignored outputs/.
# =============================================================================

suppressWarnings(suppressMessages({
    library(dplyr)
    library(stringr)
    stopifnot(requireNamespace("openxlsx", quietly = TRUE))
    stopifnot(requireNamespace("ellmer", quietly = TRUE))
}))

OUT_DIR <- file.path("outputs", "anastomosis")
MODEL   <- Sys.getenv("ANASTOMOSIS_MODEL", "gemma3:4b")  # dev-stage default; overridable
N       <- as.integer(Sys.getenv("ANASTOMOSIS_N", "0"))  # 0 = all candidate-bearing tasks
SEED    <- 20260621L

candidates <- readRDS(file.path(OUT_DIR, "candidates.rds"))
coverage   <- readRDS(file.path(OUT_DIR, "coverage.rds"))

FIELDS <- c(
    "duree_anastomose_arterielle",
    "type_anastomose_arterielle",
    "localisation_anastomose_arterielle",
    "duree_anastomose_veineuse",
    "type_anastomose_ureterale"
)

# ---- prompt + schema --------------------------------------------------------
SYSTEM_PROMPT <- paste(
    "Tu es un assistant d'extraction clinique sur des comptes rendus operatoires",
    "de transplantation renale chez le RECEVEUR. Tu recois des extraits numerotes",
    "(S01, S02, ...) provenant uniquement du sejour de greffe du receveur.",
    "Pour chaque champ, choisis d'abord un statut, puis la valeur, puis cite les",
    "extraits (evidence_ids) qui justifient ta decision.",
    "Statuts: documented = valeur explicite presente ; not_documented = information",
    "absente ; unusable = information presente mais inexploitable selon les regles.",
    "Regles de decision:",
    "- Base-toi UNIQUEMENT sur les extraits fournis ; ignore le donneur ;",
    "  ignore la duree operatoire totale de la greffe.",
    "- Les durees arterielle/veineuse sont des minutes entieres explicites.",
    "- Si une seule duree combinee arterio-veineuse est donnee sans valeurs",
    "  separables: statut 'unusable' et valeur null pour LES DEUX durees.",
    "- N'utilise jamais une duree d'ischemie tiede ou froide comme duree d'anastomose.",
    "- Plusieurs anastomoses arterielles: si une anastomose principale est",
    "  identifiable, donne son type/localisation ; sinon statut 'unusable', null.",
    "- Anastomose ureterale: ne donne une technique que si elle est explicitement nommee.",
    "- evidence_ids: identifiants (S..) des extraits qui justifient la decision.",
    "  N'invente JAMAIS d'identifiant. Pour 'documented' cite les extraits qui",
    "  portent la valeur ; pour 'unusable' cite OBLIGATOIREMENT au moins un",
    "  extrait qui cause le null (ex: duree combinee, anastomoses multiples) ;",
    "  pour 'not_documented' mets [].",
    "- resume_anastomoses: resume clinique tres court des preuves retenues et des",
    "  nulls consequents.",
    sep = "\n"
)

build_type <- function(ids) {
    ref_field <- function(value_type) {
        ellmer::type_object(
            status = ellmer::type_enum(
                c("documented", "not_documented", "unusable"),
                "documented=valeur explicite; not_documented=absent; unusable=present mais inexploitable"
            ),
            value = value_type,
            evidence_ids = ellmer::type_array(
                ellmer::type_enum(ids),
                "Identifiants (S..) qui justifient la decision; [] si not_documented."
            )
        )
    }
    ellmer::type_object(
        duree_anastomose_arterielle = ref_field(
            ellmer::type_integer("Duree anastomose arterielle en minutes entieres, ou null.", required = FALSE)),
        type_anastomose_arterielle = ref_field(
            ellmer::type_string("Type d'anastomose arterielle (libelle court normalise), ou null.", required = FALSE)),
        localisation_anastomose_arterielle = ref_field(
            ellmer::type_string("Site de l'anastomose arterielle (court normalise), ou null.", required = FALSE)),
        duree_anastomose_veineuse = ref_field(
            ellmer::type_integer("Duree anastomose veineuse en minutes entieres, ou null.", required = FALSE)),
        type_anastomose_ureterale = ref_field(
            ellmer::type_string("Technique d'anastomose ureterale (court normalise), ou null.", required = FALSE)),
        resume_anastomoses = ellmer::type_string(
            "Resume clinique tres court des preuves retenues et des nulls consequents.")
    )
}

make_chat <- function(model) {
    ellmer::chat_ollama(
        model = model,
        system_prompt = SYSTEM_PROMPT,
        params = ellmer::params(temperature = 0, seed = SEED),
        echo = "none"
    )
}

# numbered candidate block for one task; returns text, ids, and id->ref map
build_block <- function(tid) {
    cs <- candidates %>%
        filter(task_id == tid) %>%
        arrange(RECDATE, ELTID, sentence) %>%
        mutate(sid = sprintf("S%02d", row_number()))
    lines <- sprintf(
        "%s | %s | %s | %s [[ %s ]] %s",
        cs$sid, format(cs$RECDATE, "%Y-%m-%d"), coalesce(cs$RECTYPE, "NA"),
        coalesce(cs$context_before, ""), cs$hit_text, coalesce(cs$context_after, "")
    )
    header <- sprintf("Date chirurgie receveur: %s",
                      format(cs$DATEACTE[1], "%Y-%m-%d"))
    list(
        text = paste0(header, "\nExtraits numerotes:\n", paste(lines, collapse = "\n")),
        ids  = cs$sid,
        map  = cs %>% transmute(sid, evidence_ref, ELTID, sentence, RECDATE, RECTYPE, hit_text)
    )
}

# ---- run over candidate-bearing tasks ---------------------------------------
task_ids <- coverage %>% filter(state == "candidate_bearing") %>% pull(task_id)
if (N > 0L) task_ids <- head(task_ids, N)

cat(sprintf("model=%s | candidate-bearing tasks to call=%d | seed=%d\n",
            MODEL, length(task_ids), SEED))

value_rows    <- list()
evidence_rows <- list()
attempts      <- list()

scalar_or_na <- function(x) {
    if (is.null(x) || length(x) == 0) return(NA)
    x[[1]]
}

# Bounded retry: some local models intermittently crash ollama's llama-server
# (e.g. gpt-oss:20b -> CUDA "shared object initialization failed"); ollama
# reloads the model on the next request, so a short backoff usually recovers.
# attempts records n_tries.
MAX_TRY <- 3L
call_with_retry <- function(text, type) {
    out <- NULL
    for (k in seq_len(MAX_TRY)) {
        out <- tryCatch({
            chat <- make_chat(MODEL)             # fresh chat per attempt
            res <- chat$chat_structured(text, type = type)
            list(status = "ok", res = res, error = NA_character_, tries = k)
        }, error = function(e) list(status = "error", res = NULL,
                                    error = conditionMessage(e), tries = k))
        if (identical(out$status, "ok")) break
        Sys.sleep(min(5L * k, 15L))              # let llama-server restart
    }
    out
}

for (i in seq_along(task_ids)) {
    tid <- task_ids[i]
    b <- build_block(tid)
    t0 <- Sys.time()
    out <- call_with_retry(b$text, build_type(b$ids))
    lat <- as.numeric(difftime(Sys.time(), t0, units = "secs")) * 1000

    aid <- sprintf("%s#%04d", MODEL, i)
    valid_task <- NA
    if (identical(out$status, "ok") && is.list(out$res)) {
        vr <- list(task_id = tid, model = MODEL, call_status = "ok")
        field_refs <- character(0)
        field_valid <- logical(0)
        for (f in FIELDS) {
            node <- out$res[[f]]
            st  <- scalar_or_na(node[["status"]])
            val <- node[["value"]]
            ids <- node[["evidence_ids"]]
            ids <- if (is.null(ids)) character(0) else as.character(ids)
            ids <- ids[ids %in% b$ids]           # mechanical: keep only valid ids
            raw_chr <- if (is.null(val) || length(val) == 0) NA_character_ else as.character(val[[1]])
            # status is authoritative: a value is meaningful ONLY when documented.
            # type_integer(required=FALSE) has no true null, so the model emits a
            # placeholder number for not_documented/unusable durations -- ignore it.
            val_chr <- if (identical(st, "documented")) raw_chr else NA_character_
            has_val <- !is.na(val_chr) && nzchar(val_chr)

            vr[[paste0(f, "_status")]] <- if (is.na(st)) NA_character_ else st
            vr[[paste0(f, "_value")]]  <- val_chr
            vr[[paste0(f, "_n_refs")]] <- length(ids)

            # per-field validity per the contract (against the authoritative value)
            ok_field <- isTRUE(st %in% c("documented", "not_documented", "unusable")) &&
                (if (identical(st, "documented")) has_val && length(ids) >= 1 else TRUE) &&
                (if (identical(st, "unusable"))   length(ids) >= 1 else TRUE)
            field_valid <- c(field_valid, ok_field)

            # evidence rows (materialized to source sentence)
            if (length(ids)) {
                em <- b$map %>% filter(sid %in% ids) %>%
                    transmute(task_id = tid, field = f, sid, evidence_ref,
                              ELTID, sentence, RECDATE, RECTYPE, hit_text)
                evidence_rows[[length(evidence_rows) + 1]] <- em
                field_refs <- union(field_refs, em$evidence_ref)
            }
        }
        # resume evidence = deterministic R-side union of the five field arrays
        if (length(field_refs)) {
            er <- b$map %>% filter(evidence_ref %in% field_refs) %>%
                transmute(task_id = tid, field = "resume_anastomoses", sid,
                          evidence_ref, ELTID, sentence, RECDATE, RECTYPE, hit_text)
            evidence_rows[[length(evidence_rows) + 1]] <- er
        }
        vr$resume_anastomoses <- scalar_or_na(out$res[["resume_anastomoses"]])
        valid_task <- all(field_valid)
        vr$all_fields_valid <- valid_task
        value_rows[[length(value_rows) + 1]] <- as.data.frame(vr, stringsAsFactors = FALSE)
    }

    attempts[[length(attempts) + 1]] <- data.frame(
        attempt_id = aid, ts = format(Sys.time(), "%Y-%m-%dT%H:%M:%S"),
        model = MODEL, task_id = tid, n_candidates = length(b$ids),
        status = out$status, n_tries = out$tries, latency_ms = round(lat),
        all_fields_valid = valid_task, error = out$error,
        stringsAsFactors = FALSE
    )
    cat(sprintf("  [%d/%d] %s status=%s valid=%s %dms\n",
                i, length(task_ids), substr(tid, 1, 22), out$status,
                ifelse(is.na(valid_task), "NA", valid_task), round(lat)))
}

values_df   <- if (length(value_rows))    bind_rows(value_rows)    else tibble()
evidence_df <- if (length(evidence_rows)) bind_rows(evidence_rows) else tibble()
attempts_df <- bind_rows(attempts)

# ---- persist PHI artifacts (gitignored) + workbook --------------------------
stamp <- format(Sys.time(), "%Y%m%d_%H%M%S")
saveRDS(values_df,   file.path(OUT_DIR, "values.rds"))
saveRDS(evidence_df, file.path(OUT_DIR, "evidence.rds"))
saveRDS(attempts_df, file.path(OUT_DIR, "attempts.rds"))
openxlsx::write.xlsx(
    list(coverage = coverage, values = values_df,
         evidence = evidence_df, attempts = attempts_df),
    file.path(OUT_DIR, sprintf("anastomosis_%s_%s.xlsx", gsub("[^a-z0-9]", "", MODEL), stamp)),
    overwrite = TRUE
)

# ---- report (SAFE: counts only) ---------------------------------------------
n_ok    <- sum(attempts_df$status == "ok")
n_err   <- sum(attempts_df$status == "error")
n_valid <- sum(attempts_df$all_fields_valid %in% TRUE)
cat("\n============ ANASTOMOSIS EXTRACTION — aggregates ============\n")
cat(sprintf("calls .................. %d  (ok=%d, error=%d)\n", nrow(attempts_df), n_ok, n_err))
cat(sprintf("calls needing retry .... %d  (max tries=%d)\n",
            sum(attempts_df$n_tries > 1L), max(attempts_df$n_tries)))
cat(sprintf("all-fields-valid ....... %d / %d ok\n", n_valid, n_ok))
if (n_ok) {
    cat(sprintf("latency ms (median/max) %d / %d\n",
                as.integer(median(attempts_df$latency_ms[attempts_df$status == "ok"])),
                max(attempts_df$latency_ms[attempts_df$status == "ok"])))
}
if (nrow(values_df)) {
    for (f in FIELDS) {
        st <- values_df[[paste0(f, "_status")]]
        cat(sprintf("  %-38s documented=%d not_documented=%d unusable=%d\n",
                    f, sum(st == "documented", na.rm = TRUE),
                    sum(st == "not_documented", na.rm = TRUE),
                    sum(st == "unusable", na.rm = TRUE)))
    }
}
cat(sprintf("evidence rows .......... %d\n", nrow(evidence_df)))
cat(sprintf("\nWrote values/evidence/attempts + workbook to %s/ (gitignored).\n", OUT_DIR))
cat("=============================================================\n")
