#!/usr/bin/env Rscript
# =============================================================================
# Generic real-run driver: ONE end-to-end script for any concrete case.
# -----------------------------------------------------------------------------
# Replaces the three per-concept run_variable_*_real.R scripts. The spine is
# generic (config -> engine -> build -> real caller -> run_variable -> PHI detail
# to outputs/ -> aggregate-only console report); everything concept-specific is a
# CASE entry (removable scaffolding): which engine files to source, how to turn
# the raw local data into {tasks, sources, spec}, and its bounding defaults.
#
# The report needs NO per-case code: it dispatches on the run envelope itself --
# multi-channel combine -> per-channel contribution + positive attribution;
# categorical/fields output -> review/citation/grounding + per-field acceptance.
#
# MODEL: gemma3:4b only (passes scripts/check_grammar_enforcement.R). Reasoning
# models escape the grammar and are rejected by that gate.
#
# PRIVACY: console prints ONLY aggregates (counts/rates) -- never note text, model
# evidence quotes, codes, or subject/event ids. Per-row detail (PHI) -> outputs/
# only (gitignored). The committed script embeds no data.
#
# Run:  Rscript scripts/run_variable_real.R <case>       (diabetes | smoking | anastomoses)
# Env:  REAL_N=<subjects/events>  MAX_DOCS=<per subject/event>  SMOKE_SEED=20260625
#       DATASETS_DIR=C:/Users/franc/Documents/Datasets
# =============================================================================

suppressWarnings(suppressMessages({
    library(dplyr)
    stopifnot(
        requireNamespace("ellmer", quietly = TRUE),
        requireNamespace("corpustools", quietly = TRUE))
}))

# ---- case registry (concept-specific scaffolding lives HERE only) ------------
# A case: engine_files (sourced after the base engine), defaults (n, max_docs,
# max_tokens), and build(cfg) -> list(tasks, sources, spec, save_extra = list()).
CASES <- list()

# ---- shared helpers -----------------------------------------------------------
clean_mixed_date <- function(x) {                          # Excel-serial or ISO text -> Date
    x <- trimws(as.character(x)); out <- rep(as.Date(NA), length(x))
    is_num <- grepl("^\\d+(\\.\\d+)?$", x)
    out[is_num] <- as.Date(as.numeric(x[is_num]), origin = "1899-12-30")
    is_txt <- !is_num & nzchar(x); out[is_txt] <- as.Date(x[is_txt]); out
}

make_docs_corpus <- function(raw) {                        # raw: ELTID + RECTXT
    corpustools::create_tcorpus(
        data.frame(ELTID = raw$ELTID, RECTXT = raw$RECTXT, stringsAsFactors = FALSE),
        text_columns = "RECTXT", doc_column = "ELTID",
        split_sentences = TRUE, remember_spaces = FALSE, verbose = FALSE)
}

