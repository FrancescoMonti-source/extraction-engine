test_that("authoring constructors reject unread arguments", {
    selector <- icd10("^E1")

    expect_error(use_channel(prompt = "ignored"), "unused argument")
    expect_error(use_channel(method = 42), "llm_after_lucene")
    expect_error(llm_after_lucene(), "requires candidates")
    expect_error(
        code_channel("pmsi_diag", selector, prompt = "ignored"),
        "unused argument")
})

test_that("output constructors require unique explicit contracts", {
    # Authoring contract: duplicate/empty levels or fields cannot be interpreted
    # as a meaningful output schema later in execution.
    expect_error(cat_output(c("a", "a")), "unique non-empty levels")
    expect_error(struct_output(character()), "unique non-empty fields")
    expect_error(struct_output(c("field", "field")), "unique non-empty fields")
    expect_error(
        new_task_definition(
            "probe", "system", function(...) NULL, function(...) "prompt",
            function(...) NULL, summary_required = 1),
        "summary_required must be TRUE or FALSE")
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
