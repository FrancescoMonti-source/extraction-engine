# Disposable probe (NOT a shipped concept): aggregate membership predicates --
# the SQL HAVING shape (DESIGN §16 item 7, owner-greenlit 2026-07-05: "hit if
# mean hb < 10" is something the engine must be capable to do). Plain words: a
# channel filter usually tests each row alone; here membership is decided by a
# GROUP aggregate -- "anaemic stay = the stay's mean Hb below 10". In pipeline
# terms still a row FILTER, `group_by(EVTID) |> filter(mean(value) < 10)`: the
# qualifying groups keep their ORIGINAL source rows (hits, evidence, provenance
# all point at real rows; no synthetic aggregate rows).
#
# Proposed spelling (channel definition, no wrapper -- the engine must interpret
# both parts, but two plain params carry them):
#   group_at_level  = "EVTID"                  the level whose groups are tested
#   keep_group_when = function(v) mean(v) < 10 plain closure over the group's values
# Reduction-as-VALUE stays output-only (num/cat reduce); this is the one shape
# where a reduction participates in MEMBERSHIP.

am_tasks <- tibble::tibble(
    grain_id = paste0("AM", 1:4, "::t"),
    PATID = paste0("AM", 1:4))

am_biol_row <- function(srid, patid, evtid, value, date) tibble::tibble(
    source_row_id = srid, PATID = patid, EVTID = evtid,
    ELTID = paste0("L", srid), BIOL_ID = paste0("B", srid),
    DATEXAM = as.Date(date), analyte = "HGB",
    value = value, value_raw = as.character(value))

am_biol <- dplyr::bind_rows(
    am_biol_row("b1", "AM1", "SA", 9,  "2024-01-10"),
    am_biol_row("b2", "AM1", "SA", 10, "2024-01-11"),   # SA mean 9.5  -> qualifies
    am_biol_row("b3", "AM2", "SB", 11, "2024-01-10"),
    am_biol_row("b4", "AM2", "SB", 12, "2024-01-11"),   # SB mean 11.5 -> out
    # AM3: no HGB at all -> channel silent (partial), not an ascertained negative
    am_biol_row("b5", "AM4", "SC", 9,  "2024-01-10"),
    am_biol_row("b6", "AM4", "SC", 9,  "2024-01-11"),   # SC qualifies
    am_biol_row("b7", "AM4", "SD", 14, "2024-02-10"),
    am_biol_row("b8", "AM4", "SD", 14, "2024-02-11"),   # SD does not
    # combine-interaction patients (separate task set below)
    am_biol_row("b9",  "AM5", "SE", 8, "2024-01-10"),
    am_biol_row("b10", "AM5", "SE", 9, "2024-01-11"),   # SE qualifies
    am_biol_row("b11", "AM6", "SF", 8, "2024-01-10"))   # SF qualifies

am_acts <- tibble::tibble(
    source_row_id = c("t1", "t2", "u1", "u2", "u3", "u4"),
    PATID    = c("AM5", "AM6", "AM7", "AM7", "AM8", "AM8"),
    EVTID    = c("SE",  "SG",  "SH",  "SH",  "SI",  "SJ"),
    #             AM5: transfusion IN the anaemic stay; AM6: in ANOTHER stay.
    #             AM7: TWO acts in ONE stay; AM8: two acts in DIFFERENT stays.
    ELTID    = paste0("K", 1:6),
    CODEACTE = "FELF011",
    DATEACTE = as.Date("2024-01-11") + 0:5)

am_sources <- list(biology = am_biol, pmsi_actes = am_acts)

am_concept <- concept_spec(
    name = "anemia_stay",
    channels = list(
        hb_anemic_stay = lab_channel(
            source = "biology",
            selector = analyte("HGB"),
            group_at_level = "EVTID",
            keep_group_when = function(v) mean(v) < 10),
        transfusion = act_channel(
            source = "pmsi_actes",
            selector = ccam("FELF011", match = "exact"),
            linkage = "subject")))

test_that("membership by group aggregate: qualifying stays' original rows are the hits", {
    spec <- variable_spec(
        name = "has_anemic_stay",
        concept = am_concept,
        output_one_row_per = "PATID",
        channels = list(hb_anemic_stay = use_channel()),
        output = bin_output())
    run <- run_variable(spec, am_tasks, am_sources)
    value <- setNames(run$values$value, run$values$grain_id)
    coverage <- setNames(run$values$channel_coverage, run$values$grain_id)

    expect_equal(value[["AM1::t"]], 1L)   # mean(9, 10) = 9.5 < 10
    expect_equal(value[["AM2::t"]], 0L)   # measurements exist, no qualifying stay
    expect_equal(coverage[["AM2::t"]], "complete")   # ascertained negative
    expect_equal(value[["AM3::t"]], 0L)   # no Hb at all
    expect_equal(coverage[["AM3::t"]], "partial")    # silence, not a negative
    expect_equal(value[["AM4::t"]], 1L)   # one qualifying stay among two

    # Provenance intact: the hit's evidence is the qualifying group's ORIGINAL
    # rows -- and ONLY those (AM4's non-qualifying stay SD contributes nothing).
    ev4 <- run$evidence[run$evidence$grain_id == "AM4::t", ]
    expect_setequal(ev4$source_row_id, c("b5", "b6"))
})

