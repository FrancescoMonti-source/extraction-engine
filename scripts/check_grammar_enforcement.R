#!/usr/bin/env Rscript
# =============================================================================
# Model-vetting gate: does Ollama actually GRAMMAR-CONSTRAIN this model?
# -----------------------------------------------------------------------------
# The whole pipeline assumes the JSON schema is enforced by a grammar (illegal
# tokens masked before sampling), so a constrained model can NEVER answer in
# prose. Some models break that assumption — notably "thinking"/reasoning models
# (gemma4, gpt-oss), whose unconstrained reasoning text escapes the grammar.
#
# This makes a bare structured call (NO system prompt to lean on) under DEFAULT
# stochastic sampling, repeated N times, and counts prose escapes. A model with
# any prose escape is UNRELIABLE for grammar-dependent extraction — reject it,
# regardless of how good its accuracy looks behind a strong prompt.
#
# Run:  Rscript scripts/check_grammar_enforcement.R
#       SMOKE_MODELS="gemma3:4b,gemma4,mistral" GRAMMAR_N=20 Rscript ...
# Note: ellmer strips the :latest tag — pass "gemma4"/"mistral", not "*:latest".
# =============================================================================

stopifnot(requireNamespace("ellmer", quietly = TRUE))

MODELS <- strsplit(Sys.getenv("SMOKE_MODELS", "gemma3:4b,gemma4,gemma3:12b,mistral"), ",")[[1]]
N      <- as.integer(Sys.getenv("GRAMMAR_N", "12"))

# A constrained model cannot emit this prose; an unconstrained one will.
PROBE <- "My name is Susan and I'm 13 years old"
TYPE  <- ellmer::type_object(name = ellmer::type_string(), age = ellmer::type_number())

check <- function(m, n = N) {
  ok <- 0L; prose <- 0L; other <- 0L
  for (i in seq_len(n)) {
    r <- tryCatch({
      ch <- ellmer::chat_ollama(model = m, echo = "none")  # fresh chat, NO system prompt, default temp
      ch$chat_structured(PROBE, type = TYPE)
      "ok"
    }, error = function(e) if (grepl("invalid char|lexical", conditionMessage(e))) "prose" else "other")
    if (identical(r, "ok")) ok <- ok + 1L
    else if (identical(r, "prose")) prose <- prose + 1L
    else other <- other + 1L
  }
  verdict <- if (prose == 0L && other == 0L) "RELIABLE"
             else if (prose > 0L) "UNRELIABLE (prose escapes -> grammar not enforced)"
             else "FLAKY (non-prose errors)"
  cat(sprintf("%-14s ok=%2d/%d  prose-escape=%d  other=%d   -> %s\n", m, ok, n, prose, other, verdict))
}

cat(sprintf("Grammar-enforcement check | bare structured call, default sampling, n=%d each\n\n", N))
for (m in MODELS) tryCatch(check(m),
                           error = function(e) cat(sprintf("%-14s could not run: %s\n", m, conditionMessage(e))))
cat("\nReject any model that ever escapes to prose: its JSON comes from prompt-following,\nnot grammar enforcement, and will fail open on weak/long inputs.\n")