# ---- case: diabetes (multi-source OR: pmsi code channel + text channel) -------
# Corpus bounding (faithful): notes mentioning diabetes (regex superset of the
# channel's Lucene terms, so retrieval still does the precise selection) inside
# the template's window, capped to max_docs closest to the anchor per subject.
CASES$diabetes <- list(
    engine_files = "R/concepts-diabetes.R",
    defaults = list(n = 8L, max_docs = 10L, max_tokens = 512L),
    build = function(cfg) {
        ch_p   <- path_data("D0840", "chirurgie.xlsx")
        doc_p  <- path_data("D0840", "docs")
        pmsi_p <- path_data("D0840", "pmsi")
        stopifnot(file.exists(ch_p), file.exists(doc_p), file.exists(pmsi_p))
        stopifnot(requireNamespace("openxlsx", quietly = TRUE))

        ch <- openxlsx::read.xlsx(ch_p) %>%
            transmute(PATID = as.character(PATID_receveur),
                      anchor_date = clean_mixed_date(DATEACTE)) %>%
            filter(!is.na(PATID), PATID != "", !is.na(anchor_date)) %>%
            distinct(PATID, .keep_all = TRUE)
        set.seed(cfg$seed)
        ch <- ch[sample(nrow(ch), min(cfg$n, nrow(ch))), , drop = FALSE]
        tasks <- ch %>% transmute(task_id = PATID, PATID, anchor_date)
        win <- c(-1825, 7)   # template's window

        diag <- load_pmsi_diag(pmsi_p) %>%
            filter(as.character(PATID) %in% tasks$PATID)

        raw <- readRDS(doc_p) %>%
            transmute(PATID = as.character(PATID), EVTID = as.character(EVTID),
                      native_eltid = as.character(ELTID), RECDATE = as.Date(RECDATE),
                      RECTYPE = as.character(RECTYPE), RECTXT = as.character(RECTXT)) %>%
            inner_join(tasks[, c("PATID", "anchor_date")], by = "PATID") %>%
            filter(RECDATE >= anchor_date + win$from_days,
                   RECDATE <= anchor_date + win$to_days,
                   grepl("diabet|insulin", RECTXT, ignore.case = TRUE)) %>%
            mutate(prox = abs(as.numeric(RECDATE - anchor_date))) %>%
            arrange(PATID, prox) %>%
            group_by(PATID) %>% slice_head(n = cfg$max_docs) %>% ungroup() %>%
            mutate(ELTID = sprintf("E%06d", row_number()))    # unique corpus doc key
        docs_index <- raw %>% transmute(ELTID, PATID, EVTID, RECDATE, RECTYPE)

        list(
            cohort = tasks,
            sources = list(
                pmsi_diag = diag,
                documents = list(corpus = make_docs_corpus(raw),
                                 docs_index = docs_index)),
            spec = variable_spec(
                template = diabetes_baseline_status_template(),
                name = "diabete_pre_greffe", output_one_row_per = "PATID",
                anchor = "anchor_date"),
            save_extra = list(
                native_eltid = raw[, c("ELTID", "native_eltid", "PATID")]))
    })

# ---- case: smoking (single text channel, categorical output) ------------------
# Real note text + real DATEACTE; SYNTHETIC per-note subject key for clean 1:1
# task<->document linkage (the real PATID is irrelevant to the mechanism and is
# not carried, minimising PHI handling).
CASES$smoking <- list(
    engine_files = c("R/concepts-smoking.R", "R/types/smoking.R"),
    defaults = list(n = 10L, max_docs = NA_integer_, max_tokens = 512L),
    build = function(cfg) {
        pool_p <- path_data("tabac_eval_pool_1000.rds")
        if (!file.exists(pool_p)) {
            stop("Smoking pool not found: ", pool_p,
                 "\nSet DATASETS_DIR to the de-identified datasets directory.",
                 call. = FALSE)
        }
        pool <- readRDS(pool_p)
        set.seed(cfg$seed)
        samp <- pool[sample(nrow(pool), min(cfg$n, nrow(pool))), , drop = FALSE]
        n <- nrow(samp)

        sid    <- sprintf("S%04d", seq_len(n))               # synthetic subject == one note
        anchor <- as.Date(samp$DATEACTE)
        tasks  <- tibble::tibble(task_id = sid, PATID = sid, anchor_date = anchor)

        docs_index <- tibble::tibble(
            ELTID = sprintf("E%04d", seq_len(n)), PATID = sid,
            EVTID = sprintf("V%04d", seq_len(n)),
            RECDATE = anchor,                                # in-window by construction
            RECTYPE = "note")
        raw <- data.frame(ELTID = docs_index$ELTID,
                          RECTXT = as.character(samp$text_tabac_llm))

        list(
            cohort = tasks,
            sources = list(documents = list(corpus = make_docs_corpus(raw),
                                            docs_index = docs_index)),
            spec = variable_spec(
                template = documented_smoking_status_periop_template(),
                name = "tabac_statut_periop", output_one_row_per = "PATID",
                anchor = "anchor_date"),
            save_extra = list())
    })

