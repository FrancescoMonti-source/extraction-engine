# Contract test for the read-only inspection/resolution surface.
# Why: defaults and replacements must be visible before execution so judgment is
# explicit rather than hidden inside run_variable().

test_that("resolve_variable_spec exposes the inherited executable view", {
    concept <- diabetes_concept_spec()
    baseline <- variable_spec(
        template = diabetes_baseline_status_template(concept),
        name = "diabete_pre_greffe",
        unit = "transplant",
        anchor = "anchor_date")

    resolved <- resolve_variable_spec(baseline)

    expect_s3_class(resolved, "ee_resolved_variable_spec")
    expect_equal(attr(resolved, "api_status"), "experimental")
    expect_equal(resolved$name, "diabete_pre_greffe")
    expect_equal(resolved$concept, "diabetes")
    expect_equal(resolved$template, "diabetes_baseline_status_template")
    expect_equal(resolved$combine_rule,
                 "pmsi_diag_e10_e14 | text_diabetes_mentions")
    expect_equal(resolved$output$kind, "binary")
    expect_setequal(names(resolved$channels),
                    c("pmsi_diag_e10_e14", "text_diabetes_mentions"))

    code <- resolved$channels$pmsi_diag_e10_e14
    expect_equal(code$type, "code")
    expect_equal(code$source, "pmsi_diag")
    expect_equal(code$selector$kind, "icd10_prefix")
    expect_equal(code$selector$prefixes,
                 c("E10", "E11", "E12", "E13", "E14"))
    expect_null(code$method)
    expect_equal(code$method_source, "none")

    text <- resolved$channels$text_diabetes_mentions
    expect_equal(text$type, "text")
    expect_equal(text$source, "documents")
    expect_equal(text$selector$kind, "lucene_query")
    expect_s3_class(text$method, "ee_extraction_method")
    expect_equal(text$method$kind, "llm_after_lucene")
    expect_equal(text$method$top_n, 20L)
    expect_equal(text$method_source, "activation")
    expect_equal(text$extractor$name, "diabetes_text")
    expect_equal(text$extractor_source, "channel")

    inspected <- inspect(baseline)
    expect_equal(inspected$combine_rule, resolved$combine_rule)

    channel_view <- inspect(concept$channels$text_diabetes_mentions)
    expect_s3_class(channel_view, "ee_channel_inspection")
    expect_equal(channel_view$source, "documents")
})
