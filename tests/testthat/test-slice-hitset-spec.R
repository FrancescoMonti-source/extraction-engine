# Contract tests for the boolean set-algebra slice: hit_set_difference() (the NOT
# operator). Boolean logic is SET ALGEBRA over explicit hit sets, not clinical
# ontology: `A NOT B` = setdiff(union(include hits), union(exclude hits)). It means
# "in A's hit set and not in B's hit set under the SELECTED B definition" -- NOT "B
# is clinically absent". The envelope must expose both hit sets with provenance
# (role + contribution + evidence) and keep the label honest (a task kept only
# because the exclude channel was UNAVAILABLE is flagged partial, never read as an
# inferred clinical absence). Two code channels over synthetic data; no model.

# Synthetic code vehicles (prefixes are real-shaped so they pass the ICD-10 usability
# check, but the families here are illustrative, not a validated definition): include
# = transplant-status Z94 in the `acts` source; exclude = machine/dialysis-dependence
# Z99 in a SEPARATE `exclusion_dx` source -- separate sources so a task can establish
# inclusion while the exclusion channel is genuinely unavailable.
hs_concept <- function() {
    concept_spec(
        name = "act_minus_signal",
        channels = list(
            act_present = code_channel(
                source = "acts",
                selector = icd10("Z94"),
                native_grain = "diagnosis_row",
                required_roles = c("subject", "event", "interval_start",
                                   "interval_end", "code", "native_ref"),
                linkage = "subject"),
            signal_present = code_channel(
                source = "exclusion_dx",
                selector = icd10("Z99"),
                native_grain = "diagnosis_row",
                required_roles = c("subject", "event", "interval_start",
                                   "interval_end", "code", "native_ref"),
                linkage = "subject")))
}

hs_var <- function(channels = list(act_present = use_channel(),
                                   signal_present = use_channel()),
                   combine = hit_set_difference(include = "act_present",
                                                exclude = "signal_present")) {
    variable_spec(
        name = "act_without_signal_hit", concept = hs_concept(),
        unit = "transplant", anchor = "anchor_date",
        window = before_anchor(days = 1825L, grace_days = 7L),
        channels = channels, output = binary_output(),
        combine = combine, absence_policy = open_world())
}

hs_tasks <- tibble::tibble(
    task_id = paste0("HS", 1:5, "::t"),
    PATID = paste0("P", 1:5),
    anchor_date = as.Date("2024-06-01"))

hs_row <- function(srid, patid, code) tibble::tibble(
    source_row_id = srid, PATID = patid, EVTID = paste0("E", patid),
    ELTID = paste0("L", srid), diag = code,
    DATENT = as.Date("2024-05-20"), DATSORT = as.Date("2024-05-21"))

# include source: P1/P2/P3 have a Z94 include hit; P4 has only a non-matching code
# (in scope -> ascertained negative); P5 has NO act rows at all (unavailable).
hs_acts <- dplyr::bind_rows(
    hs_row("acts:001", "P1", "Z940"),
    hs_row("acts:002", "P2", "Z940"),
    hs_row("acts:003", "P3", "Z940"),
    hs_row("acts:004", "P4", "I10"))

# exclude source: P1 has a non-matching code (ascertained negative); P3/P5 have a
# Z99 exclude hit; P2/P4 have NO exclude rows (exclusion unavailable).
hs_exdx <- dplyr::bind_rows(
    hs_row("exdx:001", "P1", "I10"),
    hs_row("exdx:003", "P3", "Z992"),
    hs_row("exdx:005", "P5", "Z992"))

hs_sources <- list(acts = hs_acts, exclusion_dx = hs_exdx)

hs_run <- function(...) run_variable(hs_var(), hs_tasks, hs_sources, ...)

# Why: the full decision x ascertainment matrix of A NOT B as set algebra.
test_that("hit_set_difference resolves setdiff(include, exclude) per task", {
    run <- hs_run()
    val <- setNames(run$values$value, run$values$task_id)
    dec <- setNames(run$values$decision, run$values$task_id)
    asc <- setNames(run$values$ascertainment, run$values$task_id)

    # in include set, no exclude hit, exclusion ascertained -> kept, complete
    expect_equal(val[["HS1::t"]], 1L)
    expect_equal(dec[["HS1::t"]], "included")
    expect_equal(asc[["HS1::t"]], "complete")

    # in include set, NO exclude hit but exclusion UNAVAILABLE -> kept, but partial
    expect_equal(val[["HS2::t"]], 1L)
    expect_equal(dec[["HS2::t"]], "included")
    expect_equal(asc[["HS2::t"]], "partial")

    # in include set AND in exclude set -> setdiff removes it
    expect_equal(val[["HS3::t"]], 0L)
    expect_equal(dec[["HS3::t"]], "excluded")
    expect_equal(asc[["HS3::t"]], "complete")

    # not in include set (ascertained negative) -> out, complete
    expect_equal(val[["HS4::t"]], 0L)
    expect_equal(dec[["HS4::t"]], "no_include_hit")
    expect_equal(asc[["HS4::t"]], "complete")

    # not in include set because include UNAVAILABLE -> out, partial (even though it
    # is in the exclude set, the result keys on inclusion first)
    expect_equal(val[["HS5::t"]], 0L)
    expect_equal(dec[["HS5::t"]], "no_include_hit")
    expect_equal(asc[["HS5::t"]], "partial")

    expect_equal(run$combine_rule, "hit_set_difference")
    expect_equal(run$selected_channels$channel, c("act_present", "signal_present"))
})