# ---- case: anastomoses (EVENT-scoped text channel, multi-field output) --------
# Corpus bounding (faithful): docs restricted to the sampled events (PATID+EVTID)
# and to operative-report-like notes mentioning anastomosis terms (regex superset
# of the channel's Lucene query), capped per event. Tasks are sampled among
# recipients that HAVE >=1 such document (a mechanism run, not a coverage estimate).
CASES$anastomoses <- list(
    engine_files = c("R/concepts-anastomoses.R", "R/adapter_anastomoses.R",
                     "R/types/anastomoses.R"),
    defaults = list(n = 6L, max_docs = 6L, max_tokens = 1024L),
    build = function(cfg) {
        ch_p  <- path_data("D0840", "chirurgie.xlsx")
        doc_p <- path_data("D0840", "docs")
        stopifnot(file.exists(ch_p), file.exists(doc_p))
        ana_rx <- "anastom|gregoir|ureter|reimplant|iliaque"  # superset of ANASTOMOSES_QUERY

        all_tasks <- anastomoses_load_tasks(ch_p)
        docs <- readRDS(doc_p) %>%
            transmute(PATID = as.character(PATID), EVTID = as.character(EVTID),
                      native_eltid = as.character(ELTID), RECDATE = as.Date(RECDATE),
                      RECTYPE = as.character(RECTYPE), RECTXT = as.character(RECTXT)) %>%
            semi_join(all_tasks, by = c("PATID", "EVTID")) %>%   # same-event docs only
            filter(grepl(ana_rx, RECTXT, ignore.case = TRUE))

        events_with_docs <- docs %>% distinct(PATID, EVTID)
        cand_tasks <- all_tasks %>% semi_join(events_with_docs, by = c("PATID", "EVTID"))
        set.seed(cfg$seed)
        tasks <- cand_tasks[sample(nrow(cand_tasks), min(cfg$n, nrow(cand_tasks))), ,
                            drop = FALSE]

        raw <- docs %>%
            semi_join(tasks, by = c("PATID", "EVTID")) %>%
            group_by(PATID, EVTID) %>% slice_head(n = cfg$max_docs) %>% ungroup() %>%
            mutate(ELTID = sprintf("E%06d", row_number()))
        docs_index <- raw %>% transmute(ELTID, PATID, EVTID, RECDATE, RECTYPE)

        list(
            cohort = tasks,
            sources = list(documents = list(corpus = make_docs_corpus(raw),
                                            docs_index = docs_index)),
            spec = variable_spec(
                template = recipient_anastomoses_template(),
                name = "recipient_anastomoses", output_one_row_per = "PATID",
                anchor = "anchor_date"),
            save_extra = list(
                native_eltid = raw[, c("ELTID", "native_eltid", "PATID", "EVTID")]))
    })

# ---- select the case ----------------------------------------------------------
args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 1L || !args[[1]] %in% names(CASES)) {
    stop("Usage: Rscript scripts/run_variable_real.R <case>\n  cases: ",
         paste(names(CASES), collapse = " | "), call. = FALSE)
}
case_name <- args[[1]]
case <- CASES[[case_name]]

# ---- engine (same chain as tests/testthat.R, no test-only files) --------------
source("config/paths.R")
for (f in c("R/retrieval.R", "R/extract.R", "R/data.R", "R/structured.R",
            "R/channel-combine.R", "R/hitset.R", "R/spec.R", "R/channels.R",
            "R/operators.R", "R/run_variable.R", case$engine_files)) {
    source(f)
}

# ---- config -------------------------------------------------------------------
MODEL <- "gemma3:4b"                                       # grammar-enforced (vetted)
cfg <- list(
    n        = as.integer(Sys.getenv("REAL_N", case$defaults$n)),
    max_docs = as.integer(Sys.getenv("MAX_DOCS", case$defaults$max_docs)),
    seed     = as.integer(Sys.getenv("SMOKE_SEED", "20260625")))
OUT_DIR <- "outputs"
dir.create(OUT_DIR, showWarnings = FALSE, recursive = TRUE)

# ---- build + run --------------------------------------------------------------
built <- case$build(cfg)
spec  <- built$spec
caller <- make_ollama_caller(model = MODEL, seed = cfg$seed,
                             max_tokens = case$defaults$max_tokens)

cat(sprintf("Real run | case=%s | model=%s | tasks=%d | seed=%d\n",
            case_name, MODEL, nrow(built$tasks), cfg$seed))
