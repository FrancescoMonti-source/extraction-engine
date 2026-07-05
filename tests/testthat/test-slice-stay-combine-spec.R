# Disposable probe (NOT a shipped concept): combine_at_level -- the expression is
# checked PER STAY, then exists-lifted to the output grain (DESIGN §7, §14.8; the
# ratified pipeline model's last unwired semantic axis). Plain words: "text AND act"
# must mean "in the SAME stay", not "somewhere in the patient's window".
#
# Consumer A (§14.8, SSI post surgery): text_ssi & (cim10_ssi | act_revision) at
# EVTID, one row per PATID. The TRAP patient P1 has the text hit in stay S1A and
# the act in stay S1B: patient-level algebra says 1, stay-level must say 0.
# Consumer B (§14.9, mean Hb in anaemic stays): the gate qualifies stays, the
# payload (values_from) reads rows from QUALIFYING stays only -- including a
# payload channel that is not in the expression (hb_all), which is key-scoped,
# never a raw escape. Codes/terms here are synthetic vehicles, not validated
# ascertainment definitions.

sc_make_corpus <- function(eltids, texts) {
    corpustools::create_tcorpus(
        data.frame(ELTID = eltids, RECTXT = texts, stringsAsFactors = FALSE),
        text_columns = "RECTXT", doc_column = "ELTID",
        split_sentences = TRUE, remember_spaces = FALSE, verbose = FALSE)
}

# --- Consumer A: SSI within 180 days post surgery (bin at stay level) ----------
# Anchor = surgery date on the tasks (index_event/select_event stays §16-pending;
# researcher-supplied anchors are the already-shipped posture).

sc_tasks <- tibble::tibble(
    task_id = paste0("P", 1:5, "::t"),
    PATID = paste0("P", 1:5),
    anchor_date = as.Date("2024-01-01"))

sc_diag <- tibble::tibble(
    source_row_id = c("d1", "d2"),
    PATID   = c("P3", "P4"),
    EVTID   = c("S3", "S4"),
    ELTID   = c("L1", "L2"),
    diag    = c("T814", "T814"),
    DATENT  = as.Date(c("2024-02-08", "2024-02-08")),
    DATSORT = as.Date(c("2024-02-12", "2024-02-12")))

sc_acts <- tibble::tibble(
    source_row_id = c("a1", "a2", "a3", "a4"),
    PATID    = c("P1",  "P2",  "P2",  "P4"),
    EVTID    = c("S1B", "S2A", "S2B", "S4"),
    #            TRAP: P1's act is NOT in the text stay S1A
    ELTID    = c("K1", "K2", "K3", "K4"),
    CODEACTE = "LAVA001",
    DATEACTE = as.Date(c("2024-02-01", "2024-01-20", "2024-03-01", "2024-02-10")))

sc_docs_index <- tibble::tibble(
    ELTID   = c("E1", "E2", "E3", "E4", "E5"),
    PATID   = c("P1", "P2", "P3", "P4", "P5"),
    EVTID   = c("S1A", "S2A", "S3", "S4", "S5"),
    RECDATE = as.Date(c("2024-01-10", "2024-01-15", "2024-02-10",
                        "2024-02-11", "2024-04-01")),
    RECTYPE = "note")
sc_corpus <- sc_make_corpus(
    c("E1", "E2", "E3", "E4", "E5"),
    c("Infection du site operatoire confirmee ce jour.",
      "Reprise chirurgicale pour infection profonde de cicatrice.",
      "Infection du site avec abces paravertebral.",
      "Suites operatoires simples, cicatrice propre.",
      "Infection superficielle du site, soins locaux."))

sc_sources <- list(
    pmsi_diag  = sc_diag,
    pmsi_actes = sc_acts,
    documents  = list(corpus = sc_corpus, docs_index = sc_docs_index))

sc_ssi_fake <- function(prompt, type, system_prompt) {
    if (grepl("nfection", prompt)) {
        return(list(ssi_status = "documented", evidence_ids = list("S001")))
    }
    list(ssi_status = "not_documented", evidence_ids = list())
}

