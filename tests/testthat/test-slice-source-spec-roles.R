# Contract tests for the source-spec role vocabulary slice.
# Why: source_spec() is the HDW boundary. It must expose the target role names and
# redsan-shaped source mechanics without changing the normalized rows consumed by
# current executors.

test_that("default source specs expose redsan-shaped metadata without source grain", {
    specs <- list(documents = DOCS_SOURCE, pmsi_diag = DIAG_SOURCE,
                  biology = BIOL_SOURCE)

    expect_true(all(vapply(specs, inherits, logical(1), "ee_source_spec")))
    expect_false(any(vapply(specs, function(x) "grain" %in% names(x), logical(1))))

    registry_shape <- vapply(specs, function(x) {
        paste(x$module, x$table, x$source_time_kind, x$source_time_start,
              x$source_time_end %||% "", paste(x$query_date_keys, collapse = "/"),
              x$default_batch_key, x$normalizer %||% "", sep = "|")
    }, character(1))
    expect_equal(
        registry_shape,
        c(documents = "doceds|documents|point|RECDATE||RECDATE|RECDATE|",
          pmsi_diag = "pmsi|diag|interval|DATENT|DATSORT|DATENT/DATSORT|DATENT|process_pmsi",
          biology = "biol|results|point|DATEXAM||DATEXAM|DATEXAM|process_biol"))
})

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
})

test_that("concept channel required_roles use the target source vocabulary", {
    concept <- diabetes_concept_spec()
    all_roles <- unlist(lapply(concept$channels, `[[`, "required_roles"),
                        use.names = FALSE)

    expect_true(all(c("subject_id", "event_id", "source_item_id") %in% all_roles))
    expect_true(all(c("value_num", "source_result_id") %in%
                    concept$channels$glucose_measurements$required_roles))
    expect_false(any(c("subject", "event", "native_ref",
                       "interval_start", "interval_end") %in% all_roles))
})