cat(sprintf("variable=%s channels=%s output=%s window=%s\n\n",
            spec$name, paste(names(spec$channels), collapse = "+"),
            if (is.null(spec$output)) "(combine)" else spec$output$kind,
            if (is.null(spec$window)) "NULL (event scope)"
            else sprintf("[%d,%+d]d", spec$window$from_days, spec$window$to_days)))

t0  <- Sys.time()
run <- run_variable(spec, built$tasks, built$sources, caller = caller,
                    model_name = MODEL)
secs <- as.numeric(difftime(Sys.time(), t0, units = "secs"))

# ---- per-row detail (PHI) -> outputs/ only -------------------------------------
stamp <- format(Sys.time(), "%Y%m%d_%H%M%S")
out_p <- file.path(OUT_DIR, sprintf("%s_realrun_%s.rds", case_name, stamp))
saveRDS(c(list(spec = spec, run = run), built$save_extra), out_p)

# ---- aggregate report (SAFE: counts/rates only, no PHI) ------------------------
# Generic over the run envelope: no per-case report code.
dist_line <- function(x) {
    t <- table(x, useNA = "ifany")
    paste(sprintf("%s=%d", ifelse(is.na(names(t)), "NA", names(t)), as.integer(t)),
          collapse = "  ")
}
val <- run$values; ss <- run$channel_status
cat("================ REAL-RUN REPORT (aggregates only) ================\n")
cat(sprintf("tasks processed ......... %d\n", length(unique(val$task_id))))
if ("value" %in% names(val)) {
    v <- if (!is.null(spec$output) && identical(spec$output$kind, "categorical")) {
        factor(val$value, levels = spec$output$levels)
    } else val$value
    cat(sprintf("value distribution ...... %s\n", dist_line(v)))
}
if ("channel_coverage" %in% names(val)) {
    cat(sprintf("channel_coverage ........ %s\n", dist_line(val$channel_coverage)))
}
cat(sprintf("channel status .......... %s\n", dist_line(ss$status)))

if (!is.na(run$combine_rule)) {
    # Multi-channel: contribution per channel + attribution of positives to the
    # hitting-channel pattern (the cross-channel transparency).
    cat(sprintf("combine_rule ............ %s\n", run$combine_rule))
    cat("\n-- channel contribution --\n")
    for (chn in unique(ss$channel)) {
        cat(sprintf("  %-24s %s\n", chn, dist_line(ss$contribution[ss$channel == chn])))
    }
    pos <- val$task_id[val$value %in% 1L]
    if (length(pos)) {
        pattern <- vapply(pos, function(tid) {
            hits <- sort(ss$channel[ss$task_id == tid & ss$hit %in% TRUE])
            if (length(hits)) paste(hits, collapse = "+") else "(none)"
        }, character(1))
        cat(sprintf("\npositives attributed:  %s\n", dist_line(pattern)))
    }
}
if ("needs_review" %in% names(val)) {
    cat(sprintf("needs_review ............ %d\n", sum(val$needs_review, na.rm = TRUE)))
}
if ("citation_warning" %in% names(val)) {
    cat(sprintf("citation_warning ........ %d\n", sum(val$citation_warning, na.rm = TRUE)))
}
if ("field" %in% names(val)) {
    # fields output: per-field acceptance (documented / invalid / total tasks).
    cat("\n-- per field: documented (extracted value) / invalid / tasks --\n")
    if (nrow(val)) {
        by_field <- val %>% group_by(field) %>%
            summarise(documented = sum(!is.na(value)),
                      invalid = sum(field_validity == "invalid"),
                      n = n(), .groups = "drop")
        for (i in seq_len(nrow(by_field))) {
            cat(sprintf("  %-50s documented=%d  invalid=%d  / %d\n",
                        by_field$field[i], by_field$documented[i],
                        by_field$invalid[i], by_field$n[i]))
        }
    } else cat("  (no fields produced)\n")
}
if (nrow(run$evidence)) {
    cat(sprintf("tasks with evidence ..... %d / %d\n",
                length(unique(run$evidence$task_id)), length(unique(val$task_id))))
}
cat(sprintf("wall time ............... %.1fs\n", secs))
cat(sprintf("\nPer-row detail (PHI) -> %s (gitignored)\n", out_p))
cat("===================================================================\n")
