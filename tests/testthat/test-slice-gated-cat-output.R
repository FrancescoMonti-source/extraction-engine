# Disposable probe (NOT a shipped concept): the PAYLOAD rule of the DESIGN §8
# validity matrix (ratified 2026-07-05, this consumer). A combine expression gates
# ROWS, never produces the value; any non-bin output reads the survivors' values
# and must declare its payload: values_from = <channel> + reduce = <plain closure>.
#
# Consumer: dialysis modality. Gate = "dialysis_diag & dialysis_act" (diagnosis
# alone is not enough); the categorical value is read FROM the surviving act rows'
# CCAM codes -- the code SYSTEM already encodes the modality (JVJF* = hemodialysis
# sessions, JVJB* = peritoneal), so no text/LLM is involved. The tie-break (a
# patient with both families) is the RESEARCHER's closure, never an engine rule.
# Codes here are synthetic vehicles, not a validated ascertainment definition.

gc_diag <- tibble::tibble(
    source_row_id = c("d1", "d2", "d3", "d4", "d5"),
    PATID   = c("P1", "P2", "P3", "P4", "P5"),
    EVTID   = c("S1", "S2", "S3", "S4", "S5"),
    ELTID   = c("L1", "L2", "L3", "L4", "L5"),
    diag    = c("N186", "Z992", "N186", "E119", "Z992"),
    #             gate     gate    gate  NOT dialysis  gate
    DATENT  = as.Date("2024-03-01") + 0:4,
    DATSORT = as.Date("2024-03-05") + 0:4)

gc_acts <- tibble::tibble(
    source_row_id = c("a1", "a2", "a3", "a4", "a5", "a6"),
    PATID    = c("P1", "P1", "P2", "P4", "P5", "P5"),
    EVTID    = c("S1", "S1", "S2", "S4", "S5", "S5"),
    ELTID    = c("K1", "K2", "K3", "K4", "K5", "K6"),
    CODEACTE = c("JVJF004", "JVJF004", "JVJB001", "JVJF004", "JVJF004", "JVJB002"),
    #             P1: hemo x2          P2: perit  P4: act only  P5: BOTH (tie)
    DATEACTE = as.Date("2024-03-02") + 0:5)
# P3: dialysis diag but NO act rows at all -> act channel silent.

gc_tasks <- tibble::tibble(grain_id = paste0("P", 1:5, "::t"),
                           PATID = paste0("P", 1:5))
gc_sources <- list(pmsi_diag = gc_diag, pmsi_actes = gc_acts)

gc_concept <- concept_spec(
    name = "dialysis_modality",
    channels = list(
        dialysis_diag = code_channel(
            source = "pmsi_diag",
            selector = icd10(c("Z992", "N186"), match = "exact"),
            native_grain = "diagnosis_row",
            required_roles = c("subject_id", "event_id", "event_start",
                               "event_end", "code", "source_item_id"),
            linkage = "subject"),
        dialysis_act = act_channel(
            source = "pmsi_actes",
            selector = ccam(c("JVJF004", "JVJF008", "JVJB001", "JVJB002"),
                            match = "exact"),
            native_grain = "act_row",
            required_roles = c("subject_id", "event_id", "point_date",
                               "code", "source_item_id"),
            linkage = "subject")))

# The researcher's modality rule: an explicit priority closure.
gc_rule <- function(codes) {
    if (any(startsWith(codes, "JVJB"))) "peritoneal" else "hemodialysis"
}

test_that("a combine expression gates rows and cat_output reads the survivors' codes", {
    spec <- variable_spec(
        name = "dialysis_modality",
        concept = gc_concept,
        output_one_row_per = "PATID",
        channels = list(dialysis_diag = use_channel(),
                        dialysis_act = use_channel()),
        combine_channels = "dialysis_diag & dialysis_act",
        output = cat_output(levels = c("hemodialysis", "peritoneal"),
                            values_from = "dialysis_act",
                            reduce = gc_rule))

    run <- run_variable(spec, gc_tasks, gc_sources)
    value <- setNames(run$values$value, run$values$grain_id)
    coverage <- setNames(run$values$channel_coverage, run$values$grain_id)

    expect_equal(value[["P1::t"]], "hemodialysis")
    expect_equal(value[["P2::t"]], "peritoneal")
    expect_equal(value[["P5::t"]], "peritoneal")   # both families -> researcher's rule
    # Gate-fail -> NA (cat reserves no "excluded" level), with silence and
    # ascertained exclusion still distinguished by coverage:
    expect_true(is.na(value[["P3::t"]]))           # diag only; act channel SILENT
    expect_equal(coverage[["P3::t"]], "partial")
    expect_true(is.na(value[["P4::t"]]))           # act only; diag ascertained negative
    expect_equal(coverage[["P4::t"]], "complete")
    # The hit-algebra audit is untouched by the payload read.
    expect_true(all(c("membership", "overlap") %in% names(run)))
})