test_that("group-filtered rows feed the level algebra (anaemic stay & same-stay act)", {
    spec <- variable_spec(
        name = "transfused_anemic_stay",
        concept = am_concept,
        output_one_row_per = "PATID",
        channels = list(hb_anemic_stay = use_channel(),
                        transfusion = use_channel()),
        combine_channels = "hb_anemic_stay & transfusion",
        combine_at_level = "EVTID",
        output = bin_output())
    tasks <- tibble::tibble(grain_id = c("AM5::t", "AM6::t"),
                            PATID = c("AM5", "AM6"))
    run <- run_variable(spec, tasks, am_sources)
    value <- setNames(run$values$value, run$values$grain_id)

    expect_equal(value[["AM5::t"]], 1L)   # transfusion IN the anaemic stay SE
    expect_equal(value[["AM6::t"]], 0L)   # anaemic SF, transfusion in SG
})

test_that("the group predicate contract fails closed", {
    # A closure breaking its own contract (not exactly one TRUE/FALSE) is a hard
    # error, not a review state -- same rule as a payload reduce (DESIGN §8).
    broken <- concept_spec(
        name = "broken_group_rule",
        channels = list(hb = lab_channel(
            source = "biology", selector = analyte("HGB"),
            group_at_level = "EVTID",
            keep_group_when = function(v) mean(v))))   # numeric, not logical
    spec <- variable_spec(
        name = "broken", concept = broken,
        output_one_row_per = "PATID",
        channels = list(hb = use_channel()),
        output = bin_output())
    expect_error(run_variable(spec, am_tasks, am_sources), "TRUE/FALSE")
})

test_that("the group predicate pair is validated at declaration time", {
    # The closure without a level has no groups to test.
    expect_error(
        lab_channel(source = "biology", selector = analyte("HGB"),
                    keep_group_when = function(v) mean(v) < 10),
        "group_at_level")
    # The level without a closure is dead weight.
    expect_error(
        lab_channel(source = "biology", selector = analyte("HGB"),
                    group_at_level = "EVTID"),
        "keep_group_when")
    # Groups live on the identity spine.
    expect_error(
        lab_channel(source = "biology", selector = analyte("HGB"),
                    group_at_level = "WARD",
                    keep_group_when = function(v) mean(v) < 10),
        "spine")
    expect_error(
        lab_channel(source = "biology", selector = analyte("HGB"),
                    group_at_level = "EVTID",
                    keep_group_when = "mean < 10"),
        "function")
})

# Owner ruling 2026-07-05: the group predicate rides every structured channel
# ("it will be needed 100%"). For code/act the closure sees the group's CODES,
# so frequency criteria are plain length() rules.
test_that("a coded frequency rule: at least two acts in the SAME stay", {
    grouped_acts <- concept_spec(
        name = "grouped_acts",
        channels = list(acts = act_channel(
            source = "pmsi_actes",
            selector = ccam("FELF011", match = "exact"),
            group_at_level = "EVTID",
            keep_group_when = function(codes) length(codes) >= 2)))
    spec <- variable_spec(
        name = "repeated_act_same_stay", concept = grouped_acts,
        output_one_row_per = "PATID",
        channels = list(acts = use_channel()),
        output = bin_output())
    tasks <- tibble::tibble(grain_id = c("AM7::t", "AM8::t"),
                            PATID = c("AM7", "AM8"))
    run <- run_variable(spec, tasks, am_sources)
    value <- setNames(run$values$value, run$values$grain_id)
    coverage <- setNames(run$values$channel_coverage, run$values$grain_id)

    expect_equal(value[["AM7::t"]], 1L)   # two acts in stay SH
    expect_equal(value[["AM8::t"]], 0L)   # two acts, but one per stay
    expect_equal(coverage[["AM8::t"]], "complete")   # ascertained, not silence
    # Evidence = the qualifying stay's original act rows.
    ev7 <- run$evidence[run$evidence$grain_id == "AM7::t", ]
    expect_setequal(ev7$source_row_id, c("u1", "u2"))
})

test_that("a text channel with a group predicate is rejected loudly at run time", {
    # A text hit is an LLM answer grounded on cited rows; a group rule that
    # empties the citations would have to overturn the answer -- that fork
    # (absent? unevaluable?) is undecided, so the engine refuses rather than
    # silently ignoring the rule.
    grouped_text <- concept_spec(
        name = "grouped_text",
        channels = list(mentions = text_channel(
            source = "documents",
            selector = lucene_query("anemie"),
            extractor = binary_presence_text_definition(
                name = "t", status_key = "s", field = "f",
                system_prompt = "p"),
            linkage = "subject",
            group_at_level = "EVTID",
            keep_group_when = function(v) length(v) >= 2)))
    spec <- variable_spec(
        name = "grouped_text_probe", concept = grouped_text,
        output_one_row_per = "PATID",
        channels = list(mentions = use_channel()),
        output = bin_output())
    expect_error(
        run_variable(spec, am_tasks,
                     list(documents = list(coverage = tibble::tibble(),
                                           candidates = tibble::tibble())),
                     caller = function(...) NULL, model_name = "fake"),
        "text")
})
