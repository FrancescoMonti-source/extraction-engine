# Contract/migration tests for target output constructor names.
# These protect vocabulary alignment only; they are not clinical behavior tests.

# Why: DESIGN.md now names the target constructors bin_output(), num_output(),
# cat_output(), and struct_output(). They must be executable while the older
# names remain compatibility aliases for existing specs.
test_that("target output constructors preserve the current output contract", {
    expect_s3_class(bin_output(), "ee_output_type")
    expect_equal(bin_output()$kind, "binary")
    expect_equal(binary_output(), bin_output())

    expect_equal(num_output()$kind, "number")
    expect_equal(number_output(), num_output())

    expect_equal(cat_output(c("yes", "no"))$kind, "categorical")
    expect_equal(cat_output(c("yes", "no"))$levels, c("yes", "no"))
    expect_equal(categorical_output(c("yes", "no")), cat_output(c("yes", "no")))

    expect_equal(struct_output(c("duration", "site"))$kind, "fields")
    expect_equal(struct_output(c("duration", "site"))$fields,
                 c("duration", "site"))
    expect_equal(fields_output(c("duration", "site")),
                 struct_output(c("duration", "site")))
})

# Why: this is a migration slice, not just alias plumbing. A variable_spec should
# accept the target constructor names through the same validation path as the old
# names, proving old behavior is preserved under target vocabulary.
test_that("variable_spec accepts target output constructors", {
    concept <- diabetes_concept_spec()
    direct <- variable_spec(
        name = "perioperative_max_glucose",
        concept = concept,
        unit = "surgery",
        anchor = "anchor_date",
        window = days_after(0L, 2L),
        channels = list(
            glucose_measurements = use_channel(reducer = max_value())),
        output = num_output())

    expect_s3_class(direct, "ee_variable_spec")
    expect_equal(direct$output$kind, "number")
    expect_null(direct$combine)
})

# Why: the old absence_policy= knob was inert after coverage/audit carried
# evaluability. Removed public arguments should fail loudly rather than being
# swallowed through `...`.
test_that("variable_spec rejects the removed absence_policy argument", {
    concept <- diabetes_concept_spec()
    expect_error(
        variable_spec(
            name = "perioperative_max_glucose",
            concept = concept,
            unit = "surgery",
            anchor = "anchor_date",
            window = days_after(0L, 2L),
            channels = list(
                glucose_measurements = use_channel(reducer = max_value())),
            output = num_output(),
            absence_policy = list(kind = "removed")),
        "Unused variable_spec\\(\\) argument\\(s\\): absence_policy")

    expect_error(
        variable_spec(
            template = diabetes_baseline_status_template(concept),
            name = "diabete_pre_greffe",
            unit = "transplant",
            anchor = "anchor_date",
            absence_policy = list(kind = "removed")),
        "absence_policy is no longer")
})