test_that("num_output(values_from =, reduce =) rides the same gate", {
    spec <- variable_spec(
        name = "n_dialysis_acts_confirmed",
        concept = gc_concept,
        output_one_row_per = "PATID",
        channels = list(dialysis_diag = use_channel(),
                        dialysis_act = use_channel()),
        combine_channels = "dialysis_diag & dialysis_act",
        output = num_output(values_from = "dialysis_act", reduce = length))

    run <- run_variable(spec, gc_tasks, gc_sources)
    value <- setNames(run$values$value, run$values$grain_id)
    n_rows <- setNames(run$values$n_payload_rows, run$values$grain_id)

    expect_equal(value[["P1::t"]], 2)              # two surviving act rows
    expect_equal(value[["P2::t"]], 1)
    expect_true(is.na(value[["P3::t"]]))           # gate fail -> NA, not 0
    expect_equal(n_rows[["P1::t"]], 2L)            # post-combine payload count
    expect_equal(n_rows[["P3::t"]], 0L)
})

# An empty payload behind a PASSING gate (task admitted via the other side of an
# `|`) is NA without calling reduce -- reduce = length would have said 0, which
# would silently conflate "no surviving payload" with a measured zero.
test_that("an empty payload behind a passing gate yields NA without calling reduce", {
    spec <- variable_spec(
        name = "n_dialysis_acts_any",
        concept = gc_concept,
        output_one_row_per = "PATID",
        channels = list(dialysis_diag = use_channel(),
                        dialysis_act = use_channel()),
        combine_channels = "dialysis_diag | dialysis_act",
        output = num_output(values_from = "dialysis_act", reduce = length))

    run <- run_variable(spec, gc_tasks, gc_sources)
    value <- setNames(run$values$value, run$values$grain_id)
    n_rows <- setNames(run$values$n_payload_rows, run$values$grain_id)

    expect_true(is.na(value[["P3::t"]]))           # in via diag; act payload empty
    expect_equal(n_rows[["P3::t"]], 0L)
    expect_equal(value[["P1::t"]], 2)
})

test_that("single-channel cat payload reads the channel's own rows (no combine)", {
    spec <- variable_spec(
        name = "dialysis_modality_by_act",
        concept = gc_concept,
        output_one_row_per = "PATID",
        channels = list(dialysis_act = use_channel()),
        output = cat_output(levels = c("hemodialysis", "peritoneal"),
                            reduce = gc_rule))   # values_from defaults to the channel

    run <- run_variable(spec, gc_tasks, gc_sources)
    value <- setNames(run$values$value, run$values$grain_id)

    expect_equal(value[["P4::t"]], "hemodialysis") # no gate: the act alone answers
    expect_true(is.na(value[["P3::t"]]))           # no rows -> NA/partial
})

test_that("the payload rule is enforced at build time", {
    # A gate yields rows, not a value: non-bin output without a payload spec.
    expect_error(
        variable_spec(
            name = "no_payload", concept = gc_concept,
            output_one_row_per = "PATID",
            channels = list(dialysis_diag = use_channel(),
                            dialysis_act = use_channel()),
            combine_channels = "dialysis_diag & dialysis_act",
            output = cat_output(levels = c("hemodialysis", "peritoneal"))),
        "combine gates rows")
    # values_from must name an activated channel.
    expect_error(
        variable_spec(
            name = "bad_payload_channel", concept = gc_concept,
            output_one_row_per = "PATID",
            channels = list(dialysis_diag = use_channel(),
                            dialysis_act = use_channel()),
            combine_channels = "dialysis_diag & dialysis_act",
            output = num_output(values_from = "nope", reduce = length)),
        "values_from must name an activated channel")
    # With several channels the payload pick is not derivable.
    expect_error(
        variable_spec(
            name = "underdetermined_payload", concept = gc_concept,
            output_one_row_per = "PATID",
            channels = list(dialysis_diag = use_channel(),
                            dialysis_act = use_channel()),
            combine_channels = "dialysis_diag & dialysis_act",
            output = num_output(reduce = length)),
        "must declare values_from")
    # Reduction lives on the output, never on the activation (wrapper razor).
    expect_error(use_channel(reducer = length), "no longer takes reducer")
})

# A deterministic closure violating its own declared contract is a BUG -> hard
# error, not a review state (unlike an ungrounded LLM answer).
test_that("a reduce returning something outside levels is a hard error", {
    spec <- variable_spec(
        name = "broken_rule", concept = gc_concept,
        output_one_row_per = "PATID",
        channels = list(dialysis_act = use_channel()),
        output = cat_output(levels = c("hemodialysis", "peritoneal"),
                            reduce = function(codes) "dialysis"))
    expect_error(run_variable(spec, gc_tasks, gc_sources),
                 "not one of levels")
})
