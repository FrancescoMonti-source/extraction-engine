#!/usr/bin/env Rscript
# =============================================================================
# Parallel round 1 (Claude branch) — reproduce D0840's smoking task with ellmer
# -----------------------------------------------------------------------------
# Reference: C:/Users/franc/Desktop/projects/D0840/D0840.R, §4.4 (lines 782-911).
# We keep D0840's INPUTS, window, and value meanings, and replace its `gpt_column`
# (OpenAI) call with a local ellmer/Ollama structured call. We ADD auditable
# provenance: numbered snippets, `evidence_ids` (a dynamic enum), and a
# `decision_note`. Per the brief, `no_candidate` is an R-side workflow state.
#
# Contract (DESIGN.md, conformed to D0840 tabac_statut):
#   variable:     smoking_status_periop  (== D0840 tabac_statut)
#   anchor:       surgery date (DATEACTE)
#   source scope: docs with RECDATE in [anchor - 365d, anchor + 7d]
#   values:       actif / sevre / non_fumeur / indetermine
#   absence:      no eligible candidate -> no_candidate (R-side, no model call)
#
# DEVIATION (data-forced, flag for comparison): D0840 builds core_patids from
# `chirurgie.xlsx` (donor/recipient pairs). We use the same file, supplied in the
# shared dataset dir.
#
# PRIVACY: console prints ONLY aggregates/counts. Snippet text, evidence, and
# notes are PHI and are written ONLY to outputs/ (gitignored).
#
# Run:  Rscript scripts/smoking_d0840.R
# Env:  SMOKE_N (limit groups, 0=all)  MODEL  DRY_RUN=1 (stop before LLM)
#       DATASETS_DIR
# =============================================================================

suppressWarnings(suppressMessages({
    library(dplyr)
    library(stringr)
    library(tidyr)
    stopifnot(
        requireNamespace("openxlsx", quietly = TRUE),
        requireNamespace("writexl", quietly = TRUE),
        requireNamespace("readr", quietly = TRUE)
    )
    if (Sys.getenv("DRY_RUN", "0") != "1") {
        stopifnot(requireNamespace("ellmer", quietly = TRUE))
    }
}))

# ---- config -----------------------------------------------------------------
DATASETS <- Sys.getenv("DATASETS_DIR", "C:/Users/franc/Documents/Datasets/D0840")
MODEL <- Sys.getenv("MODEL", "gemma3:4b") # ellmer strips :latest
N <- as.integer(Sys.getenv("SMOKE_N", "0")) # 0 = all groups
SEED <- 20260620L
DRY_RUN <- Sys.getenv("DRY_RUN", "0") == "1"
OUT_DIR <- "outputs"
dir.create(OUT_DIR, showWarnings = FALSE, recursive = TRUE)

STATUTS <- c("actif", "sevre", "non_fumeur", "indetermine")

# D0840 §4.4 parameters (kept identical)
WIN_PRE <- 365L
WIN_POST <- 7L
KEYWORDS <- stringr::regex(
    "tabac|tabagi|non[- ]?fumeur|ex[- ]?fumeur|ancien fumeur|fumeuse|fumeur|sevr|cigarette|paquet|\\b\\d+\\s*PA\\b",
    ignore_case = TRUE
)
SPLIT_PAT <- "\\n|//|\\r|(?<=[\\.;])\\s+"
CONTEXT <- 1L
MAX_SNIPPETS <- 12L

# ---- helpers (inlined from D0840 R/ for self-containment) --------------------
norm <- function(x) tolower(gsub("\\s+", " ", trimws(x)))

# Excel-serial or text date -> Date (D0840 clean_mixed_date, numeric branch)
clean_mixed_date <- function(x) {
    x <- trimws(as.character(x))
    out <- rep(as.Date(NA), length(x))
    is_num <- grepl("^\\d+(\\.\\d+)?$", x)
    out[is_num] <- as.Date(as.numeric(x[is_num]), origin = "1899-12-30")
    is_txt <- !is_num & nzchar(x)
    out[is_txt] <- as.Date(x[is_txt]) # ISO fallback
    out
}

