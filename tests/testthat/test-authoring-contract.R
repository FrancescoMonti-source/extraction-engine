test_that("authoring constructors reject unread arguments", {
    selector <- icd10("^E1")

    expect_error(use_channel(prompt = "ignored"), "unused argument")
    expect_error(use_channel(method = 42), "llm_after_lucene")
    expect_error(
        code_channel("pmsi_diag", selector, prompt = "ignored"),
        "unused argument")
})

test_that("one compiled spec drives inspection and retains combine level", {
    concept <- concept_spec("two signals", list(
        first = code_channel("pmsi_diag", icd10("^E10")),
        second = code_channel("pmsi_diag", icd10("^E11"))))
    build_variable <- function(level) {
        variable_spec(
            name = "combined", concept = concept,
            output_one_row_per = "PATID",
            channels = list(first = use_channel(), second = use_channel()),
            combine_channels = "first | second",
            combine_at_level = level,
            output = bin_output())
    }

    authored <- build_variable("EVTID")
    compiled <- resolve_variable_spec(authored)

    expect_equal(compiled$combine_at_level, "EVTID")
    expect_identical(inspect(authored), compiled)
    expect_false("activation" %in% names(compiled$channels$first))
    expect_false(exists("variable_template", mode = "function", inherits = TRUE))
})
