# Whole-history ("ever") variant: the unanchored axis. anchor = none, window = none,
# scope = the subject's ENTIRE record. diabetes_ever contrasts with the windowed
# diabete_pre_greffe -- same concept + channel, different anchor/window choice at
# the variable level. Synthetic deterministic data.

# Tasks carry NO anchor_date -- whole-history variables have no anchor.
wh_tasks <- tibble::tibble(
    task_id = paste0("Q", 1:4),
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
        unit = "patient",
        anchor = NULL,                 # no anchor
        window = NULL,                 # whole history
        channels = list(pmsi_diag_e10_e14 = use_channel()),
        output = bin_output())         # single channel -> combine = NULL (membership)
}

# Why: a whole-history variable must execute with no anchor and no date window,
# scoping the subject's entire record. A diabetes code anywhere -> present; a record
# with only non-diabetes codes -> ascertained negative; no rows -> not ascertained.
test_that("diabetes_ever scopes the whole history with no anchor/window", {
    var <- wh_variable()
    expect_null(var$window)
    expect_null(var$anchor)

    run <- run_variable(var, wh_tasks, wh_sources)   # no caller: structured only

    value <- setNames(run$values$value, run$values$task_id)

    expect_equal(value[["Q4"]], 1L)        # 2005 code still counts (no window)

    expect_true(is.na(run$combine_rule))
    expect_equal(run$evidence$evidence_ref[run$evidence$task_id == "Q4"], "diag:003")
})

# ---------------------------------------------------------------------------
# Whole-history TEXT: the SAME unanchored axis over a TEXT channel. This guards the
# distinct invariant that no-window subject text eligibility scopes the subject's
# ENTIRE document record (the text mirror of diabetes_ever): a matching document of
# ANY age is retrieved, because whole history applies no date filter.
#
# The variable below is a DISPOSABLE PROBE, not shipped machinery: "whole-history
# text" is JUST a variable_spec with window = NULL over a text channel. The engine
# gains a generic capability; nothing concept-specific is added. An existing concept
# is reused only to pose the demand through the public run_variable() surface.

wht_tasks <- tibble::tibble(
    task_id = c("Q1", "Q3", "Q4"),
    PATID   = c("Q1", "Q3", "Q4"))          # no anchor_date -- whole history

# Q1: recent diabetes note. Q4: a 2005 note -- OLD, but no window, so it still counts.
# Q3: no documents at all (open-world "not ascertained", not an absence).
wht_docs_index <- tibble::tibble(
    ELTID   = c("D1", "D4"),
    PATID   = c("Q1", "Q4"),
    EVTID   = c("V1", "V4"),
    RECDATE = as.Date(c("2024-02-01", "2005-06-01")),
    RECTYPE = "note")
wht_corpus <- corpustools::create_tcorpus(
    data.frame(
        ELTID  = c("D1", "D4"),
        RECTXT = c("Patient diabetique connu, suivi regulier.",
                   "Diabete de type 2 ancien documente en 2005."),
        stringsAsFactors = FALSE),
    text_columns = "RECTXT", doc_column = "ELTID",
    split_sentences = TRUE, remember_spaces = FALSE, verbose = FALSE)

wht_sources <- list(documents = list(corpus = wht_corpus, docs_index = wht_docs_index))

# Fake caller (no real model): any retrieved diabetes snippet -> documented.
wht_fake <- function(prompt, type, system_prompt) {
    if (grepl("diabet", prompt, ignore.case = TRUE)) {
        list(diabetes_status = "documented", evidence_ids = list("S001"))
    } else {
        list(diabetes_status = "not_documented", evidence_ids = list())
    }
}

wht_variable <- function() {
    variable_spec(
        name = "diabetes_mention_ever",
        concept = diabetes_concept_spec(),
        unit = "patient",
        anchor = NULL,                 # no anchor
        window = NULL,                 # whole history
        channels = list(text_diabetes_mentions =
                            use_channel(method = llm_after_lucene())),
        output = bin_output())         # single channel -> membership
}

# Why: a whole-history TEXT variable must execute with no anchor and no window,
# retrieving from the subject's ENTIRE document record. A matching note of any age
# -> present; a subject with no documents -> not ascertained (partial), not absent.
test_that("whole-history text scopes the subject's entire document record (no window)", {
    var <- wht_variable()
    expect_null(var$window)
    expect_null(var$anchor)

    run <- run_variable(var, wht_tasks, wht_sources,
                        caller = wht_fake, model_name = "fake")

    value <- setNames(run$values$value, run$values$task_id)
    coverage <- setNames(run$values$channel_coverage, run$values$task_id)

    expect_equal(value[["Q1"]], 1L)              # recent mention -> present
    expect_equal(value[["Q4"]], 1L)              # 2005 mention still counts (no window)
    expect_equal(coverage[["Q3"]], "partial")    # no document -> not ascertained

    # Q4's positive is grounded by a real retrieved sentence from the 2005 note.
    ev4 <- run$evidence[run$evidence$task_id == "Q4", ]
    expect_equal(nrow(ev4), 1L)
    expect_match(ev4$evidence_ref, "^D4::")
})
