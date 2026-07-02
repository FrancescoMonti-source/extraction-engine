# Disposable probe (NOT a shipped concept): does index_event derive a PER-SUBJECT anchor
# from a matched event, so windowing keys off that derived date? DESIGN §7/§14: an anchor
# may be DERIVED from an event (transplant_date()/surgery_date()); index_event is the
# generic form -- per subject, find the event matching a code selector and anchor at its
# date-role. It runs as an anchor-resolution PASS (produce (subject, anchor_date)) BEFORE
# normal windowing, NOT an inter-channel dependency.
#
# Discriminator: two patients, SAME measured-code date but DIFFERENT index-event dates.
# P1's index stay (Z94 transplant-status code) starts 2024-06-01; P2's starts 2024-01-01.
# Both carry an E11 diabetes code dated 2024-05-20. With anchor = index_event(... at
# event_start) + a 30-day before-anchor window: P1's window [2024-05-02, 2024-06-01]
# CONTAINS 2024-05-20 (present); P2's window [2023-12-02, 2024-01-01] does NOT (absent).
# Same E11 date, opposite outcome -> the anchor was derived per-subject from its event.
# (pmsi_diag already maps DATENT -> event_start, so no source-spec change is needed.)

ix_diag <- tibble::tibble(
    source_row_id = c("z1", "z2", "e1", "e2"),
    PATID   = c("P1", "P2", "P1", "P2"),
    EVTID   = c("S1", "S2", "S1b", "S2b"),
    ELTID   = c("L1", "L2", "L3", "L4"),
    diag    = c("Z94.0", "Z94.0", "E11.9", "E11.9"),
    DATENT  = as.Date(c("2024-06-01", "2024-01-01", "2024-05-20", "2024-05-20")),
    DATSORT = as.Date(c("2024-06-10", "2024-01-05", "2024-05-21", "2024-05-21")))

ix_tasks <- tibble::tibble(task_id = c("P1::t", "P2::t"), PATID = c("P1", "P2"))
    # NB: NO anchor_date column -- index_event computes it.

ix_concept <- concept_spec(
    name = "diabetes_ix",
    channels = list(
        dm_code = code_channel(
            source = "pmsi_diag", selector = icd10("^E11"),
            required_roles = c("subject_id", "event_id", "event_start",
                               "event_end", "code", "source_item_id"),
            linkage = "subject")))

test_that("index_event derives a per-subject anchor from the matched event", {
    ix_spec <- variable_spec(
        name = "dm_before_index_stay",
        concept = ix_concept,
        output_one_row_per = "PATID",
        anchor = index_event(source = "pmsi_diag", selector = icd10("^Z94"),
                             at = "event_start"),
        window = before_anchor(days = 30L, grace_days = 0L),
        channels = list(dm_code = use_channel()),
        output = bin_output())

    run <- run_variable(ix_spec, ix_tasks, list(pmsi_diag = ix_diag))
    value <- setNames(run$values$value, run$values$task_id)

    expect_equal(value[["P1::t"]], 1L)   # E11 (05-20) within 30d before P1 index DATENT 06-01
    expect_equal(value[["P2::t"]], 0L)   # same E11 date, but P2 index DATENT 01-01 -> out of window
})

# Single-match is a DELIBERATE boundary (multi-match is the future candidate_selection
# path). Silently picking an arbitrary event would give a wrong anchor -> wrong cohort
# membership, invisibly. So multiple index events per subject must ERROR, not resolve.
test_that("index_event errors on multiple matching events per subject", {
    two_index <- tibble::tibble(
        source_row_id = c("z1", "z2"), PATID = c("P1", "P1"),
        EVTID = c("S1", "S2"), ELTID = c("L1", "L2"),
        diag = c("Z94.0", "Z94.0"),
        DATENT = as.Date(c("2024-06-01", "2023-01-01")),
        DATSORT = as.Date(c("2024-06-10", "2023-01-05")))
    spec <- variable_spec(
        name = "dm_before_index_stay", concept = ix_concept,
        output_one_row_per = "PATID",
        anchor = index_event("pmsi_diag", icd10("^Z94"), at = "event_start"),
        window = before_anchor(days = 30L, grace_days = 0L),
        channels = list(dm_code = use_channel()), output = bin_output())
    expect_error(
        run_variable(spec, tibble::tibble(task_id = "P1::t", PATID = "P1"),
                     list(pmsi_diag = two_index)),
        "multiple events")
})
