# Why: run_variable() promises to accept a redsan-shaped biology table. Users
# should not have to manufacture the engine's canonical aliases or row ids.

test_that("redsan-shaped biology is adapted internally at execution", {
    raw_biology <- tibble::tibble(
        PATID = c("P1", "P1", "P2"),
        EVTID = c("E1", "E2", "E3"),
        ELTID = c("L1", "L2", "L3"),
        biol_ID = c("B1", "B2", "B3"),
        DATEXAM = c("2024-06-01", "2024-06-02", "2024-06-03"),
        PATAGE = c("50", "50", "60"),
        PATSEX = c("F", "F", "M"),
        TYPEANA = c("HGB.GDL", "HGB.MML", "HGB.GDL"),
        NUMRES = c(11, 8, 12.5),
        STRRES = NA_character_)
    cohort <- tibble::tibble(
        PATID = c("P1", "P1", "P2", "P3"),
        EVTID = c("E1", "E2", "E3", "E4"))

    haemoglobin <- concept_spec("haemoglobin", list(
        hb_gdl = lab_channel("biology", analyte("HGB.GDL")),
        hb_mml = lab_channel("biology", analyte("HGB.MML"))))
    anaemia <- variable_spec(
        "anaemia_demo", haemoglobin,
        output_one_row_per = "EVTID",
        channels = list(
            hb_gdl = use_channel(keep_when = function(value, PATSEX) {
                value < ifelse(PATSEX == "F", 12, 13)
            }),
            hb_mml = use_channel(keep_when = function(value, PATSEX) {
                value < ifelse(PATSEX == "F", 12, 13) * 0.6206
            })),
        combine_channels = any_positive(),
        output = bin_output())

    run <- run_variable(
        anaemia, cohort = cohort, sources = list(biology = raw_biology))
    value <- stats::setNames(run$values$value, run$values$grain_id)
    coverage <- stats::setNames(
        run$values$channel_coverage, run$values$grain_id)

    expect_equal(value[["P1::E1"]], 1L)
    expect_equal(value[["P1::E2"]], 0L)
    expect_equal(value[["P2::E3"]], 1L)
    expect_equal(value[["P3::E4"]], 0L)
    expect_equal(coverage[["P3::E4"]], "partial")
    expect_true(all(grepl("^biology:[0-9]+$", run$evidence$source_row_id)))
})

test_that("source preparation touches only cohort subjects and keeps source coordinates", {
    biology <- tibble::tibble(
        PATID = c("OUT", "P1", "OUT", "P1"),
        EVTID = c("X1", "E1", "X2", "E2"),
        ELTID = c("LX1", "L1", "LX2", "L2"),
        biol_ID = c("BX1", "B1", "BX2", "B2"),
        DATEXAM = "2024-06-01",
        PATAGE = "50",
        PATSEX = "F",
        TYPEANA = "HGB.GDL",
        NUMRES = 11,
        STRRES = NA_character_)

    prepared <- .prepare_execution_sources(
        list(biology = biology), tibble::tibble(PATID = "P1"))$biology

    expect_equal(nrow(prepared), 2L)
    expect_equal(prepared$PATID, c("P1", "P1"))
    expect_equal(prepared$source_row_id,
                 c("biology:00000002", "biology:00000004"))
})
