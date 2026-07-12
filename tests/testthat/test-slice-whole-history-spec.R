# Whole-history ("ever") variant: the unanchored axis. anchor = none, window = none,
# scope = the subject's ENTIRE record. diabetes_ever contrasts with the windowed
# diabete_pre_greffe -- same concept + channel, different anchor/window choice at
# the variable level. Synthetic deterministic data.

# Tasks carry NO anchor_date -- whole-history variables have no anchor.
wh_tasks <- tibble::tibble(
    grain_id = paste0("Q", 1:4),
    PATID = paste0("Q", 1:4))

# Q1: a diabetes code. Q2: a non-diabetes code (ascertained negative). Q3: NO rows.
# Q4: a diabetes code from 2005 -- old, but whole-history has no window, so it counts.
wh_diag <- tibble::tibble(
    source_row_id = sprintf("diag:%03d", 1:3),
    PATID = c("Q1", "Q2", "Q4"),
    EVTID = c("V1", "V2", "V4"),
    ELTID = c("L1", "L2", "L4"),
    diag = c("E11.9", "I10", "E10"),
    DATENT = as.Date(c("2023-01-01", "2023-01-01", "2005-06-01")),
    DATSORT = as.Date(c("2023-01-02", "2023-01-02", "2005-06-02")))

wh_sources <- list(pmsi_diag = wh_diag)

wh_variable <- function() {
    variable_spec(
        name = "diabetes_ever",
        concept = diabetes_concept_spec(),
        output_one_row_per = "PATID",
        anchor = NULL,                 # no anchor
        window = NULL,                 # whole history
        channels = list(pmsi_diag_e10_e14 = use_channel()),
        output = bin_output())         # single channel -> combine_channels = NULL (membership)
}

# Why: a whole-history variable must execute with no anchor and no date window,
# scoping the subject's entire record. A diabetes code anywhere -> present; a record
# with only non-diabetes codes -> ascertained negative; no rows -> not ascertained.
test_that("diabetes_ever scopes the whole history with no anchor/window", {
    var <- wh_variable()
    expect_null(var$window)
    expect_null(var$anchor)

    run <- run_variable(var, wh_tasks, wh_sources)   # no caller: structured only

    value <- setNames(run$values$value, run$values$grain_id)

    expect_equal(value[["Q4"]], 1L)        # 2005 code still counts (no window)

    expect_true(is.na(run$combine_rule))
    expect_equal(run$evidence$evidence_ref[run$evidence$grain_id == "Q4"], "diag:003")
})

# ---------------------------------------------------------------------------
# Whole-history TEXT eligibility invariant (the ONE thing unique to the no-window
# branch of .retrieve_text_channel): no-window subject text scopes the subject's
# ENTIRE record, so a document any date window would EXCLUDE (here a 2005 note) is
# still retrieved and extracted. Recent-mention->present, evidence grounding, and
# open-world "no document -> partial" are already guarded by
# test-slice-retrieval-wiring.R and the structured whole-history test above, so they
# are NOT re-asserted here. The variable is a disposable probe (window = NULL over an
# existing text channel), not shipped machinery.

wht_tasks <- tibble::tibble(grain_id = "Q4", PATID = "Q4")   # no anchor_date

# A single OLD note (2005): any window would drop it; whole history keeps it.
wht_docs_index <- tibble::tibble(
    ELTID = "D4", PATID = "Q4", EVTID = "V4",
    RECDATE = as.Date("2005-06-01"), RECTYPE = "note")
wht_corpus <- corpustools::create_tcorpus(
    data.frame(ELTID = "D4",
               RECTXT = "Diabete de type 2 ancien documente en 2005.",
               stringsAsFactors = FALSE),
    text_columns = "RECTXT", doc_column = "ELTID",
    split_sentences = TRUE, remember_spaces = FALSE, verbose = FALSE)
wht_sources <- list(documents = list(corpus = wht_corpus, docs_index = wht_docs_index))

wht_fake <- function(prompt, type, system_prompt) {
    list(diabetes_status = "documented", evidence_ids = list("S001"))
}

wht_variable <- function() {
    variable_spec(
        name = "diabetes_mention_ever",
        concept = diabetes_concept_spec(),
        output_one_row_per = "PATID", anchor = NULL, window = NULL,   # whole history
        channels = list(text_diabetes_mentions =
                            use_channel(method = llm_after_lucene(function(x) x))),
        output = bin_output())                            # single channel -> membership
}

# Why: if the no-window branch is broken or reverted, run_variable() either errors
# (the old stop) or applies a window that drops the 2005 note -> value 0. value == 1
# is reachable only when the whole record is in scope. (value == 1 also implies real
# grounding: binary presence is invalid without a resolved evidence id.)
test_that("no-window subject text retrieves a document any window would exclude", {
    run <- run_variable(wht_variable(), wht_tasks, wht_sources,
                        chat = fake_chat(wht_fake))
    value <- setNames(run$values$value, run$values$grain_id)
    expect_equal(value[["Q4"]], 1L)
})