# D0840 extract_keyword_snippets (verbatim behaviour)
extract_keyword_snippets <- function(
    text,
    keyword_pattern,
    split_pattern = "\\n|//|\\r",
    context = 0L,
    max_snippets = 8L
) {
    text <- as.character(text)
    text[is.na(text)] <- ""
    vapply(
        text,
        function(txt) {
            if (!nzchar(trimws(txt))) {
                return(NA_character_)
            }
            parts <- unlist(strsplit(txt, split_pattern, perl = TRUE))
            parts <- stringr::str_squish(parts)
            parts <- parts[nzchar(parts)]
            if (!length(parts)) {
                return(NA_character_)
            }
            hits <- which(stringr::str_detect(parts, keyword_pattern))
            if (!length(hits)) {
                return(NA_character_)
            }
            if (context > 0L) {
                idx <- unique(unlist(lapply(hits, function(i) {
                    seq.int(max(1L, i - context), min(length(parts), i + context))
                })))
            } else {
                idx <- hits
            }
            snippets <- unique(parts[idx])
            snippets <- snippets[nzchar(snippets)]
            if (!length(snippets)) {
                return(NA_character_)
            }
            paste(utils::head(snippets, max_snippets), collapse = " || ")
        },
        character(1)
    )
}

# ---- 1. core_patids from chirurgie.xlsx (D0840 lines 588-595) ----------------
ch <- openxlsx::read.xlsx(file.path(DATASETS, "chirurgie.xlsx")) %>%
    mutate(
        DATEACTE = clean_mixed_date(DATEACTE),
        PATID_donneur = as.character(PATID_donneur),
        PATID_receveur = as.character(PATID_receveur)
    )

core_patids <- bind_rows(
    ch %>% transmute(DATEACTE, role = "donneur", PATID = PATID_donneur),
    ch %>% transmute(DATEACTE, role = "receveur", PATID = PATID_receveur)
) %>%
    filter(!is.na(PATID), PATID != "", !is.na(DATEACTE)) %>%
    distinct()

# ---- 2. candidate selection (D0840 §4.4, faithful) --------------------------
docs <- readRDS(file.path(DATASETS, "docs")) %>%
    transmute(
        PATID = as.character(PATID),
        EVTID,
        ELTID,
        RECDATE = as.Date(RECDATE),
        RECTYPE,
        RECTXT
    )

tabac_candidates <- docs %>%
    inner_join(core_patids, by = "PATID", relationship = "many-to-many") %>%
    filter(
        RECDATE >= DATEACTE - WIN_PRE,
        RECDATE <= DATEACTE + WIN_POST,
        str_detect(RECTXT, KEYWORDS)
    ) %>%
    mutate(
        snippet_tabac = extract_keyword_snippets(
            RECTXT,
            KEYWORDS,
            split_pattern = SPLIT_PAT,
            context = CONTEXT,
            max_snippets = MAX_SNIPPETS
        ),
        jours_diff_abs = abs(as.numeric(difftime(RECDATE, DATEACTE, units = "days"))),
        post_op = as.integer(RECDATE > DATEACTE),
        rectype_priority = dplyr::case_when(
            str_detect(
                dplyr::coalesce(RECTYPE, ""),
                stringr::regex(
                    "consult|anesth|greffe|neph|chir|hospi",
                    ignore_case = TRUE
                )
            ) ~ 0L,
            TRUE ~ 1L
        )
    ) %>%
    filter(!is.na(snippet_tabac))

# ---- 3. numbered-snippet context with provenance (our addition) -------------
# Split each doc's snippet bundle into atomic snippets, order by D0840 proximity,
# dedup copy-forward (normalized), keep top MAX_SNIPPETS, number S01..Sn.
snip <- tabac_candidates %>%
    mutate(atom = str_split(snippet_tabac, stringr::fixed(" || "))) %>%
    tidyr::unnest_longer(atom) %>%
    mutate(atom = str_squish(atom)) %>%
    filter(nzchar(atom)) %>%
    arrange(
        PATID,
        DATEACTE,
        role,
        post_op,
        jours_diff_abs,
        rectype_priority,
        desc(RECDATE),
        desc(ELTID)
    ) %>%
    group_by(PATID, DATEACTE, role) %>%
    filter(!duplicated(norm(atom))) %>% # keep first (closest) normalized copy
    slice_head(n = MAX_SNIPPETS) %>%
    mutate(snippet_id = sprintf("S%02d", row_number())) %>%
    ungroup()

# group key table (one row per task call)
groups <- snip %>%
    distinct(PATID, DATEACTE, role) %>%
    arrange(PATID, DATEACTE, role) %>%
    mutate(group_id = sprintf("%s|%s|%s", PATID, format(DATEACTE, "%Y-%m-%d"), role))

# no_candidate = core_patids rows with no in-scope smoking snippet (R-side)
no_candidate <- core_patids %>%
    anti_join(groups, by = c("PATID", "DATEACTE", "role"))

