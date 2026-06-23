source_result <- function(status, hit = NA, evidence_ids = character(),
                          error = NA_character_) {
    list(
        status = status,
        hit = hit,
        evidence = tibble::tibble(source_row_id = evidence_ids),
        error = error)
}

# Why: an OR variable may be established by one source even when another source
# fails. This protects positive evidence from being discarded by an unrelated
# branch failure while keeping partial ascertainment and the failure auditable.
test_that("any-source hit survives failure in another selected source", {
    result <- combine_any_source_hit(
        list(
            documents = source_result(
                "error", error = "synthetic document extraction failure"),
            pmsi_diag = source_result(
                "complete", hit = TRUE, evidence_ids = "diag:E11")),
        incomplete_value = NA_integer_)

    expect_equal(result$value, 1L)
    expect_equal(result$ascertainment, "partial")
    expect_equal(result$evidence$source, "pmsi_diag")
    expect_equal(result$evidence$source_row_id, "diag:E11")
    expect_equal(
        result$source_status$error[result$source_status$source == "documents"],
        "synthetic document extraction failure")
})

# Why: absence of a hit and incomplete ascertainment are separate facts. This
# protects study authors' ability to choose either a strict missing value or a
# permissive zero without the engine hiding that only part of the sources ran.
test_that("variable policy decides the value under partial ascertainment", {
    branches <- list(
        documents = source_result("complete", hit = FALSE),
        pmsi_diag = source_result("unavailable"))

    strict <- combine_any_source_hit(
        branches, incomplete_value = NA_integer_)
    permissive <- combine_any_source_hit(
        branches, incomplete_value = 0L)

    expect_true(is.na(strict$value))
    expect_equal(permissive$value, 0L)
    expect_equal(strict$ascertainment, "partial")
    expect_equal(permissive$ascertainment, "partial")
    expect_equal(strict$source_status$status, c("complete", "unavailable"))
})

# Why: zero is a valid derived value only when the selected completed branches
# report no hit. This prevents a completed negative from being confused with
# missing evidence, invalid evidence, or a processing failure.
test_that("completed selected sources with no hit produce a valid zero", {
    result <- combine_any_source_hit(
        list(
            documents = source_result("complete", hit = FALSE),
            pmsi_diag = source_result("complete", hit = FALSE)),
        incomplete_value = NA_integer_)

    expect_equal(result$value, 0L)
    expect_equal(result$ascertainment, "complete")
    expect_equal(nrow(result$evidence), 0L)
})

# Why: malformed-only evidence is not a completed negative. This protects an
# invalid selected source from being silently converted into absence while still
# allowing the variable recipe to choose its own incomplete-source policy.
test_that("invalid-only evidence remains partial rather than negative", {
    result <- combine_any_source_hit(
        list(
            documents = source_result("complete", hit = FALSE),
            pmsi_diag = source_result("invalid")),
        incomplete_value = NA_integer_)

    expect_true(is.na(result$value))
    expect_equal(result$ascertainment, "partial")
    expect_equal(
        result$source_status$status[result$source_status$source == "pmsi_diag"],
        "invalid")
})

# Why: combined evidence must retain an unambiguous source and native row key.
# This catches positive branches without evidence and duplicate evidence links
# before they can enter review or cohort artifacts.
test_that("multi-source evidence keeps unique source provenance", {
    result <- combine_any_source_hit(
        list(
            documents = source_result(
                "complete", hit = TRUE, evidence_ids = "doc:D1"),
            pmsi_diag = source_result(
                "complete", hit = TRUE, evidence_ids = "diag:E11")),
        incomplete_value = NA_integer_)

    expect_equal(result$value, 1L)
    expect_equal(result$ascertainment, "complete")
    expect_equal(
        result$evidence[c("source", "source_row_id")],
        tibble::tibble(
            source = c("documents", "pmsi_diag"),
            source_row_id = c("doc:D1", "diag:E11")))

    expect_error(
        combine_any_source_hit(
            list(
                documents = source_result("complete", hit = TRUE),
                pmsi_diag = source_result("complete", hit = FALSE)),
            incomplete_value = NA_integer_),
        "positive hit requires evidence")

    expect_error(
        combine_any_source_hit(
            list(
                documents = source_result(
                    "complete", hit = TRUE,
                    evidence_ids = c("doc:D1", "doc:D1"))),
            incomplete_value = NA_integer_),
        "evidence IDs must be non-missing and unique")
})
