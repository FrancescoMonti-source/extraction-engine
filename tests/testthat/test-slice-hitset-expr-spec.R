# Contract tests for bare-string hit-set combine.
# Why: combine is target-facing observed set algebra over activated channels. The
# durable public result is value + channel coverage; the raw membership audit keeps
# per-channel TRUE/FALSE/NA without exposing migration-era decision_state/role.

hx_concept <- function() {
    code_ch <- function(source, prefix) code_channel(
        source = source, selector = icd10(prefix),
        required_roles = c("subject_id", "event_id", "event_start", "event_end",
                           "code", "source_item_id"),
        linkage = "subject")
    concept_spec(
        name = "transplant_minus_dialysis",
        channels = list(
            transplant_act = code_ch("acts", "Z94"),
            dialysis_signal = code_ch("dialysis_dx", "Z99")))
}

hx_var <- function(expr = "transplant_act & !dialysis_signal",
                   channels = list(transplant_act = use_channel(),
                                   dialysis_signal = use_channel())) {
    variable_spec(
        name = "transplant_without_dialysis", concept = hx_concept(),
        unit = "transplant", anchor = "anchor_date",
        window = before_anchor(days = 1825L, grace_days = 7L),
        channels = channels, output = bin_output(),
        combine = expr)
}

hx_tasks <- tibble::tibble(
    task_id = paste0("HX", 1:4, "::t"),
    PATID = paste0("Q", 1:4),
    anchor_date = as.Date("2024-06-01"))

hx_row <- function(srid, patid, code) tibble::tibble(
    source_row_id = srid, PATID = patid, EVTID = paste0("E", patid),
    ELTID = paste0("L", srid), diag = code,
    DATENT = as.Date("2024-05-20"), DATSORT = as.Date("2024-05-21"))

hx_sources <- list(
    acts = dplyr::bind_rows(
        hx_row("acts:1", "Q1", "Z940"),  # included: act hit, dialysis negative
        hx_row("acts:2", "Q2", "Z940"),  # included: exclusion source unavailable
        hx_row("acts:3", "Q3", "Z940")), # excluded: dialysis hit
    dialysis_dx = dplyr::bind_rows(
        hx_row("dx:1", "Q1", "I10"),
        hx_row("dx:3", "Q3", "Z992"),
        hx_row("dx:4", "Q4", "I10")))

test_that("bare string combine returns value, coverage, and raw membership audit", {
    run <- run_variable(hx_var(), hx_tasks, hx_sources)

    expect_equal(
        setNames(run$values$value, run$values$task_id),
        c("HX1::t" = 1L, "HX2::t" = 1L, "HX3::t" = 0L, "HX4::t" = 0L))
    expect_equal(
        setNames(run$values$channel_coverage, run$values$task_id),
        c("HX1::t" = "complete", "HX2::t" = "partial",
          "HX3::t" = "complete", "HX4::t" = "partial"))
    expect_equal(run$combine_rule, "transplant_act & !dialysis_signal")

    m <- run$membership
    expect_true(all(c("task_id", "channel", "hit",
                      "processing_state", "evidence_refs") %in% names(m)))
    expect_true(is.na(m$hit[m$task_id == "HX2::t" &
                            m$channel == "dialysis_signal"]))
})

test_that("hit-set expression grammar and channel validation fail closed", {
    expect_setequal(hit_set_expr("(a | b) & !c")$channels, c("a", "b", "c"))
    expect_error(hit_set_expr("foo(a)"), "operators")

    expect_error(
        hx_var(expr = "transplant_act | missing_channel"),
        "non-activated")
    expect_error(
        hx_var(expr = "transplant_act"),
        "not used")
})
