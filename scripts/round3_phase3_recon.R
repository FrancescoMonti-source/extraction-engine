#!/usr/bin/env Rscript
# Corrected Phase 3, run off the PERSISTED canonical corpus (no rebuild).
# Reconstructs only hit sentences +/-1 (not whole documents). Counts only to
# console; reconstructed PHI sentences -> outputs/ (gitignored).
suppressWarnings(suppressMessages({
    library(dplyr); library(stringr); library(corpustools)
    stopifnot(packageVersion("corpustools") == "0.5.2")
}))

source("config/paths.R")  # single source of truth for DATASETS / path_data()
OUT_DIR  <- file.path("outputs", "round3-experiments")
WIN_PRE <- 365L; WIN_POST <- 7L
SMOKING_QUERY <- paste(
    "tabac*", "tabagi*", "fumeu*", "sevr*", "cigarette*", "paquet*",
    "<(0* OR 1* OR 2* OR 3* OR 4* OR 5* OR 6* OR 7* OR 8* OR 9*) PA>",
    "(0*PA OR 1*PA OR 2*PA OR 3*PA OR 4*PA OR 5*PA OR 6*PA OR 7*PA OR 8*PA OR 9*PA)",
    sep = " OR ")
elapsed <- function(expr) as.numeric(system.time(expr)["elapsed"])
untokenize <- function(toks) {
    s <- paste(toks, collapse = " ")
    s <- gsub(" ([,.;:!?%)\\]}])", "\\1", s, perl = TRUE)
    s <- gsub("([(\\[{]) ", "\\1", s, perl = TRUE)
    s <- gsub(" ?- ?", "-", s); s <- gsub(" ?' ?", "'", s)
    trimws(gsub("\\s+", " ", s))
}
clean_mixed_date <- function(x) {
    if (inherits(x, "Date")) return(x)
    x <- trimws(as.character(x)); out <- rep(as.Date(NA), length(x))
    is_num <- grepl("^\\d+(\\.\\d+)?$", x)
    out[is_num] <- as.Date(as.numeric(x[is_num]), origin = "1899-12-30")
    is_txt <- !is_num & nzchar(x); out[is_txt] <- as.Date(substr(x[is_txt], 1, 10)); out
}

# tasks + eligible docs (cohort + in-window) for the fast subset search path
ch <- openxlsx::read.xlsx(path_data("D0840", "chirurgie.xlsx")) %>%
    mutate(DATEACTE = clean_mixed_date(DATEACTE))
tasks <- bind_rows(
    ch %>% transmute(DATEACTE, role = "donneur",  PATID = as.character(PATID_donneur)),
    ch %>% transmute(DATEACTE, role = "receveur", PATID = as.character(PATID_receveur))
) %>% filter(!is.na(PATID), PATID != "", !is.na(DATEACTE)) %>% distinct()
doc_meta <- readRDS(path_data("D0840", "docs")) %>%
    transmute(ELTID = as.character(ELTID), PATID = as.character(PATID),
              RECDATE = as.Date(RECDATE), RECTXT = as.character(RECTXT)) %>%
    filter(nzchar(trimws(RECTXT))) %>% distinct(ELTID, PATID, RECDATE)
eligible_ids <- doc_meta %>%
    inner_join(tasks, by = "PATID", relationship = "many-to-many") %>%
    filter(RECDATE >= DATEACTE - WIN_PRE, RECDATE <= DATEACTE + WIN_POST) %>%
    distinct(ELTID) %>% pull(ELTID)

load_s <- elapsed(tc <- readRDS(file.path(OUT_DIR, "canonical_tcorpus.rds")))
sub <- tc$subset(subset_meta = doc_id %in% eligible_ids, copy = TRUE)
h1 <- as.data.frame(search_contexts(sub, SMOKING_QUERY,
                                    context_level = "sentence", as_ascii = FALSE)$hits)

hit_docs <- unique(as.character(h1$doc_id))
hit_sent <- h1 %>% transmute(doc_id = as.character(doc_id), sentence = as.integer(sentence))
targets <- bind_rows(hit_sent,
                     hit_sent %>% mutate(sentence = sentence - 1L),
                     hit_sent %>% mutate(sentence = sentence + 1L)) %>%
    filter(sentence >= 1L) %>% distinct()

recon_s <- elapsed({
    tok_target <- sub$tokens %>% as.data.frame() %>%
        transmute(doc_id = as.character(doc_id), sentence = as.integer(sentence),
                  token_id = as.integer(token_id), token = as.character(token)) %>%
        semi_join(targets, by = c("doc_id", "sentence")) %>%
        arrange(doc_id, sentence, token_id)
    sent_text <- tok_target %>% group_by(doc_id, sentence) %>%
        summarise(text = untokenize(token), .groups = "drop")
})
saveRDS(sent_text, file.path(OUT_DIR, "hit_sentences_normalized.rds"))

cat("=============== PHASE 3 (corrected: hit sentences +/-1) ===============\n")
cat(sprintf("persisted-corpus load=%.1fs\n", load_s))
cat(sprintf("hit docs=%d | hit sentences=%d | target sentences (hit +/-1)=%d\n",
            length(hit_docs), nrow(hit_sent), nrow(targets)))
cat(sprintf("reconstructed sentences=%d | %.1fs\n", nrow(sent_text), recon_s))
cat(sprintf("vs over-reconstruction (all sentences in hit docs) = 1,682,707 in 212.5s\n"))
cat("======================================================================\n")
