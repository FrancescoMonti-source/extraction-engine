test_that("authoring constructors reject unread arguments", {
    selector <- icd10("^E1")

    expect_error(use_channel(prompt = "ignored"), "unused argument")
    expect_error(use_channel(method = 42), "llm_after_lucene")
    expect_equal(llm_after_lucene()$candidate_policy, "all")
    capped <- llm_after_lucene(max_candidates = 10)
    expect_equal(capped$max_candidates, 10L)
    expect_equal(nrow(capped$candidates(data.frame(x = 1:20))), 10L)
    expect_error(llm_after_lucene(max_candidates = 0), "positive integer")
    expect_error(
        llm_after_lucene(
            max_candidates = 10, select_candidates = identity),
        "either max_candidates or select_candidates")
    expect_error(
        code_channel("pmsi_diag", selector, prompt = "ignored"),
        "unused argument")
})

test_that("output constructors require unique explicit contracts", {
    # Authoring contract: duplicate/empty levels or fields cannot be interpreted
    # as a meaningful output schema later in execution.
    expect_error(cat_output(c("a", "a")), "unique non-empty levels")
    expect_error(struct_output(character()), "unique non-empty fields")
    expect_error(struct_output(c("field", "field")), "unique non-empty fields")
    expect_error(
        llm_task(
            "probe", "system", function(...) NULL, function(...) "prompt",
            function(...) NULL, summary_required = 1),
        "summary_required must be TRUE or FALSE")
})

test_that("one compiled spec drives inspection and retains combine level", {
    concept <- concept_spec("two signals", list(
        first = code_channel("pmsi_diag", icd10("^E10")),
        second = code_channel("pmsi_diag", icd10("^E11"))))
    build_variable <- function(level) {
        variable_spec(
            name = "combined", concept = concept,
            output_one_row_per = "PATID",
            channels = list(first = use_channel(), second = use_channel()),
            combine_channels = "first | second",
            combine_at_level = level,
            output = bin_output())
    }

    authored <- build_variable("EVTID")
    compiled <- resolve_variable_spec(authored)

    expect_equal(compiled$combine_at_level, "EVTID")
    expect_identical(inspect(authored), compiled)
    expect_false("activation" %in% names(compiled$channels$first))
    expect_false(exists("variable_template", mode = "function", inherits = TRUE))
})

test_that("a lab activation can add a row rule without repeating its analyte", {
    concept <- concept_spec("haemoglobin", list(
        hb = lab_channel("biology", analyte("HGB.GDL"))))
    rule <- function(value, PATSEX) value < ifelse(PATSEX == "F", 12, 13)
    variable <- variable_spec(
        "anaemia", concept,
        channels = list(hb = use_channel(keep_when = rule)),
        output = bin_output())

    compiled <- resolve_variable_spec(variable)
    expect_equal(compiled$channels$hb$selector$codes, "HGB.GDL")
    expect_identical(compiled$channels$hb$selector$keep_when, rule)
    expect_match(compiled$channels$hb$selector_source,
                 "activation keep_when", fixed = TRUE)
    expect_error(
        use_channel(selector = analyte("OTHER"), keep_when = rule),
        "either selector or keep_when")
})

test_that("authored concept and variable specs print as concise study definitions", {
    concept <- concept_spec("haemoglobin", list(
        hb = lab_channel("biology", analyte("HGB.GDL"))))
    variable <- variable_spec(
        "anaemia", concept,
        channels = list(hb = use_channel(
            keep_when = function(value, PATSEX) value < 12)),
        output = bin_output())

    concept_text <- paste(capture.output(print(concept)), collapse = "\n")
    variable_text <- paste(capture.output(print(variable)), collapse = "\n")
    expect_match(concept_text, "Concept: haemoglobin", fixed = TRUE)
    expect_match(concept_text, "analyte: HGB.GDL", fixed = TRUE)
    expect_match(variable_text, "Study variable: anaemia", fixed = TRUE)
    expect_match(variable_text, "Output: binary, one row per PATID", fixed = TRUE)
    expect_match(variable_text, "rule:", fixed = TRUE)
})

test_that("a text variable owns its model configuration", {
    definition <- binary_presence_text_definition(
        name = "mention", status_key = "mention_status", field = "mention",
        system_prompt = "Extract only documented mentions.")
    concept <- concept_spec("text mention", list(
        mentions = text_channel(
            "documents", lucene_query("term*"), extractor = definition,
            default_method = llm_after_lucene(), linkage = "event")))
    variable <- variable_spec(
        "mention_enum", concept,
        channels = list(mentions = use_channel()), output = bin_output(),
        model = "gemma3:4b",
        model_params = list(temperature = 0, seed = 42L))

    compiled <- resolve_variable_spec(variable)
    printed <- paste(capture.output(print(variable)), collapse = "\n")
    expect_equal(compiled$model, "gemma3:4b")
    expect_equal(compiled$model_params$seed, 42L)
    expect_match(printed, "Model: gemma3:4b", fixed = TRUE)
    expect_match(printed, "scope: same PATID + EVTID", fixed = TRUE)
    expect_match(printed, "candidates after Lucene: all matches",
                 fixed = TRUE)
    expect_match(printed, "llm task: mention", fixed = TRUE)
    expect_match(printed, "ellmer type:", fixed = TRUE)

    expect_error(
        variable_spec(
            "bad", concept, channels = list(mentions = use_channel()),
            output = bin_output(), model_params = list(seed = 1L)),
        "require model")
    expect_error(
        variable_spec(
            "bad", concept, channels = list(mentions = use_channel()),
            output = bin_output(), model = "gemma3:4b",
            model_params = list(1L)),
        "named list")

    structured <- concept_spec("codes", list(
        code = code_channel("pmsi_diag", icd10("^E1"))))
    expect_error(
        variable_spec(
            "dead model", structured, channels = list(code = use_channel()),
            output = bin_output(), model = "gemma3:4b"),
        "no effect")
})
