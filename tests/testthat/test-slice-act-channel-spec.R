# Contract test: act_channel -- CCAM procedure codes over pmsi$actes. Proves the
# code executor is SOURCE-agnostic: it resolves the code column (CODEACTE) and the
# point-dated time (DATEACTE) from the source's roles (the EE_SOURCES registry),
# matches CCAM codes exactly, and scopes a point date to the anchor window. The
# CCAM codes here (JAFA001 / HGPC015) would fail the deleted ICD-10 usability gate,
# so a positive hit also proves that gate is gone. Synthetic data.

act_tasks <- tibble::tibble(
    task_id = paste0("A", 1:3, "::t"),
    PATID = paste0("P", 1:3),
    anchor_date = as.Date("2024-06-01"))

# pmsi$actes: CODEACTE (CCAM), DATEACTE (point time). P1 has the target act in the
# window; P2 has it OUT of the window; P3 has a different act.
act_rows <- tibble::tibble(
    source_row_id = sprintf("acte:%03d", 1:3),
    PATID = c("P1", "P2", "P3"),
    EVTID = c("E1", "E2", "E3"),
    ELTID = c("L1", "L2", "L3"),
    CODEACTE = c("JAFA001", "JAFA001", "HGPC015"),
    DATEACTE = as.Date(c("2024-05-25", "2024-01-01", "2024-05-25")))

act_var <- function(codes = "JAFA001", match = "exact") {
    concept <- concept_spec(
        name = "kidney_transplant_act",
        channels = list(
            transplant_act = act_channel(
                source = "pmsi_actes",
                selector = ccam(codes, match = match),
                required_roles = c("subject_id", "event_id", "date", "code",
                                   "source_item_id"),
                linkage = "subject")))
    variable_spec(
        name = "transplant_act", concept = concept, output_one_row_per = "PATID",
        anchor = "anchor_date",
        window = before_anchor(days = 30L, grace_days = 0L),
        channels = list(transplant_act = use_channel()),
        output = bin_output())
}

test_that("act_channel matches CCAM codes over pmsi$actes with point-window scope", {
    run <- run_variable(act_var(), act_tasks, list(pmsi_actes = act_rows))
    value <- setNames(run$values$value, run$values$task_id)

    expect_equal(value[["A1::t"]], 1L)   # JAFA001 within 30d of the anchor
    expect_equal(value[["A2::t"]], 0L)   # JAFA001 but ~5 months before -> out of window
    expect_equal(value[["A3::t"]], 0L)   # a different act (HGPC015)

    # The CCAM code materialises as evidence via CODEACTE (an ICD-10 gate would have
    # dropped it as "malformed"); only the in-window row is selected.
    ev <- run$evidence[run$evidence$task_id == "A1::t", ]
    expect_equal(ev$evidence_ref, "acte:001")
})
