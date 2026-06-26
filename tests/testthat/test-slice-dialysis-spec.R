# Contract tests for slice 4: dialysis as multi-source OR (any_positive) with
# TRANSPARENT source contribution. The point is not conflict handling; it is that
# the envelope exposes which channel carried the signal, which were silent and WHY,
# evidence refs for the positive channel(s), and the researcher's combine rule.
# Synthetic data, deterministic fake model.

dia_tasks <- tibble::tibble(
    task_id = paste0("DG", 1:4, "::t"),
    PATID = paste0("P", 1:4),
    anchor_date = as.Date("2024-06-01"))

# P1: dialysis ICD-10 in window (signal). P2/P4: a non-dialysis code in window
# (ascertained negative). P3: NO diagnosis rows at all (no source for the subject).
dia_diag <- tibble::tibble(
    source_row_id = sprintf("diag:%03d", 1:3),
    PATID = c("P1", "P2", "P4"),
    EVTID = c("E1", "E2", "E4"),
    ELTID = c("D1", "D2", "D4"),
    diag = c("Z99.2", "I10", "I10"),
    DATENT = as.Date("2024-05-20"),
    DATSORT = as.Date("2024-05-21"))

# DG2 -> documented dialysis text (signal). DG4 -> not_documented (negative).
# DG1/DG3 -> no_candidate (the text channel is silent, nothing retrieved).
dia_docs <- list(
    coverage = tibble::tibble(
        task_id = dia_tasks$task_id,
        coverage_state = c("no_candidate", "candidate", "no_candidate", "candidate")),
    candidates = tibble::tibble(
        task_id = c("DG2::t", "DG4::t"),
        snippet_id = "S001",
        hit_ref = c("DOC2::3", "DOC4::3"),
        ELTID = c("DOC2", "DOC4"),
        sentence = 3L,
        hit_text = "dialyse.",
        snippet_text = "Patient en hemodialyse chronique.",
        RECDATE = as.Date("2024-05-15"),
        RECTYPE = "note"))

dia_sources <- list(pmsi_diag = dia_diag, documents = dia_docs)

# dialysis_text_definition()'s prompt echoes the task id, so the fake keys on it.
dia_fake <- function(prompt, type, system_prompt) {
    if (grepl("DG2::t", prompt, fixed = TRUE)) {
        return(list(dialysis_status = "documented", evidence_ids = list("S001")))
    }
    list(dialysis_status = "not_documented", evidence_ids = list())   # DG4
}

dia_var <- function() {
    variable_spec(
        template = dialysis_status_template(),
        name = "dialysis_status", unit = "transplant", anchor = "anchor_date")
}

# Why: dialysis is OR'd across ICD-10 + text with the researcher's any_positive().
# A positive in either source yields 1; absence stays open-world (NA when a source
# was merely silent, 0 only when every source ascertained a negative).
test_that("dialysis multi-source OR yields the expected values and channel coverage", {
    run <- run_variable(dia_var(), dia_tasks, dia_sources,
                        caller = dia_fake, model_name = "fake")
    value <- setNames(run$values$value, run$values$task_id)
    cov <- setNames(run$values$channel_coverage, run$values$task_id)

    expect_equal(value[["DG1::t"]], 1L)        # ICD-10 only
    expect_equal(value[["DG2::t"]], 1L)        # text only
    expect_equal(value[["DG3::t"]], 0L)        # both silent -> no observed hit -> 0 (coverage partial)
    expect_equal(value[["DG4::t"]], 0L)        # both ascertained negative

    expect_equal(cov[["DG1::t"]], "partial")   # text was silent
    expect_equal(cov[["DG2::t"]], "complete")
    expect_equal(cov[["DG3::t"]], "partial")   # neither channel evaluable -> uncertainty here, not in value
    expect_equal(cov[["DG4::t"]], "complete")

    # any_positive() lowered to a hit-set expression; combine_rule exposes the raw rule.
    expect_equal(run$combine_rule, "pmsi_diag_dialysis | text_dialysis_mentions")
    expect_equal(run$selected_channels$channel,
                 c("pmsi_diag_dialysis", "text_dialysis_mentions"))
})

