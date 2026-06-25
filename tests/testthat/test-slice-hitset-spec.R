# Contract tests for hit_set_difference(): it is NOT a parallel boolean system, only
# thin backward-compatible sugar that LOWERS to a string hit-set expression.
# hit_set_difference(include = a, exclude = b) == combine = "a & !b". The string
# expression DSL (test-slice-hitset-expr-spec.R) is the primary, documented surface;
# these tests pin the lowering and prove end-to-end equivalence. Two code channels
# over synthetic data; no model.

# Synthetic code vehicles (real-shaped so they pass the ICD-10 usability check):
# include = transplant-status Z94 in `acts`; exclude = dialysis-dependence Z99 in a
# SEPARATE `exclusion_dx` source.
hs_concept <- function() {
    concept_spec(
        name = "act_minus_signal",
        channels = list(
            act_present = code_channel(
                source = "acts", selector = icd10("Z94"),
                native_grain = "diagnosis_row",
                required_roles = c("subject", "event", "interval_start",
                                   "interval_end", "code", "native_ref"),
                linkage = "subject"),
            signal_present = code_channel(
                source = "exclusion_dx", selector = icd10("Z99"),
                native_grain = "diagnosis_row",
                required_roles = c("subject", "event", "interval_start",
                                   "interval_end", "code", "native_ref"),
                linkage = "subject")))
}

hs_var <- function(combine = hit_set_difference(include = "act_present",
                                                exclude = "signal_present"),
                   channels = list(act_present = use_channel(),
                                   signal_present = use_channel())) {
    variable_spec(
        name = "act_without_signal_hit", concept = hs_concept(),
        unit = "transplant", anchor = "anchor_date",
        window = before_anchor(days = 1825L, grace_days = 7L),
        channels = channels, output = binary_output(),
        combine = combine, absence_policy = open_world())
}

hs_tasks <- tibble::tibble(
    task_id = paste0("HS", 1:5, "::t"),
    PATID = paste0("P", 1:5),
    anchor_date = as.Date("2024-06-01"))

hs_row <- function(srid, patid, code) tibble::tibble(
    source_row_id = srid, PATID = patid, EVTID = paste0("E", patid),
    ELTID = paste0("L", srid), diag = code,
    DATENT = as.Date("2024-05-20"), DATSORT = as.Date("2024-05-21"))

# include source: P1/P2/P3 Z94 hit; P4 non-matching (ascertained negative); P5 none.
hs_acts <- dplyr::bind_rows(
    hs_row("acts:001", "P1", "Z940"),
    hs_row("acts:002", "P2", "Z940"),
    hs_row("acts:003", "P3", "Z940"),
    hs_row("acts:004", "P4", "I10"))

# exclude source: P1 non-matching (negative); P3/P5 Z99 hit; P2/P4 none (unavailable).
hs_exdx <- dplyr::bind_rows(
    hs_row("exdx:001", "P1", "I10"),
    hs_row("exdx:003", "P3", "Z992"),
    hs_row("exdx:005", "P5", "Z992"))

hs_sources <- list(acts = hs_acts, exclusion_dx = hs_exdx)

# Why: the operator is sugar -- it must build the equivalent string expression.
test_that("hit_set_difference lowers to a string hit-set expression", {
    one <- hit_set_difference(include = "act_present", exclude = "signal_present")
    expect_equal(one$kind, "hit_set_expr")          # NOT a parallel kind
    expect_equal(one$expr, "act_present & !signal_present")
    expect_setequal(one$channels, c("act_present", "signal_present"))

    # OR-within-role for multiple include / exclude channels
    expect_equal(hit_set_difference(c("a", "b"), c("c", "d"))$expr,
                 "(a | b) & !(c | d)")
    # include-only collapses to a bare inclusion
    expect_equal(hit_set_difference("a")$expr, "a")
})

# Why: lowering must be behaviourally identical to writing the string directly --
# same values, same membership, same overlap audit.
test_that("hit_set_difference(a, b) is exactly combine = 'a & !b' end-to-end", {
    run_sugar <- run_variable(
        hs_var(combine = hit_set_difference("act_present", "signal_present")),
        hs_tasks, hs_sources)
    run_str <- run_variable(
        hs_var(combine = "act_present & !signal_present"),
        hs_tasks, hs_sources)

    expect_equal(run_sugar$values, run_str$values)
    expect_equal(run_sugar$source_status, run_str$source_status)
    expect_equal(run_sugar$membership, run_str$membership)
    expect_equal(run_sugar$overlap, run_str$overlap)
    expect_equal(run_sugar$evidence, run_str$evidence)
    expect_equal(run_sugar$combine_rule, "hit_set_expr")
})

# Why: document the lowered OBSERVED semantics of "act & !signal" on real-ish data --
# in particular that an unavailable exclusion keeps an act-hit task INCLUDED (B
# produced no observed hit), with the uncertainty reported as channel_coverage, never
# a silent definitive negative or an undetermined decision.
test_that("the lowered expression evaluates as observed set algebra", {
    run <- run_variable(hs_var(), hs_tasks, hs_sources)
    dec <- setNames(run$values$decision, run$values$task_id)
    cov <- setNames(run$values$channel_coverage, run$values$task_id)

    expect_equal(dec[["HS1::t"]], "included")        # act hit, signal negative
    expect_equal(cov[["HS1::t"]], "complete")
    expect_equal(dec[["HS2::t"]], "included")        # act hit, signal UNAVAILABLE -> kept
    expect_equal(cov[["HS2::t"]], "partial")         # ...with coverage flagging it
    expect_equal(dec[["HS3::t"]], "excluded")        # act hit, signal hit
    expect_equal(dec[["HS4::t"]], "excluded")        # act negative
    expect_equal(dec[["HS5::t"]], "excluded")        # signal hit removes regardless
})

test_that("hit_set_difference() guards its roles", {
    expect_error(hit_set_difference(include = character()), "include")
    expect_error(hit_set_difference(include = "a", exclude = "a"), "both")
})