# Why: THE honesty invariant. A task kept ONLY because the exclude channel was
# unavailable must NOT be reported as a definitive "act and no signal" -- it is
# "act and no signal HIT (exclusion not ascertained)". That is the partial flag on
# HS2, distinguishing it from HS1 where the exclusion was actually ascertained.
test_that("kept-because-no-exclude-HIT is flagged when exclusion is unavailable", {
    run <- hs_run()
    asc <- setNames(run$values$ascertainment, run$values$task_id)
    # same value + decision...
    expect_equal(run$values$value[run$values$task_id == "HS1::t"],
                 run$values$value[run$values$task_id == "HS2::t"])
    # ...but ascertainment honestly distinguishes ascertained vs unavailable exclusion
    expect_equal(asc[["HS1::t"]], "complete")
    expect_equal(asc[["HS2::t"]], "partial")
})

# Why: both hit sets must be visible with provenance -- which channel is the
# inclusion, which is the exclusion, and how each contributed per task.
test_that("source contribution exposes include/exclude roles transparently", {
    run <- hs_run()
    ss <- run$source_status
    get <- function(tid, ch, col) ss[[col]][ss$task_id == tid & ss$channel == ch]

    expect_equal(unique(ss$role[ss$channel == "act_present"]), "include")
    expect_equal(unique(ss$role[ss$channel == "signal_present"]), "exclude")

    # HS1: include carried the signal; exclude ascertained a negative
    expect_equal(get("HS1::t", "act_present", "contribution"), "signal")
    expect_equal(get("HS1::t", "signal_present", "contribution"), "negative")

    # HS3: BOTH channels hit (in include AND in exclude) -- setdiff still removes it,
    # but the contribution view shows both signals
    expect_equal(get("HS3::t", "act_present", "contribution"), "signal")
    expect_equal(get("HS3::t", "signal_present", "contribution"), "signal")

    # HS2: exclude silent because the source had no rows for the subject (WHY is kept)
    expect_equal(get("HS2::t", "signal_present", "contribution"), "silent")
    expect_equal(get("HS2::t", "signal_present", "processing_state"), "no_eligible_source")

    # HS5: include silent (could not establish inclusion)
    expect_equal(get("HS5::t", "act_present", "contribution"), "silent")
})

# Why: evidence refs for BOTH inclusion and exclusion hits, tagged by role, so the
# researcher can audit WHY a task was kept and WHY one was removed.
test_that("evidence carries refs for both inclusion and exclusion hits", {
    run <- hs_run()
    ev <- run$evidence
    expect_true(all(c("role", "channel", "evidence_ref") %in% names(ev)))

    # HS3 hit both an include and an exclude signal -> one evidence row per role
    ev3 <- ev[ev$task_id == "HS3::t", ]
    expect_setequal(ev3$role, c("include", "exclude"))
    expect_setequal(ev3$channel, c("act_present", "signal_present"))
    expect_true(all(nzchar(ev3$evidence_ref)))

    # the exclusion that REMOVED HS3 is auditable (its evidence ref is the DIA row)
    expect_equal(ev3$evidence_ref[ev3$role == "exclude"], "exdx:003")

    # a channel that did NOT hit contributes no evidence (HS1 exclude was a negative)
    expect_equal(nrow(ev[ev$task_id == "HS1::t" & ev$role == "exclude", ]), 0L)
})

# Why: the pure set-algebra core, isolated from channels -- plain R over named id
# sets. OR-within-role (union), difference between the unions, exclude-only ids
# reported (not silently dropped).
test_that("hit_set_decision() is plain setdiff over named hit sets", {
    d <- hit_set_decision(
        universe = c("a", "b", "c", "d"),
        include_sets = list(act = c("a", "b", "c")),
        exclude_sets = list(sig = c("b")))
    dec <- setNames(d$decision, d$id)
    expect_equal(dec[["a"]], "included")
    expect_equal(dec[["b"]], "excluded")
    expect_equal(dec[["c"]], "included")
    expect_equal(dec[["d"]], "no_include_hit")
    expect_equal(d$included, c(TRUE, FALSE, TRUE, FALSE))

    # OR within each role: include = union(x,y); exclude = union(p,q)
    d2 <- hit_set_decision(
        c("a", "b", "c"),
        include_sets = list(x = "a", y = "b"),
        exclude_sets = list(p = "b", q = "c"))
    expect_equal(setNames(d2$decision, d2$id)[c("a", "b", "c")],
                 c(a = "included", b = "excluded", c = "no_include_hit"))
    # an exclude-only id stays out, but is still reported over the universe
    expect_true(all(c("a", "b", "c") %in% d2$id))
})

test_that("hit_set_difference() guards its roles", {
    expect_error(hit_set_difference(include = character()), "include")
    expect_error(hit_set_difference(include = "a", exclude = "a"), "both")
})

# Why: the operator's roles must match the variable's activated channels -- a
# referenced-but-unactivated channel is a spec error, not a silent empty hit set.
test_that("hit_set_difference rejects a referenced-but-unactivated channel", {
    bad <- hs_var(channels = list(act_present = use_channel()))   # exclude not activated
    expect_error(run_variable(bad, hs_tasks, hs_sources), "unactivated")
})