# Why: THE point of this slice -- source contribution must be transparent. The
# engine exposes which channel carried the signal, which were silent and WHY
# (no source rows vs nothing retrieved), and evidence only for positive channels.
# It does NOT estimate certainty.
test_that("source contribution is transparent per channel", {
    run <- run_variable(dia_var(), dia_tasks, dia_sources,
                        caller = dia_fake, model_name = "fake")
    ss <- run$channel_status
    get <- function(tid, ch, col) ss[[col]][ss$task_id == tid & ss$channel == ch]

    # DG1: the `1` came ONLY from ICD-10; documents were silent (nothing retrieved).
    expect_equal(get("DG1::t", "pmsi_diag_dialysis", "contribution"), "signal")
    expect_equal(get("DG1::t", "pmsi_diag_dialysis", "processing_state"), "measured")
    expect_equal(get("DG1::t", "text_dialysis_mentions", "contribution"), "silent")
    expect_equal(get("DG1::t", "text_dialysis_mentions", "processing_state"), "no_candidate")
    ev1 <- run$evidence[run$evidence$task_id == "DG1::t", ]
    expect_equal(ev1$channel, "pmsi_diag_dialysis")   # evidence only for the positive channel
    expect_equal(ev1$evidence_ref, "diag:001")

    # DG2: the `1` came only from text; ICD-10 ascertained a negative.
    expect_equal(get("DG2::t", "pmsi_diag_dialysis", "contribution"), "negative")
    expect_equal(get("DG2::t", "text_dialysis_mentions", "contribution"), "signal")

    # DG3: BOTH silent, but for DIFFERENT reasons -- the granular state is preserved,
    # not collapsed to a bare "unavailable".
    expect_equal(get("DG3::t", "pmsi_diag_dialysis", "contribution"), "silent")
    expect_equal(get("DG3::t", "pmsi_diag_dialysis", "processing_state"), "no_eligible_source")
    expect_equal(get("DG3::t", "text_dialysis_mentions", "contribution"), "silent")
    expect_equal(get("DG3::t", "text_dialysis_mentions", "processing_state"), "no_candidate")

    # DG4: both channels ascertained a negative.
    expect_equal(get("DG4::t", "pmsi_diag_dialysis", "contribution"), "negative")
    expect_equal(get("DG4::t", "text_dialysis_mentions", "contribution"), "negative")
})

# Why: when the text channel retrieves NOTHING for any task, run_extraction returns
# COLUMN-LESS empty values/evidence. The OR reducer must handle that cleanly -- no
# spurious "Unknown or uninitialised column: task_id" warning (regression surfaced by
# a real-data multi-source run). The code channel still drives the result and the text
# channel is transparently silent.
test_that("multi-source OR is warning-clean when the text channel is entirely silent", {
    docs_all_silent <- list(
        coverage = tibble::tibble(task_id = dia_tasks$task_id, coverage_state = "no_candidate"),
        candidates = tibble::tibble())
    sources <- list(pmsi_diag = dia_diag, documents = docs_all_silent)

    run <- expect_no_warning(
        run_variable(dia_var(), dia_tasks, sources, caller = dia_fake, model_name = "fake"))

    value <- setNames(run$values$value, run$values$task_id)
    expect_equal(value[["DG1::t"]], 1L)        # ICD-10 carries it; text silent
    expect_equal(value[["DG3::t"]], 0L)        # no code rows + text silent -> no observed hit -> 0
    txt <- run$channel_status[run$channel_status$channel == "text_dialysis_mentions", ]
    expect_true(all(txt$contribution == "silent"))
    expect_true(all(txt$processing_state == "no_candidate"))
})
