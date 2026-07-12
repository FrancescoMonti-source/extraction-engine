test_that("prepared views retain redsan types without engine coercion", {
    # Source/process contract: redsan owns warehouse parsing. The engine view is
    # only a plain rename plus an explicit row coordinate for repeated records.
    pmsi_tables <- redsan::process_pmsi(list(list(
        PATID = "P1", EVTID = "E1", ELTID = "L1",
        DATENT = "2025-06-22 00:30", DATSORT = "2025-06-23",
        PATAGE = "50", DALL = "01:E11.9 02:I10",
        CODEACTE1 = "ABCD001", DATEACTE1 = "2025-06-22 09:15")))
    pmsi <- pmsi_tables$diag
    diag <- dplyr::transmute(
        pmsi,
        source_row_id = paste0("diag:", seq_len(dplyr::n())),
        PATID, EVTID, ELTID, diag, DATENT, DATSORT, PATAGE)
    actes <- dplyr::mutate(
        pmsi_tables$actes,
        source_row_id = paste0("acte:", seq_len(dplyr::n())))

    biology <- redsan::process_biol(list(examA = list(
        PATID = "P1", EVTID = "E1", ELTID = "B1",
        DATEXAM = "2025-06-22 00:30", PATAGE = "50", PATSEX = "M",
        RESULTATS = data.frame(
            TYPEANA = c("K.K", "K.K"), NUMRES = I(list(5.4, 3))))))
    biol <- dplyr::transmute(
        biology,
        source_row_id = paste0("biol:", seq_len(dplyr::n())),
        PATID, EVTID, ELTID, BIOL_ID, DATEXAM,
        analyte = TYPEANA, value = NUMRES, value_raw = as.character(NUMRES),
        PATSEX, PATAGE)

    expect_true(inherits(diag$DATENT, "POSIXct"))
    expect_true(inherits(actes$DATEACTE, "POSIXct"))
    expect_type(diag$PATAGE, "double")
    expect_true(inherits(biol$DATEXAM, "POSIXct"))
    expect_equal(biol$value, c(5.4, 3))
    expect_equal(biol$value_raw, c("5.4", "3"))
    expect_type(biol$PATAGE, "double")
    expect_silent(validate_source_view(diag, DIAG_SOURCE))
    expect_silent(validate_source_view(actes, ACTE_SOURCE))
    expect_silent(validate_source_view(biol, BIOL_SOURCE))
})

test_that("prepared-view validation fails closed on untyped numeric payloads", {
    view <- tibble::tibble(
        source_row_id = "biol:1", PATID = "P1", EVTID = "E1", ELTID = "B1",
        BIOL_ID = "examA", DATEXAM = as.Date("2025-06-22"),
        analyte = "K.K", value = "5.4", value_raw = "5.4")

    expect_error(validate_source_view(view, BIOL_SOURCE),
                 "value_num must bind a numeric column")
})
