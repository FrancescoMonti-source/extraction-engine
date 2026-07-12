review_diag_rows <- tibble::tibble(
    source_row_id = "diag:1",
    PATID = "subject",
    EVTID = "target-event",
    ELTID = "stay:1",
    diag = "A41",
    DATENT = as.POSIXct("2025-01-02", tz = "Europe/Paris"),
    DATSORT = as.POSIXct("2025-01-03", tz = "Europe/Paris"))

review_code_concept <- function(linkage = "subject",
                                required_roles = c(
                                    "subject_id", "event_id", "event_start",
                                    "event_end", "code", "source_item_id")) {
    concept_spec("review scope", list(
        code = code_channel(
            "pmsi_diag", icd10("A41", match = "exact"),
            required_roles = required_roles,
            linkage = linkage)))
}

test_that("a named task anchor is the only clock used by a relative window", {
    # Engine invariant: the authored anchor name must drive execution. A decoy
    # anchor_date outside the window catches any hidden hard-coded fallback.
    variable <- variable_spec(
        "custom anchor", review_code_concept(),
        anchor = "index_date", window = c(-1, 1),
        channels = list(code = use_channel()), output = bin_output())
    cohort <- tibble::tibble(
        grain_id = "task", PATID = "subject",
        index_date = as.Date("2025-01-02"),
        anchor_date = as.Date("2025-02-01"))

    run <- run_variable(variable, cohort, list(pmsi_diag = review_diag_rows))

    expect_equal(run$values$value, 1L)
    expect_equal(run$provenance$anchor,
                 list(kind = "task_column", column = "index_date"))
})

test_that("a relative window without a declared anchor fails closed", {
    # Authoring contract: an undeclared cohort column must never become an
    # implicit clock merely because it happens to be named anchor_date.
    expect_error(
        variable_spec(
            "missing anchor", review_code_concept(),
            anchor = NULL, window = c(-1, 1),
            channels = list(code = use_channel()), output = bin_output()),
        "relative window requires an explicit anchor")
})

test_that("required source roles are validated by the compiler", {
    # Source contract: declarative metadata is executable only if every named
    # role is actually bound by the selected prepared source.
    variable <- variable_spec(
        "missing role",
        review_code_concept(required_roles = "role_that_does_not_exist"),
        channels = list(code = use_channel()), output = bin_output())

    expect_error(resolve_variable_spec(variable),
                 "requires source role.*role_that_does_not_exist")
})

test_that("event linkage prevents structured cross-event hits", {
    # Relational-scope invariant: same-subject evidence from a different EVTID
    # cannot qualify an event-linked channel.
    variable <- variable_spec(
        "event scope", review_code_concept(linkage = "event"),
        output_one_row_per = "PATID", anchor = NULL, window = NULL,
        channels = list(code = use_channel()), output = bin_output())
    cohort <- tibble::tibble(
        grain_id = "task", PATID = "subject", EVTID = "target-event")
    other_event <- dplyr::mutate(review_diag_rows, EVTID = "other-event")

    run <- run_variable(variable, cohort, list(pmsi_diag = other_event))

    expect_equal(run$values$value, 0L)
    expect_equal(run$provenance$channels$code$linkage, "event")
    expect_equal(
        run$provenance$channels$code$required_roles,
        c("subject_id", "event_id", "event_start", "event_end", "code",
          "source_item_id"))
})
