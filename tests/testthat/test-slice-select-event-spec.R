# Disposable probe (NOT a shipped concept): index_event(select_event =) -- the
# researcher's rule for a subject with SEVERAL index events (DESIGN §7,
# invariant 35; consumer §14.8 "earliest of several surgeries"). Plain words:
# select_event decides WHERE THE CLOCK STARTS when the anchor source matches
# more than one event. slice_min = "the first surgery starts the clock";
# identity = "EVERY surgery starts its own clock" -> one task per event, and
# the output grain must say so (one row per index event, not per patient).
#
# Fixture: P1 has spinal surgery in March (stay X1) and again in June (stay
# X2); the revision act happens in November -- inside June's 180-day window,
# OUTSIDE March's. P2 has one surgery, no complication.

se_acts <- tibble::tibble(
    source_row_id = paste0("s", 1:4),
    PATID    = c("P1", "P1", "P2", "P1"),
    EVTID    = c("X1", "X2", "Y1", "X9"),
    ELTID    = paste0("A", 1:4),
    CODEACTE = c("SURG01", "SURG01", "SURG01", "LAVA001"),
    DATEACTE = as.Date(c("2024-03-01", "2024-06-01", "2024-03-15",
                         "2024-11-01")))
    # 2024-11-01 is 153 days after June 1 (in), 245 after March 1 (out).

se_concept <- concept_spec(
    name = "post_surgical_revision",
    channels = list(
        act_revision = act_channel(
            source = "pmsi_actes",
            selector = ccam("LAVA001", match = "exact"),
            linkage = "subject")))

se_var <- function(select_event, output_one_row_per = "PATID") {
    variable_spec(
        name = "revision_180d_post_surgery",
        concept = se_concept,
        output_one_row_per = output_one_row_per,
        anchor = index_event("pmsi_actes", ccam("SURG01", match = "exact"),
                             at = "point_date",
                             select_event = select_event),
        window = c(0, 180),
        channels = c("act_revision"),
        output = bin_output())
}

se_tasks <- tibble::tibble(grain_id = c("P1::t", "P2::t"),
                           PATID = c("P1", "P2"))
se_sources <- list(pmsi_actes = se_acts)

test_that("select_event picks the anchoring event (first surgery starts the clock)", {
    run <- run_variable(
        se_var(select_event = function(d) dplyr::slice_min(d, point_date, n = 1)),
        se_tasks, se_sources)
    value <- setNames(run$values$value, run$values$grain_id)

    expect_equal(value[["P1::t"]], 0L)   # March clock: November revision is out
    expect_equal(value[["P2::t"]], 0L)
    # The executed rule is provenance, like a reduce.
    expect_match(run$provenance$anchor$select_event, "slice_min")
})

test_that("select_event = identity emits one task per event, each with its own window", {
    run <- run_variable(se_var(select_event = identity,
                               output_one_row_per = "EVTID"),
                        se_tasks, se_sources)
    value <- setNames(run$values$value, run$values$grain_id)

    # P1 became two rows: one clock per surgery. Same patient, same November
    # revision -- in for the June surgery, out for the March one.
    expect_equal(value[["P1::t::X1"]], 0L)
    expect_equal(value[["P1::t::X2"]], 1L)
    expect_equal(value[["P2::t::Y1"]], 0L)
    expect_equal(nrow(run$values), 3L)
})

test_that("several kept events under patient-grain output fail loudly", {
    expect_error(
        run_variable(se_var(select_event = identity), se_tasks, se_sources),
        "one task per patient")
})

test_that("a closure dropping the anchor columns is rejected", {
    expect_error(
        run_variable(se_var(select_event = function(d) d["PATID"]),
                     se_tasks, se_sources),
        "EVTID")
})
