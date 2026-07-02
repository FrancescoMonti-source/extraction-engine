# Disposable probe (NOT a shipped concept): post-operative complications, anchored on
# the CCAM act itself and scoped to the 30 days FOLLOWING it, seen through >=1 source.
#
# This is the first spec to compose three shipped-but-never-co-exercised axes:
#   1. an ACT-anchored derived anchor -- index_event(pmsi_actes, ccam(...), at="point_date")
#      resolves each subject's own surgery date (DATEACTE) as the anchor. "point_date" is
#      the point-event role a CCAM act carries (contrast the stay's event_start/event_end);
#      the default at="event_start" would (correctly) error on a point source.
#   2. a FORWARD window -- days_after(1, 30): the post-op direction, vs the before_anchor
#      windows every prior slice used.
#   3. a cross-source combine -- "pmsi_complication | redo_act": the complication is a hit
#      if EITHER a coded diagnosis (interval source) OR a reintervention act (point source)
#      lands in the post-op window. This stands in, deterministically, for the study's real
#      "docs OR pmsi" combine -- the text arm rides the same combine path (proven in
#      test-slice-hitset-expr-spec) but would drag in a live LLM, which is not what is new.
#
# Discriminator (all anchored on the index surgery HGFA011 @ 2024-05-10, window [05-11,06-09]):
#   P1 complication diag T81 @ +10d  -> in window            -> 1 (via pmsi_complication)
#   P2 complication diag T81 @ pre-op -> forward window excludes it, no redo -> 0
#   P3 no diag row at all, redo act @ +5d -> in window        -> 1 (via redo_act; diag NA)
#   P4 complication diag T81 @ +52d  -> past the 30d bound, no redo -> 0
# Same complication code, opposite outcomes by WHERE it falls relative to the act anchor.

aw_concept <- concept_spec(
    name = "post_op_complication",
    channels = list(
        pmsi_complication = code_channel(
            source = "pmsi_diag", selector = icd10("^T81"),
            required_roles = c("subject_id", "event_id", "event_start",
                               "event_end", "code", "source_item_id"),
            linkage = "subject"),
        redo_act = act_channel(
            source = "pmsi_actes", selector = ccam("HGFA012"),
            required_roles = c("subject_id", "event_id", "point_date", "code",
                               "source_item_id"),
            linkage = "subject")))

aw_var <- variable_spec(
    name = "complication_within_30d_of_surgery",
    concept = aw_concept,
    output_one_row_per = "PATID",
    anchor = index_event(source = "pmsi_actes", selector = ccam("HGFA011"),
                         at = "point_date"),
    window = days_after(from_days = 1L, to_days = 30L),
    channels = list(pmsi_complication = use_channel(), redo_act = use_channel()),
    output = bin_output(),
    combine = "pmsi_complication | redo_act")

aw_tasks <- tibble::tibble(
    task_id = paste0(c("P1", "P2", "P3", "P4"), "::t"),
    PATID = c("P1", "P2", "P3", "P4"))   # NB: no anchor_date -- index_event derives it

# pmsi_actes: every subject's index surgery (HGFA011 @ 05-10); P3 also a redo (HGFA012 @ +5d).
aw_actes <- tibble::tibble(
    source_row_id = c("act:1", "act:2", "act:3", "act:redo", "act:4"),
    PATID    = c("P1", "P2", "P3", "P3", "P4"),
    EVTID    = c("E1", "E2", "E3", "E3", "E4"),
    ELTID    = c("A1", "A2", "A3", "A3b", "A4"),
    CODEACTE = c("HGFA011", "HGFA011", "HGFA011", "HGFA012", "HGFA011"),
    DATEACTE = as.Date(c("2024-05-10", "2024-05-10", "2024-05-10",
                         "2024-05-15", "2024-05-10")))

# pmsi_diag: T81 postprocedural-complication stays. P3 has NO diag row (relies on the redo).
aw_diag <- tibble::tibble(
    source_row_id = c("dx:1", "dx:2", "dx:4"),
    PATID   = c("P1", "P2", "P4"),
    EVTID   = c("F1", "F2", "F4"),
    ELTID   = c("D1", "D2", "D4"),
    diag    = c("T81.4", "T81.4", "T81.4"),
    DATENT  = as.Date(c("2024-05-20", "2024-04-01", "2024-07-01")),
    DATSORT = as.Date(c("2024-05-22", "2024-04-03", "2024-07-03")))

test_that("an act-anchored, post-op forward window combines complication signals across sources", {
    run <- run_variable(aw_var, aw_tasks,
                        list(pmsi_actes = aw_actes, pmsi_diag = aw_diag))
    value <- setNames(run$values$value, run$values$task_id)

    expect_equal(value[["P1::t"]], 1L)   # T81 10d after the act
    expect_equal(value[["P2::t"]], 0L)   # T81 is PRE-op -> forward window excludes it
    expect_equal(value[["P3::t"]], 1L)   # no diag, but a redo act 5d after the act
    expect_equal(value[["P4::t"]], 0L)   # T81 52d after -> past the 30d bound

    expect_equal(run$combine_rule, "pmsi_complication | redo_act")

    # P3's complication rides the redo (point source) arm; the diagnosis arm is unevaluable
    # for P3 (no eligible rows), so its membership is NA -- absence is not observed-negative.
    m <- run$membership
    expect_true(is.na(m$hit[m$task_id == "P3::t" & m$channel == "pmsi_complication"]))
    expect_true(m$hit[m$task_id == "P3::t" & m$channel == "redo_act"])
})
