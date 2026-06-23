# Multi-source diabetes (binary) SPIKE — documents OR pmsi OR biology -> 1.
# Proves the production seam ba9f171 skipped: three HETEROGENEOUS real source paths
# (LLM text via a fake caller, ICD-10 over PMSI, high glucose over biology) each
# reduced to {status, hit, evidence} and combined by combine_any_source_hit. The
# document model is a deterministic fake — we test the SEAM, not extraction quality.
# All windows are relative to ONE fixed arbitrary anchor, so out-of-window evidence
# (high glucose / E11 dated years off) must NOT count.

ANCHOR        <- as.Date("2024-06-01")  # arbitrary fixed point; every window is relative to it
IN_WIN        <- as.Date("2024-05-15")  # inside both the pmsi (-1825d) and biology (-365d) windows
PRE_WIN_PMSI  <- as.Date("2010-01-01")  # before the pmsi window
PRE_WIN_BIOL  <- as.Date("2020-01-01")  # before the biology window

ms_tasks <- tibble::tibble(
    task_id = paste0("P", 1:8, "::t"), PATID = paste0("P", 1:8), anchor_date = ANCHOR)

# PMSI diagnosis rows (one per patient; P7's diabetes code is OUT of the window).
ms_diag <- tibble::tibble(
    source_row_id = sprintf("diag:%03d", 1:8),
    PATID = paste0("P", 1:8), EVTID = paste0("EV", 1:8), ELTID = paste0("EL", 1:8),
    #         P1     P2     P3     P4     P5     P6     P7      P8
    diag   = c("I10", "E11", "I10", "I10", "E11", "I10", "E11", "I10"),
    DATENT = c(IN_WIN, IN_WIN, IN_WIN, IN_WIN, IN_WIN, IN_WIN, PRE_WIN_PMSI, IN_WIN),
    DATSORT = c(IN_WIN, IN_WIN, IN_WIN, IN_WIN, IN_WIN, IN_WIN, PRE_WIN_PMSI, IN_WIN))

# Biology glucose rows. P6 has NO biology row -> that source is UNAVAILABLE for P6.
# P7's high glucose is OUT of window; P8 sits exactly on the strict-> threshold.
ms_biol <- tibble::tibble(
    source_row_id = sprintf("biol:%03d", 1:7),
    PATID = c("P1", "P2", "P3", "P4", "P5", "P7", "P8"),
    EVTID = paste0("EV", 1:7), ELTID = paste0("EL", 1:7), BIOL_ID = paste0("B", 1:7),
    DATEXAM = c(IN_WIN, IN_WIN, IN_WIN, IN_WIN, IN_WIN, PRE_WIN_BIOL, IN_WIN),
    analyte = "GLU.GLU",
    value_raw = c("5.0", "5.0", "9.0", "5.0", "5.0", "9.0", "7.0"),
    value     = c(5.0,   5.0,   9.0,   5.0,   5.0,   9.0,   7.0))

# Documents: only P1 (positive) and P5 (the model errors) reach the model. For the
# others, no_candidate means "no diabetes text was retrieved", not automatically
# "no diabetes". ms_run() exposes the project decision for mapping that state.
ms_doc_coverage <- tibble::tibble(
    task_id = paste0("P", 1:8, "::t"),
    coverage_state = c("candidate", "no_candidate", "no_candidate", "no_candidate",
                       "candidate", "no_candidate", "no_candidate", "no_candidate"))
ms_doc_candidates <- tibble::tibble(
    task_id = c("P1::t", "P5::t"), snippet_id = c("S001", "S001"),
    hit_ref = c("EL1::3", "EL5::2"), ELTID = c("EL1", "EL5"), sentence = c(3L, 2L),
    hit_text = c("diabete", "note"),
    snippet_text = c("Patient diabetique sous metformine.", "Compte rendu operatoire."),
    RECDATE = IN_WIN, RECTYPE = "CRO")
fake_docs <- function(prompt, type, system_prompt) {
    if (grepl("P5::t", prompt, fixed = TRUE)) stop("synthetic document extraction failure")
    if (grepl("P1::t", prompt, fixed = TRUE))
        return(list(diabetes_status = "documented", evidence_ids = list("S001")))
    list(diabetes_status = "not_documented", evidence_ids = list())
}

