# Contract test for the read-only inspection/resolution surface.
# Why: defaults and replacements must be visible before execution so judgment is
# explicit rather than hidden inside run_variable().

test_that("resolve_variable_spec exposes inherited executable essentials", {
    baseline <- variable_spec(
        template = diabetes_baseline_status_template(),
        name = "diabete_pre_greffe",
        unit = "transplant",
        anchor = "anchor_date")

    resolved <- resolve_variable_spec(baseline)

    expect_equal(resolved$combine_rule,
                 "pmsi_diag_e10_e14 | text_diabetes_mentions")
    expect_setequal(names(resolved$channels),
                    c("pmsi_diag_e10_e14", "text_diabetes_mentions"))
})