sc_ssi_concept <- concept_spec(
    name = "surgical_site_infection",
    channels = list(
        text_ssi = text_channel(
            source = "documents",
            selector = lucene_query("infection"),
            extractor = binary_presence_text_definition(
                name = "ssi_text", status_key = "ssi_status",
                field = "ssi_mention",
                system_prompt = paste(
                    "Identify only an explicitly documented surgical site",
                    "infection. Do not infer absence from silence.")),
            linkage = "subject"),
        cim10_ssi = code_channel(
            source = "pmsi_diag",
            selector = icd10("T814", match = "exact"),
            linkage = "subject"),
        act_revision = act_channel(
            source = "pmsi_actes",
            selector = ccam("LAVA001", match = "exact"),
            linkage = "subject")))

sc_ssi_var <- function(..., output_one_row_per = "PATID") {
    variable_spec(
        name = "ssi_6mo_post_surgery",
        concept = sc_ssi_concept,
        output_one_row_per = output_one_row_per,
        anchor = "anchor_date",
        window = c(0, 180),
        channels = c("text_ssi", "cim10_ssi", "act_revision"),   # plain activations
        combine_channels = "text_ssi & (cim10_ssi | act_revision)",
        output = bin_output(),
        ...)
}

test_that("stay-level combine: same-stay co-occurrence, exists-lifted to patient", {
    run <- run_variable(sc_ssi_var(combine_at_level = "EVTID"),
                        sc_tasks, sc_sources,
                        caller = sc_ssi_fake, model_name = "fake")
    value <- setNames(run$values$value, run$values$task_id)

    expect_equal(value[["P1::t"]], 0L)   # THE TRAP: text in S1A, act in S1B
    expect_equal(value[["P2::t"]], 1L)   # text + act in the SAME stay S2A
    expect_equal(value[["P3::t"]], 1L)   # text + cim10 in the same stay (| arm)
    expect_equal(value[["P4::t"]], 0L)   # structured-only stay; text required
    expect_equal(value[["P5::t"]], 0L)   # text-only stay

    # Stay-level audit: P1's two observed stays, neither qualifying.
    ck <- run$combine_keys
    expect_setequal(ck$EVTID[ck$task_id == "P1::t"], c("S1A", "S1B"))
    expect_false(any(ck$qualifies[ck$task_id == "P1::t"]))
    expect_true(ck$qualifies[ck$task_id == "P2::t" & ck$EVTID == "S2A"])
    # Executed provenance records the evaluation level.
    expect_equal(run$provenance$combine_at_level, "EVTID")
})

# The same spec WITHOUT combine_at_level is today's shipped semantics: the trap
# patient scores 1 (a text hit and an act ANYWHERE in the window). This is the
# discriminator that makes the axis real -- and it must not drift.
test_that("default level (= output grain) keeps patient-level semantics", {
    run <- run_variable(sc_ssi_var(), sc_tasks, sc_sources,
                        caller = sc_ssi_fake, model_name = "fake")
    value <- setNames(run$values$value, run$values$task_id)
    expect_equal(value[["P1::t"]], 1L)   # cross-stay & passes at patient level
    expect_equal(value[["P4::t"]], 0L)
})

# --- Consumer B: mean Hb in anaemic stays (§14.9, gated payload at stay level) --

sc_an_tasks <- tibble::tibble(
    task_id = c("P1::t", "P2::t"),
    PATID = c("P1", "P2"),
    anchor_date = as.Date("2024-06-01"))

sc_biol <- tibble::tibble(
    source_row_id = paste0("b", 1:5),
    PATID   = c("P1", "P1", "P1", "P1", "P2"),
    EVTID   = c("SA", "SA", "SA", "SB", "SC"),
    ELTID   = paste0("BL", 1:5),
    BIOL_ID = paste0("B", 1:5),
    DATEXAM = as.Date(c("2024-05-01", "2024-05-02", "2024-05-03",
                        "2024-05-10", "2024-05-05")),
    analyte = "HGB",
    value   = c(9, 10, 13, 8, 13),
    # SA: two sub-threshold + one normal; SB: sub-threshold but NO anemia doc;
    # SC (P2): anemia doc but nothing sub-threshold -> gate fails.
    value_raw = as.character(c(9, 10, 13, 8, 13)))

sc_an_docs_index <- tibble::tibble(
    ELTID   = c("A1", "A2"),
    PATID   = c("P1", "P2"),
    EVTID   = c("SA", "SC"),
    RECDATE = as.Date(c("2024-05-02", "2024-05-05")),
    RECTYPE = "note")
