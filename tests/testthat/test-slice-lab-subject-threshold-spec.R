# Disposable probe (NOT a shipped concept): can a lab channel decide membership by a
# SUBJECT-CONTEXT cutoff -- a reference range that depends on the patient's sex/age,
# not a single fixed number? This is the real shape of anaemia (owner 2026-07-07:
# "una cosa tipica della biologia con valori uomo donna diversi e che variano con
# l'eta"): Hb < 12 g/dL in women, < 13 g/dL in men. DESIGN §8: the fixed gt/lt bound
# generalises to analyte_value(keep_when =), a plain vectorised predicate whose
# FORMALS NAME RAW COLUMNS on the analyte's rows (the measured `value` plus subject
# attributes the source carries, PATSEX/PATAGE) -- the reducers-are-plain-functions
# rule extended to membership: the researcher's closure IS the rule, not a sex-keyed
# threshold table the engine would interpret.
#
# Invariant locked: the hit reads an attribute OFF THE ROW. The discriminator is one
# haemoglobin value, 12.5 g/dL, measured in a woman and in a man: the woman is NOT
# anaemic (12.5 is not < 12) and the man IS (12.5 < 13). A single-number cutoff
# cannot separate them; only a predicate that sees PATSEX can. Three-valued like
# every structured channel: below the sex cutoff = TRUE, an in-range measurement
# above it = observed FALSE (coverage complete), no measurement = unevaluable (NA,
# coverage partial).

anemia_tasks <- tibble::tibble(
    grain_id = paste0("P", 1:5, "::t"),
    PATID = paste0("P", 1:5),
    anchor_date = as.Date("2024-06-01"))

hgb_row <- function(srid, patid, sex, value) tibble::tibble(
    source_row_id = srid, PATID = patid, EVTID = paste0("E", patid),
    ELTID = paste0("L", srid), BIOL_ID = paste0("B", srid),
    DATEXAM = as.Date("2024-06-01"), analyte = "HGB",
    value_raw = as.character(value), value = value,
    PATSEX = sex, PATAGE = 50)

anemia_biol <- dplyr::bind_rows(
    hgb_row("h1", "P1", "F", 11.0),    # woman, 11 < 12  -> anaemic (hit)
    hgb_row("h2", "P2", "F", 12.5),    # woman, 12.5 !< 12 -> measured, observed FALSE
    hgb_row("h3", "P3", "M", 12.5),    # man,   12.5 < 13 -> anaemic (hit) -- SAME value as P2
    hgb_row("h4", "P4", "M", 14.0))    # man,   14 !< 13 -> measured, observed FALSE
    # P5: no biology row at all -> the source is unevaluable for the subject (NA)

anemia_concept <- function() concept_spec(
    name = "anaemia",
    channels = list(
        hb = lab_channel(
            source = "biology",
            selector = analyte("HGB"),
            required_roles = c("subject_id", "event_id", "point_date", "value_num",
                               "value_str", "analyte", "source_item_id",
                               "source_result_id"),
            linkage = "subject")))

test_that("a subject-context analyte predicate decides membership per patient sex", {
    var <- variable_spec(
        name = "anemie_sexe", concept = anemia_concept(),
        output_one_row_per = "PATID", anchor = "anchor_date",
        window = c(-7, 7),
        channels = list(hb = use_channel(selector = analyte_value(
            "HGB", keep_when = \(value, PATSEX) value < ifelse(PATSEX == "F", 12, 13)))),
        output = bin_output())

    run <- run_variable(var, anemia_tasks, list(biology = anemia_biol))
    value <- setNames(run$values$value, run$values$grain_id)
    cov <- setNames(run$values$channel_coverage, run$values$grain_id)

    expect_equal(value[["P1::t"]], 1L)   # F 11.0  < 12
    expect_equal(value[["P2::t"]], 0L)   # F 12.5 !< 12  (measured, below-threshold negative)
    expect_equal(value[["P3::t"]], 1L)   # M 12.5  < 13  -- the sex discriminator
    expect_equal(value[["P4::t"]], 0L)   # M 14.0 !< 13
    expect_equal(value[["P5::t"]], 0L)   # no biology at all

    # FALSE (evaluated, no hit) vs NA (unevaluable) rides on coverage.
    expect_equal(cov[["P2::t"]], "complete")
    expect_equal(cov[["P5::t"]], "partial")

    # Evidence is the qualifying rows only: the woman at 12.5 and the man at 14 are
    # in-range for their own sex, so they are not hits and contribute no evidence.
    hit_ev <- run$evidence[run$evidence$grain_id %in% c("P1::t", "P3::t"), ]
    expect_setequal(hit_ev$evidence_ref, c("h1", "h3"))
    expect_equal(nrow(run$evidence[run$evidence$grain_id == "P2::t", ]), 0L)
})

test_that("a keep_when predicate breaking its contract is a hard error, not a silent pass", {
    # (a) a formal naming a column the source does not carry.
    bad_col <- variable_spec(
        name = "anemie_badcol", concept = anemia_concept(),
        output_one_row_per = "PATID", anchor = "anchor_date", window = c(-7, 7),
        channels = list(hb = use_channel(selector = analyte_value(
            "HGB", keep_when = \(value, PATWEIGHT) value < PATWEIGHT))),
        output = bin_output())
    expect_error(
        run_variable(bad_col, anemia_tasks, list(biology = anemia_biol)),
        "PATWEIGHT")

    # (b) a predicate returning the wrong shape (one scalar instead of one per row).
    bad_shape <- variable_spec(
        name = "anemie_badshape", concept = anemia_concept(),
        output_one_row_per = "PATID", anchor = "anchor_date", window = c(-7, 7),
        channels = list(hb = use_channel(selector = analyte_value(
            "HGB", keep_when = \(value) any(value < 12)))),
        output = bin_output())
    expect_error(
        run_variable(bad_shape, anemia_tasks, list(biology = anemia_biol)),
        "one logical per row")
})

test_that("analyte_value rejects mixing fixed bounds with a keep_when predicate", {
    expect_error(
        analyte_value("HGB", lt = 12, keep_when = \(value, PATSEX) value < 12),
        "EITHER fixed bounds")
})