# build the per-group numbered snippet block + provenance list
build_block <- function(g_patid, g_date, g_role) {
    s <- snip %>%
        filter(PATID == g_patid, DATEACTE == g_date, role == g_role) %>%
        arrange(snippet_id)
    header <- sprintf(
        "Date chirurgie: %s\nRole: %s\nExtraits tabagisme (du plus proche au plus eloigne):",
        format(g_date, "%Y-%m-%d"),
        g_role
    )
    lines <- sprintf(
        "%s | %s | %s | %s",
        s$snippet_id,
        format(s$RECDATE, "%Y-%m-%d"),
        dplyr::coalesce(s$RECTYPE, "NA"),
        s$atom
    )
    list(
        text = paste0(header, "\n", paste(lines, collapse = "\n")),
        ids = s$snippet_id,
        prov = s
    )
}

cat(sprintf(
    "core_patids=%d | candidate docs=%d | task groups=%d | no_candidate=%d\n",
    nrow(core_patids),
    nrow(tabac_candidates),
    nrow(groups),
    nrow(no_candidate)
))

if (DRY_RUN) {
    # write a small sample of numbered contexts for inspection (PHI -> outputs/)
    samp <- head(groups, 5)
    dump <- lapply(seq_len(nrow(samp)), function(i) {
        b <- build_block(samp$PATID[i], samp$DATEACTE[i], samp$role[i])
        paste0("### ", samp$group_id[i], "\n", b$text)
    })
    writeLines(
        unlist(dump),
        file.path(OUT_DIR, "smoking_dryrun_sample_contexts.txt")
    )
    snip_per_group <- snip %>% count(PATID, DATEACTE, role, name = "n_snip")
    cat(sprintf(
        "snippets/group: median=%d max=%d\n",
        as.integer(median(snip_per_group$n_snip)),
        max(snip_per_group$n_snip)
    ))
    cat("DRY_RUN: wrote sample contexts to outputs/ — stopping before LLM.\n")
    quit(status = 0)
}

# ---- 4. ellmer structured call (local Ollama, fresh chat per call) -----------
SYSTEM_PROMPT <- paste(
    "Tu es un assistant d'extraction clinique. Tu recois des extraits numerotes",
    "(S01, S02, ...) de dossier autour d'une chirurgie. Determine le statut tabagique",
    "du patient au moment de la chirurgie.",
    "- actif: le patient fume encore au moment de la chirurgie.",
    "- sevre: ancien fumeur / sevre / arret du tabac avant la chirurgie.",
    "- non_fumeur: non-fumeur, jamais fume, ou absence de tabagisme.",
    "- indetermine: extraits contradictoires ou insuffisants.",
    "Regles: base-toi UNIQUEMENT sur les extraits fournis ; ignore les mentions",
    "concernant la famille ou l'entourage ; 'evidence_ids' liste les identifiants",
    "(S..) des extraits qui justifient ta reponse, n'invente jamais d'identifiant,",
    "et mets [] si indetermine sans extrait pertinent ; 'decision_note' est une",
    "explication clinique tres courte, surtout en cas de conflit ou d'ambiguite.",
    sep = "\n"
)

make_chat <- function(model) {
    ellmer::chat_ollama(
        model = model,
        system_prompt = SYSTEM_PROMPT,
        params = ellmer::params(temperature = 0, seed = SEED),
        echo = "none"
    )
}

build_type <- function(ids) {
    ellmer::type_object(
        smoking_status_periop = ellmer::type_enum(
            STATUTS,
            "Le statut tabagique au moment de la chirurgie."
        ),
        evidence_ids = ellmer::type_array(
            ellmer::type_enum(ids),
            "Identifiants (S..) des extraits qui justifient la reponse ; [] si indetermine."
        ),
        decision_note = ellmer::type_string(
            "Explication clinique tres courte, surtout en cas de conflit ou d'ambiguite."
        )
    )
}

g <- groups
if (N > 0L) {
    g <- head(g, N)
}
cat(sprintf("Calling model=%s on %d groups...\n", MODEL, nrow(g)))

rows <- list() # per-call detail (PHI) -> outputs/
attempts <- list() # minimal attempt log -> outputs/