ms_run <- function(
    document_no_candidate = c("unavailable", "complete"),
    incomplete_value = NA_integer_) {
    document_no_candidate <- match.arg(document_no_candidate)
    docs <- run_extraction(ms_doc_coverage, ms_doc_candidates,
                           diabetes_text_definition(), fake_docs, "fake")
    pmsi <- measure_diabetes(ms_diag, ms_tasks, codes = c("E10", "E11", "E12", "E13", "E14"),
                             from_days = -1825L, to_days = 7L)
    biol <- measure_diabetes_glucose(ms_biol, ms_tasks, analytes = "GLU.GLU",
                                     threshold = 7.0, from_days = -365L, to_days = 7L)
    combine_diabetes_any(ms_tasks, list(
        documents = reduce_text_source(
            docs, ms_tasks$task_id,
            no_candidate_status = document_no_candidate),
        pmsi      = reduce_structured_source(pmsi, ms_tasks$task_id),
        biology   = reduce_structured_source(biol, ms_tasks$task_id)),
        incomplete_value = incomplete_value)
}

# Why: the OR variable must preserve positive evidence from any source while keeping
# failure to retrieve diabetes text distinct from a documented negative. This protects
# the conservative default: text no_candidate does not prove absence.
test_that("any of documents/pmsi/biology establishes diabetes=1, relative to a fixed anchor", {
    combined <- ms_run()
    v <- setNames(combined$values$diabetes_any, combined$values$task_id)
    a <- setNames(combined$values$ascertainment, combined$values$task_id)

    expect_equal(v[["P1::t"]], 1L);   expect_equal(a[["P1::t"]], "complete")  # documents only
    expect_equal(v[["P2::t"]], 1L);   expect_equal(a[["P2::t"]], "partial")   # pmsi only
    expect_equal(v[["P3::t"]], 1L);   expect_equal(a[["P3::t"]], "partial")   # biology only
    expect_true(is.na(v[["P4::t"]])); expect_equal(a[["P4::t"]], "partial")   # no text hit != absence
    expect_equal(v[["P5::t"]], 1L);   expect_equal(a[["P5::t"]], "partial")   # pmsi hit despite doc error
    expect_true(is.na(v[["P6::t"]])); expect_equal(a[["P6::t"]], "partial")   # biology unavailable -> not 0
    expect_true(is.na(v[["P7::t"]])); expect_equal(a[["P7::t"]], "partial")   # out-of-window hits excluded
    expect_true(is.na(v[["P8::t"]])); expect_equal(a[["P8::t"]], "partial")   # glucose == threshold
})

# Why: treating absence of retrieved document evidence as absence of diabetes can be a
# legitimate study rule, but it must be selected explicitly. This prevents an engine
# default from silently deciding the scientific meaning of missing text evidence.
test_that("project policy may treat document no_candidate as a completed negative", {
    combined <- ms_run(document_no_candidate = "complete")
    v <- setNames(combined$values$diabetes_any, combined$values$task_id)
    a <- setNames(combined$values$ascertainment, combined$values$task_id)

    expect_equal(v[["P4::t"]], 0L)
    expect_equal(a[["P4::t"]], "complete")
    expect_equal(v[["P7::t"]], 0L)
    expect_equal(v[["P8::t"]], 0L)
})

# Why: a positive in one source must survive another source's failure, source
# unavailability must stay distinct from a negative, and combined evidence must
# name the originating source and its native row key.
test_that("multi-source diabetes keeps per-source status and positive provenance", {
    combined <- ms_run()
    ss <- combined$source_status
    p5 <- ss[ss$task_id == "P5::t", ]
    expect_equal(p5$status[p5$source == "documents"], "error")   # doc model errored
    expect_true(p5$hit[p5$source == "pmsi"])                     # pmsi still positive
    p6 <- ss[ss$task_id == "P6::t", ]
    expect_equal(p6$status[p6$source == "biology"], "unavailable")

    ev <- combined$evidence
    expect_equal(ev$source[ev$task_id == "P1::t"], "documents")  # provenance by source
    expect_equal(ev$source[ev$task_id == "P2::t"], "pmsi")
    expect_equal(ev$source[ev$task_id == "P3::t"], "biology")
    expect_equal(ev$source_row_id[ev$task_id == "P2::t"], "diag:002")
    expect_equal(nrow(ev[ev$task_id == "P4::t", ]), 0L)          # unresolved carries no positive evidence
})
