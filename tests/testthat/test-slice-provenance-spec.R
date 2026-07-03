# Disposable probe (NOT a shipped concept): does run_variable() output carry the
# produced-dataset PROVENANCE object (DESIGN §12, invariant 27: "Provenance is part
# of the output contract, not optional documentation")?
#
# Invariant locked: `run$provenance` records the RESOLVED definition that actually
# executed -- in particular, a channel activated with a LOCAL selector override
# (use_channel(selector = ...), DESIGN §14.3) is recorded with the OVERRIDE, not the
# concept baseline. This failure is silent and invisible to real validation: the
# values are computed correctly from the override, so a physician reviewing them sees
# nothing wrong -- only the audit trail lies about which definition produced them.
#
# Discriminator: the concept baseline is icd10("^E1[0-4]") and the activation
# override is icd10("^E1[0-2]"); a resolution regression that falls back to the
# baseline is detectably different in the recorded codes and in selector_source.

pv_tasks <- tibble::tibble(
    task_id = "S1::t", PATID = "S1", anchor_date = as.Date("2024-06-01"))

pv_diag <- tibble::tibble(
    source_row_id = "d1", PATID = "S1", EVTID = "E1", ELTID = "L1",
    diag = "E11.9", DATENT = as.Date("2024-05-20"), DATSORT = as.Date("2024-05-22"))

pv_biol <- tibble::tibble(
    source_row_id = "b1", PATID = "S1", EVTID = "E1", ELTID = "L2", BIOL_ID = "B1",
    DATEXAM = as.Date("2024-06-01"), analyte = "GLU.GLU",
    value_raw = "15", value = 15)

pv_concept <- concept_spec(
    name = "pv_diabetes",
    channels = list(
        dx = code_channel(
            source = "pmsi_diag", selector = icd10("^E1[0-4]"),
            required_roles = c("subject_id", "event_id", "event_start", "event_end",
                               "code", "source_item_id"),
            linkage = "subject"),
        glucose = lab_channel(
            source = "biology", selector = analyte("GLU.GLU"),
            required_roles = c("subject_id", "event_id", "point_date", "value_num",
                               "value_str", "analyte", "source_item_id",
                               "source_result_id"),
            linkage = "subject")))

pv_spec <- variable_spec(
    name = "pv_diabetes_or_glucose", concept = pv_concept,
    output_one_row_per = "PATID", anchor = "anchor_date",
    window = days_after(-30L, 30L),
    channels = list(
        dx = use_channel(selector = icd10("^E1[0-2]")),   # local override (§14.3)
        glucose = use_channel()),                          # concept baseline
    combine = "dx | glucose",
    output = bin_output())

pv_run <- run_variable(pv_spec, pv_tasks,
                       list(pmsi_diag = pv_diag, biology = pv_biol))

test_that("provenance records the RESOLVED definition: the overridden selector, not the concept baseline", {
    prov <- pv_run$provenance
    expect_s3_class(prov, "ee_provenance")

    # The overridden channel: the trail carries the activation's selector.
    expect_equal(prov$channels$dx$selector$codes, "^E1[0-2]")
    expect_equal(prov$channels$dx$selector_source, "activation")

    # The baseline channel: the concept default, marked as such.
    expect_equal(prov$channels$glucose$selector$codes, "GLU.GLU")
    expect_equal(prov$channels$glucose$selector_source, "channel")

    # The rest of the resolved definition rides along.
    expect_equal(prov$variable, "pv_diabetes_or_glucose")
    expect_equal(prov$concept, "pv_diabetes")
    expect_equal(prov$output_one_row_per, "PATID")
    expect_equal(prov$anchor, list(kind = "task_column", column = "anchor_date"))
    expect_equal(prov$window$from_days, -30L)
    expect_equal(prov$window$to_days, 30L)
    expect_equal(prov$combine, "dx | glucose")
    expect_equal(prov$output$kind, "binary")

    # Sanity: the value was computed FROM the override (E11.9 matches ^E1[0-2]) --
    # trail and execution describe the same run.
    expect_equal(pv_run$values$value, 1L)
})

test_that("provenance carries execution facts and the resolved source-role mappings", {
    prov <- pv_run$provenance

    expect_equal(prov$model, "fake")
    expect_s3_class(prov$executed_at, "POSIXct")

    # Resolved source mapping: which physical column played each role.
    expect_equal(prov$channels$dx$source_roles$code, "diag")
    expect_equal(prov$channels$dx$source_roles$event_start, "DATENT")
    expect_equal(prov$channels$glucose$source_roles$value_num, "value")
    expect_equal(prov$channels$glucose$source_roles$point_date, "DATEXAM")
})