sc_an_corpus <- sc_make_corpus(
    c("A1", "A2"),
    c("Anemie normocytaire connue, bien toleree.",
      "Anemie evoquee cliniquement ce jour."))

sc_an_sources <- list(
    biology   = sc_biol,
    documents = list(corpus = sc_an_corpus, docs_index = sc_an_docs_index))

sc_an_fake <- function(prompt, type, system_prompt) {
    if (grepl("nemie", prompt)) {
        return(list(anemia_status = "documented", evidence_ids = list("S001")))
    }
    list(anemia_status = "not_documented", evidence_ids = list())
}

sc_anemia_concept <- concept_spec(
    name = "anemia",
    channels = list(
        text_anemia = text_channel(
            source = "documents",
            selector = lucene_query("anemie"),
            extractor = binary_presence_text_definition(
                name = "anemia_text", status_key = "anemia_status",
                field = "anemia_mention",
                system_prompt = paste(
                    "Identify only explicitly documented anaemia.",
                    "Do not infer absence from silence.")),
            linkage = "subject"),
        hb_low = lab_channel(
            source = "biology",
            selector = analyte_value("HGB", lt = 12))))  # the concept's lab
                                                         # definition of anaemia

# hb_all is not a concept channel: this variable declares it INLINE in its
# channels list (the ratified §14.9 shape -- a payload channel one variable
# wants, promoted to the concept only when a second variable needs it). Only
# the payload channel is exempt from the dead-weight rule, so the channel list
# follows the payload pick; the others are plain string activations.
sc_anemia_var <- function(values_from) {
    channels <- list("text_anemia", "hb_low")
    if (identical(values_from, "hb_all")) {
        channels$hb_all <- lab_channel(source = "biology",
                                       selector = analyte("HGB"))
    }
    variable_spec(
        name = "mean_hb_anemic_stays",
        concept = sc_anemia_concept,
        output_one_row_per = "PATID",
        anchor = "anchor_date",
        window = c(-365, 0),
        channels = channels,
        combine_channels = "text_anemia & hb_low",
        combine_at_level = "EVTID",
        output = num_output(values_from = values_from, reduce = mean))
}

test_that("gated payload reads only the qualifying stays' rows (values_from key-scoped)", {
    run <- run_variable(sc_anemia_var(values_from = "hb_all"),
                        sc_an_tasks, sc_an_sources,
                        caller = sc_an_fake, model_name = "fake")
    value <- setNames(run$values$value, run$values$task_id)
    n_rows <- setNames(run$values$n_payload_rows, run$values$task_id)

    # P1: SA qualifies (doc + sub-threshold Hb); SB does NOT (no doc). hb_all is
    # scoped to qualifying stays: mean(9, 10, 13) -- SB's 8 is OUT, SA's normal
    # 13 is IN (unthresholded payload channel, key-scoped, §14.9).
    expect_equal(value[["P1::t"]], mean(c(9, 10, 13)))
    expect_equal(n_rows[["P1::t"]], 3L)
    # P2: anemia documented but no sub-threshold measurement -> no qualifying
    # stay -> gate fails -> NA (not a mean over unqualified rows).
    expect_true(is.na(value[["P2::t"]]))
    expect_equal(n_rows[["P2::t"]], 0L)
})

test_that("swapping the payload channel changes which values enter the mean", {
    run <- run_variable(sc_anemia_var(values_from = "hb_low"),
                        sc_an_tasks, sc_an_sources,
                        caller = sc_an_fake, model_name = "fake")
    value <- setNames(run$values$value, run$values$task_id)
    expect_equal(value[["P1::t"]], mean(c(9, 10)))   # only sub-threshold rows
})

# --- Build-time guards ----------------------------------------------------------

test_that("combine_at_level is validated at build time", {
    # Needs a combine expression: a single channel's rows are already the
    # surviving set; there is no algebra to evaluate at a level.
    expect_error(
        variable_spec(
            name = "no_expr", concept = sc_ssi_concept,
            output_one_row_per = "PATID",
            channels = list(act_revision = use_channel()),
            output = bin_output(),
            combine_at_level = "EVTID"),
        "combine expression")
    # Coarser than the output grain would leak hits across output rows.
    expect_error(
        sc_ssi_var(combine_at_level = "PATID",
                   output_one_row_per = "EVTID"),
        "finer")
    # The level must be an identity-spine key.
    expect_error(sc_ssi_var(combine_at_level = "WARD"), "spine")
})
