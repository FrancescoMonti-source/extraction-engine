# Contract test for the source-spec role vocabulary slice.
# Why: source_spec() is the HDW boundary -- raw HDW columns must resolve to the
# canonical target role names (the PATID/EVTID/ELTID spine, lab value/result coords).

test_that("source role maps use target names", {
    expect_equal(
        unlist(source_roles(DIAG_SOURCE)[
            c("subject_id", "event_id", "source_item_id", "event_start",
              "event_end", "code")], use.names = TRUE),
        c(subject_id = "PATID", event_id = "EVTID", source_item_id = "ELTID",
          event_start = "DATENT", event_end = "DATSORT", code = "diag"))
    expect_equal(
        unlist(source_roles(BIOL_SOURCE)[
            c("source_item_id", "source_result_id", "value_num", "value_str")],
            use.names = TRUE),
        c(source_item_id = "ELTID", source_result_id = "BIOL_ID",
          value_num = "value", value_str = "value_raw"))
    expect_equal(source_roles(DOCS_SOURCE)$document_type, "RECTYPE")
    expect_equal(DOCS_SOURCE$normalizer, "process_doceds")
    expect_equal(DIAG_SOURCE$source_time_kind, "interval")
})
