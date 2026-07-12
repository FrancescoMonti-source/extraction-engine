chat_tasks <- tibble::tibble(
    grain_id = "CHAT1", PATID = "P1", anchor_date = as.Date("2025-01-15"))

chat_candidates <- tibble::tibble(
    grain_id = c("CHAT1", "CHAT1"),
    snippet_id = c("S001", "S002"),
    hit_ref = c("D1::1", "D2::1"),
    ELTID = c("D1", "D2"), EVTID = c("E1", "E1"), sentence = 1L,
    hit_text = c("DROP", "KEEP"), snippet_text = c("DROP", "KEEP"),
    RECDATE = as.Date("2025-01-10"), RECTYPE = "note")

chat_sources <- list(documents = list(
    coverage = tibble::tibble(grain_id = "CHAT1", coverage_state = "candidate"),
    candidates = chat_candidates))

chat_variable <- function() {
    concept <- smoking_concept_spec()
    variable_spec(
        name = "chat_contract", concept = concept,
        output_one_row_per = "PATID", anchor = "anchor_date",
        window = c(-30, 0),
        channels = list(text_smoking_mentions = use_channel(
            method = llm_after_lucene(
                function(rows) rows[rows$snippet_id == "S002", , drop = FALSE]),
            extractor = smoking_definition())),
        output = cat_output(SMOKING_STATUSES))
}

test_that("direct Chat injection is isolated and records params", {
    responder <- function(prompt, type, system_prompt) {
        if (!grepl("KEEP", prompt, fixed = TRUE) || grepl("DROP", prompt, fixed = TRUE)) {
            stop("candidate selector was not applied")
        }
        list(smoking_status = "actif", evidence_ids = list("S002"),
             decision_note = "selected evidence")
    }
    chat <- fake_chat(
        responder,
        params = list(temperature = 0.2, seed = 77L, max_tokens = 33L))
    before <- chat$get_turns(include_system_prompt = TRUE)

    run <- run_variable(chat_variable(), chat_tasks, chat_sources, chat = chat)

    expect_identical(chat$get_turns(include_system_prompt = TRUE), before)
    expect_equal(run$values$value, "actif")
    expect_equal(run$evidence$evidence_ref, "D2::1")
    attempt <- run$channel_results$text_smoking_mentions$attempts
    expect_equal(attempt$provider, "test")
    expect_equal(attempt$model, "fake")
    expect_equal(attempt$temperature, 0.2)
    expect_equal(attempt$seed, 77L)
    expect_equal(attempt$max_tokens, 33)
    expect_equal(
        run$channel_results$text_smoking_mentions$model_candidates$snippet_id,
        "S002")
    expect_equal(run$provenance$model_params$seed, 77L)
})

test_that("model errors retain truncation diagnostics", {
    chat <- fake_chat(function(...) {
        rlang::abort(
            "premature EOF", partial_response = "{\"smoking_status\":",
            output_tokens = 33, inferred_finish_reason = "length")
    }, params = list(temperature = 0, seed = 7L, max_tokens = 33L))

    run <- run_variable(chat_variable(), chat_tasks, chat_sources, chat = chat)
    attempt <- run$channel_results$text_smoking_mentions$attempts

    expect_equal(attempt$attempt_status, "error")
    expect_equal(attempt$output_tokens, 33)
    expect_equal(attempt$inferred_finish_reason, "length")
    expect_match(attempt$partial_response, "smoking_status", fixed = TRUE)
    expect_equal(run$channel_status$status, "error")
})