for (i in seq_len(nrow(g))) {
    b <- build_block(g$PATID[i], g$DATEACTE[i], g$role[i])
    t0 <- Sys.time()
    out <- tryCatch(
        {
            chat <- make_chat(MODEL) # FRESH chat per call (confound control)
            res <- chat$chat_structured(b$text, type = build_type(b$ids))
            list(status = "ok", res = res, error = NA_character_)
        },
        error = function(e) {
            list(status = "error", res = NULL, error = conditionMessage(e))
        }
    )
    lat <- as.numeric(difftime(Sys.time(), t0, units = "secs")) * 1000

    status_val <- NA_character_
    ev_ids <- character(0)
    note <- NA_character_
    status_in_enum <- NA
    ev_subset_ok <- NA
    if (identical(out$status, "ok") && is.list(out$res)) {
        status_val <- out$res[["smoking_status_periop"]]
        ev_ids <- out$res[["evidence_ids"]]
        ev_ids <- if (is.null(ev_ids)) character(0) else as.character(ev_ids)
        note <- out$res[["decision_note"]]
        status_in_enum <- isTRUE(status_val %in% STATUTS)
        ev_subset_ok <- all(ev_ids %in% b$ids) # mechanical check only
    }

    aid <- sprintf("%s#%04d", MODEL, i)
    attempts[[length(attempts) + 1]] <- data.frame(
        attempt_id = aid,
        ts = format(Sys.time(), "%Y-%m-%dT%H:%M:%S"),
        model = MODEL,
        group_id = g$group_id[i],
        n_snippets = length(b$ids),
        status = out$status,
        latency_ms = round(lat),
        error = out$error,
        stringsAsFactors = FALSE
    )
    # materialize evidence -> snippet text (PHI)
    ev_text <- if (length(ev_ids)) {
        paste(b$prov$atom[match(ev_ids, b$prov$snippet_id)], collapse = " || ")
    } else {
        NA_character_
    }
    rows[[length(rows) + 1]] <- data.frame(
        attempt_id = aid,
        group_id = g$group_id[i],
        PATID = g$PATID[i],
        DATEACTE = format(g$DATEACTE[i], "%Y-%m-%d"),
        role = g$role[i],
        n_snippets = length(b$ids),
        call_status = out$status,
        smoking_status_periop = status_val,
        status_in_enum = status_in_enum,
        evidence_ids = paste(ev_ids, collapse = ","),
        evidence_subset_ok = ev_subset_ok,
        decision_note = note,
        evidence_text = ev_text,
        context = b$text,
        latency_ms = round(lat),
        stringsAsFactors = FALSE
    )
}

res_df <- do.call(rbind, rows)
att_df <- do.call(rbind, attempts)

# also record no_candidate rows in the value table (R-side, no call)
nc_df <- no_candidate %>%
    transmute(
        attempt_id = NA_character_,
        group_id = sprintf(
            "%s|%s|%s",
            PATID,
            format(DATEACTE, "%Y-%m-%d"),
            role
        ),
        PATID,
        DATEACTE = format(DATEACTE, "%Y-%m-%d"),
        role,
        n_snippets = 0L,
        call_status = "no_candidate",
        smoking_status_periop = NA_character_,
        status_in_enum = NA,
        evidence_ids = NA_character_,
        evidence_subset_ok = NA,
        decision_note = NA_character_,
        evidence_text = NA_character_,
        context = NA_character_,
        latency_ms = NA_real_
    )

stamp <- format(Sys.time(), "%Y%m%d_%H%M%S")
writexl::write_xlsx(
    bind_rows(res_df, nc_df),
    file.path(OUT_DIR, sprintf("smoking_rows_%s.xlsx", stamp))
)
readr::write_excel_csv(
    att_df,
    file.path(OUT_DIR, sprintf("smoking_attempts_%s.csv", stamp))
)

# ---- 5. report (SAFE: counts/rates only) ------------------------------------
pct <- function(x) sprintf("%.0f%%", 100 * mean(x, na.rm = TRUE))
ok <- res_df$call_status == "ok"
cat("================ SMOKING (D0840 reproduction) — aggregates ================\n")
cat(sprintf("model ............... %s\n", MODEL))
cat(sprintf("groups called ....... %d\n", nrow(res_df)))
cat(sprintf("  call ok ........... %d (%s)\n", sum(ok), pct(ok)))
cat(sprintf("  status in enum .... %s\n", pct(res_df$status_in_enum)))
cat(sprintf(
    "  evidence subset ok  %s\n",
    pct(res_df$evidence_subset_ok)
))
tab <- table(factor(res_df$smoking_status_periop, levels = STATUTS))
cat("  status distribution: ")
cat(paste(sprintf("%s=%d", names(tab), tab), collapse = "  "), "\n")
cat(sprintf("no_candidate (R-side) %d\n", nrow(nc_df)))
lat <- att_df$latency_ms[att_df$status == "ok"]
if (length(lat)) {
    cat(sprintf(
        "latency ms (med/max)  %d / %d\n",
        round(median(lat)),
        max(lat)
    ))
}
cat(sprintf("\nWrote per-row detail + attempts to %s/ (gitignored).\n", OUT_DIR))
cat("==========================================================================\n")
