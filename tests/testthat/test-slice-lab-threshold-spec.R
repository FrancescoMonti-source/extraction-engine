# Disposable probe (NOT a shipped concept): can a THRESHOLDED lab channel produce a
# membership hit that joins the boolean combine algebra? DESIGN §8/§14.6: a threshold is
# represented by replacing the selector with a thresholded one -- analyte_value(gt) --
# whose meaning is "has at least one in-scope measurement of this analyte above the
# cutoff". That is the lab channel's MEMBERSHIP face (bin_output + combine), distinct
# from its value face (num_output + a reducer, already shipped).
#
# Invariant locked (DESIGN §1185 explicitly wants one THRESHOLDED lab channel in the
# validity matrix): the thresholded hit is three-valued like every other channel --
# above cutoff = TRUE (1), an in-range measurement below cutoff = observed FALSE (0,
# coverage complete), no measurement at all = unevaluable (0, coverage partial). That
# FALSE-vs-NA split is what lets the lab hit mean the same thing as a code hit inside a
# combine expression.

lab_tasks <- tibble::tibble(
    task_id = paste0("Q", 1:3, "::t"),
    PATID = paste0("Q", 1:3),
    anchor_date = as.Date("2024-06-01"))

lab_row <- function(srid, patid, analyte, value) tibble::tibble(
    source_row_id = srid, PATID = patid, EVTID = paste0("E", patid),
    ELTID = paste0("L", srid), BIOL_ID = paste0("B", srid),
    DATEXAM = as.Date("2024-06-01"), analyte = analyte,
    value_raw = as.character(value), value = value)

lab_biol <- dplyr::bind_rows(
    lab_row("g1", "Q1", "GLU.GLU", 15),   # above 11 -> hit
    lab_row("g2", "Q2", "GLU.GLU", 8))    # glucose measured, below 11 -> observed FALSE
    # Q3: no biology row at all -> the source is unevaluable for the subject (NA)

lab_concept <- function() concept_spec(
    name = "glycaemia",
    channels = list(
        glucose = lab_channel(
            source = "biology",
            selector = analyte("GLU.GLU"),
            required_roles = c("subject_id", "event_id", "date", "value_num",
                               "value_str", "analyte", "source_item_id",
                               "source_result_id"),
            linkage = "subject")))

test_that("a thresholded analyte selector hits above the cutoff, observed-negative below, unevaluable when absent", {
    var <- variable_spec(
        name = "hyperglycaemia", concept = lab_concept(),
        output_one_row_per = "PATID", anchor = "anchor_date",
        window = days_after(-7L, 7L),
        channels = list(glucose = use_channel(selector = analyte_value("GLU.GLU", gt = 11))),
        output = bin_output())

    run <- run_variable(var, lab_tasks, list(biology = lab_biol))
    value <- setNames(run$values$value, run$values$task_id)
    cov <- setNames(run$values$channel_coverage, run$values$task_id)

    expect_equal(value[["Q1::t"]], 1L)   # 15 > 11
    expect_equal(value[["Q2::t"]], 0L)   # 8 not > 11: glucose measured, below cutoff
    expect_equal(value[["Q3::t"]], 0L)   # no biology at all

    # The FALSE (evaluated, no hit) vs NA (unevaluable) split rides on coverage.
    expect_equal(cov[["Q2::t"]], "complete")
    expect_equal(cov[["Q3::t"]], "partial")

    # Evidence is the thresholded row only -- a below-cutoff measurement is not a hit
    # and contributes no evidence.
    ev1 <- run$evidence[run$evidence$task_id == "Q1::t", ]
    expect_equal(ev1$evidence_ref, "g1")
    expect_equal(nrow(run$evidence[run$evidence$task_id == "Q2::t", ]), 0L)
})

test_that("a thresholded lab hit joins a boolean combine with a code channel", {
    concept <- concept_spec(
        name = "diabetic_hyperglycaemia",
        channels = list(
            glucose = lab_channel(
                source = "biology", selector = analyte("GLU.GLU"),
                required_roles = c("subject_id", "event_id", "date", "value_num",
                                   "value_str", "analyte", "source_item_id",
                                   "source_result_id"),
                linkage = "subject"),
            diabetes_dx = code_channel(
                source = "pmsi_diag", selector = icd10("E11"),
                required_roles = c("subject_id", "event_id", "event_start",
                                   "event_end", "code", "source_item_id"),
                linkage = "subject")))
    var <- variable_spec(
        name = "diabetic_with_hyperglycaemia", concept = concept,
        output_one_row_per = "PATID", anchor = "anchor_date",
        window = days_after(-7L, 7L),
        channels = list(
            glucose = use_channel(selector = analyte_value("GLU.GLU", gt = 11)),
            diabetes_dx = use_channel()),
        combine = "glucose & diabetes_dx",
        output = bin_output())

    diag <- tibble::tibble(
        source_row_id = c("d1", "d2"), PATID = c("Q1", "Q2"),
        EVTID = c("E1", "E2"), ELTID = c("L1", "L2"),
        diag = c("E11.9", "E11.9"),
        DATENT = as.Date("2024-05-28"), DATSORT = as.Date("2024-05-29"))

    run <- run_variable(var, lab_tasks, list(biology = lab_biol, pmsi_diag = diag))
    value <- setNames(run$values$value, run$values$task_id)

    expect_equal(value[["Q1::t"]], 1L)   # E11 code AND glucose 15 > 11
    expect_equal(value[["Q2::t"]], 0L)   # E11 code but glucose 8: the AND gates on the lab
})
