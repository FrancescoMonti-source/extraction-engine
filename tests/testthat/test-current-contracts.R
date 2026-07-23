lab_fixture <- function() {
    tibble::tibble(
        PATID = "P1",
        EVTID = c("E1", "E1", "E2", "E2", "E3"),
        ELTID = paste0("L", 1:5),
        BIOL_ID = paste0("B", 1:5),
        DATEXAM = as.Date("2026-01-01") + 0:4,
        TYPEANA = c("K.K", "K.K", "K.K", "ONE", "EMPTY"),
        NUMRES = c(4.2, NA, 5.1, 2, NA),
        STRRES = c(NA, "negatif", "legacy-code", NA, NA),
        LOWER = c(3.5, 3.5, 3.5, 1, NA),
        UPPER = c(5, 5, 5, 3, NA),
        WEIGHT = c(1, 2, 3, 1, 1))
}

lab_variable <- function(code, value) {
    value <- rlang::enquo(value)
    concept <- concept_spec(
        paste("lab", code),
        channels = list(result = lab_channel(selector = analyte(code))))
    variable_spec(
        name = paste0(code, "_value"),
        channels = list(result = use_channel(
            channel = "result", concept = concept)),
        output = from_channel(
            "result", group_by = "PATID", value = !!value))
}

test_that("data-masked values preserve aligned source rows and one-cell output", {
    biology <- lab_fixture()
    cohort <- tibble::tibble(PATID = "P1")

    numeric_run <- run_variable(
        lab_variable("K.K", max(NUMRES, na.rm = TRUE)), cohort,
        sources = list(biology = dplyr::select(biology, -BIOL_ID)))
    character_run <- run_variable(
        lab_variable(
            "K.K", paste(STRRES[!is.na(STRRES)], collapse = "|")), cohort,
        sources = list(biology = biology))
    date_run <- run_variable(
        lab_variable("K.K", max(DATEXAM)), cohort,
        sources = list(biology = biology))
    empty_run <- run_variable(
        lab_variable("ABSENT", mean(NUMRES, na.rm = TRUE)), cohort,
        sources = list(biology = biology))
    weight_options <- list(remove_missing = TRUE)
    weighted_run <- run_variable(
        lab_variable(
            "K.K", stats::weighted.mean(
                NUMRES, WEIGHT, na.rm = weight_options$remove_missing)),
        cohort, sources = list(biology = biology))
    latest_class_run <- run_variable(
        lab_variable("K.K", {
            if (all(is.na(NUMRES))) {
                result <- NA_character_
            } else {
                i <- which.max(DATEXAM)
                result <- dplyr::case_when(
                    NUMRES[[i]] < LOWER[[i]] ~ "low",
                    NUMRES[[i]] > UPPER[[i]] ~ "high",
                    .default = "normal")
            }
            result
        }),
        cohort, sources = list(biology = biology))

    # Engine invariant: one data-masked expression sees complete, aligned source
    # columns. Missing values are handled explicitly by the author.
    expect_identical(
        list(
            numeric = numeric_run$values$value,
            character = character_run$values$value,
            date = date_run$values$value,
            weighted = weighted_run$values$value,
            latest_class = latest_class_run$values$value),
        list(
            numeric = 5.1,
            character = "negatif|legacy-code",
            date = as.POSIXct("2026-01-03", tz = "Europe/Paris"),
            weighted = 4.875,
            latest_class = "high"))

    # With no candidate rows the expression is not evaluated and the task gets
    # one stable missing cell. Multiple returned cells remain a loud error.
    expect_identical(empty_run$values$value, NA)

    # Channel status keeps row selection separate from model processing. A
    # deterministic channel never needs model processing, whether or not its
    # selector matched a candidate row.
    expect_identical(
        c(
            matched_selection = numeric_run$channel_status$selection_status,
            matched_processing = numeric_run$channel_status$processing_status,
            empty_selection = empty_run$channel_status$selection_status,
            empty_processing = empty_run$channel_status$processing_status),
        c(
            matched_selection = "matched",
            matched_processing = "not_required",
            empty_selection = "no_match",
            empty_processing = "not_required"))
    expect_length(
        intersect(
            c("status", "hit", "processing_state", "contribution", "error"),
            names(numeric_run$channel_status)),
        0L)
    expect_identical(
        intersect(
            c("call_status", "response_status", "transport_attempts",
              "attempt_status", "processing_status", "n_tries", "definition"),
            names(numeric_run$audit$llm_calls)),
        c("call_status", "response_status", "transport_attempts"))

    # Reading NUMRES does not erase sibling payload or rows with missing NUMRES.
    # The native BIOL_ID is optional for execution and preserved when supplied.
    expect_identical(
        numeric_run$evidence |>
            dplyr::arrange(evidence_ref) |>
            dplyr::select(source_EVTID, NUMRES, STRRES),
        tibble::tibble(
            source_EVTID = c("E1", "E1", "E2"),
            NUMRES = c(4.2, NA, 5.1),
            STRRES = c(NA, "negatif", "legacy-code")))
    expect_identical(character_run$evidence$BIOL_ID, paste0("B", 1:3))
    expect_identical(unique(numeric_run$evidence$evidence_kind), "source_row")
    expect_identical(
        intersect(c("evidence_ref", "source_row_id", "hit_ref"),
                  names(numeric_run$evidence)),
        "evidence_ref")

    expect_error(
        run_variable(
            lab_variable("K.K", NUMRES), cohort,
            sources = list(biology = biology)),
        "must return exactly one scalar or one list cell")

    # Data masks expose prepared-source columns only, and invalid references are
    # rejected even when the selector happens to produce no target row.
    absent_concept <- concept_spec(
        "absent lab",
        channels = list(result = lab_channel(selector = analyte("ABSENT"))))
    invalid_filter <- variable_spec(
        name = "invalid_filter",
        channels = list(result = use_channel(
            channel = "result",
            concept = absent_concept,
            filter_rows = {
                if (FALSE) conditional_name <- 1
                NUMREZ <- replace(NUMREZ, 1L, 0)
                task_id == "internal-task" | conditional_name > 0
            })),
        output = bin_output(group_by = "PATID"))
    expect_error(
        run_variable(
            invalid_filter, cohort,
            sources = list(biology = biology)),
        "missing prepared-source column.*NUMREZ, task_id, conditional_name")
    expect_error(
        run_variable(
            lab_variable("K.K", task_id[[1L]]), cohort,
            sources = list(biology = biology)),
        "missing prepared-source column.*task_id")
})

test_that("relational keys control qualification, evidence, and broadcast", {
    biology <- tibble::tibble(
        PATID = "P1",
        EVTID = c("E1", "E1", "E1", "E2", "E2", "E2"),
        ELTID = paste0("L", 1:6),
        BIOL_ID = paste0("B", 1:6),
        DATEXAM = as.Date("2026-02-01") + c(0, 1, 1, 2, 3, 5),
        TYPEANA = c("HB.HB", "HB.HB", "OTHER", "HB.HB", "HB.HB", "HB.HB"),
        NUMRES = c(9, 10, 99, 14, 16, 7),
        STRRES = NA_character_)
    hemoglobin <- concept_spec(
        "hemoglobin",
        channels = list(hb = lab_channel(selector = analyte("HB.HB"))))
    conflicting_hemoglobin <- concept_spec(
        "hemoglobin",
        channels = list(hb = lab_channel(selector = analyte("OTHER"))))
    origin_contract <- c(
        character_requires_concept = inherits(
            try(use_channel("hb"), silent = TRUE), "try-error"),
        inline_rejects_concept = inherits(
            try(
                use_channel(
                    lab_channel(selector = analyte("HB.HB")),
                    concept = hemoglobin),
                silent = TRUE),
            "try-error"),
        unknown_channel_is_local_to_concept = inherits(
            try(
                use_channel("not_in_hemoglobin", concept = hemoglobin),
                silent = TRUE),
            "try-error"),
        duplicate_name_rejects_different_catalog = inherits(
            try(
                variable_spec(
                    name = "ambiguous_catalog_identity",
                    channels = list(
                        first = use_channel("hb", concept = hemoglobin),
                        second = use_channel(
                            "hb", concept = conflicting_hemoglobin)),
                    combine = combine_channels("first & second", by = "PATID"),
                    output = bin_output(group_by = "PATID")),
                silent = TRUE),
            "try-error"))
    expect_identical(
        origin_contract,
        c(
            character_requires_concept = TRUE,
            inline_rejects_concept = TRUE,
            unknown_channel_is_local_to_concept = TRUE,
            duplicate_name_rejects_different_catalog = TRUE))

    make_variable <- function(filter_by) {
        low_threshold <- 12
        variable_spec(
            name = paste0("mean_hb_filtered_by_", filter_by),
            anchor = "anchor_date",
            channels = list(
                hb_low = use_channel(
                    channel = "hb",
                    concept = hemoglobin,
                    filter_rows = .data$NUMRES < .env$low_threshold,
                    window = c(-Inf, 0)),
                hb_group = use_channel(
                    channel = "hb",
                    concept = hemoglobin,
                    group_by = "EVTID",
                    filter_groups = mean(NUMRES, na.rm = TRUE) < 12,
                    window = c(-Inf, 0)),
                hb_payload = use_channel(
                    channel = "hb",
                    concept = hemoglobin,
                    window = c(-Inf, 0))),
            combine = combine_channels("hb_low & hb_group", by = "EVTID"),
            output = from_channel(
                "hb_payload", group_by = "PATID",
                value = mean(NUMRES, na.rm = TRUE),
                filter_by_qualified = filter_by))
    }

    patient_cohort <- tibble::tibble(
        PATID = c("P1", "P1"),
        EVTID = c("E1", "E2"),
        task_id = c("caller-E1", "caller-E2"),
        anchor_date = as.Date("2026-02-05"))

    protocol_specs <- list(make_variable("EVTID"), make_variable("PATID"))
    protocol_run <- run_protocol(
        protocol_specs,
        cohort = patient_cohort,
        sources = list(biology = biology))
    event_restricted <- protocol_run$mean_hb_filtered_by_EVTID
    patient_restricted <- protocol_run$mean_hb_filtered_by_PATID

    # Engine invariant: the qualified-row key, not an implicit aggregation,
    # determines which raw rows reach the terminal patient reducer.
    expect_identical(
        c(
            filter_by_EVTID = event_restricted$values$value,
            filter_by_PATID = patient_restricted$values$value),
        c(filter_by_EVTID = 9.5, filter_by_PATID = 12.25))
    expect_identical(
        event_restricted$audit$combine_keys$EVTID[
            event_restricted$audit$combine_keys$qualifies],
        "E1")
    # Audit stages describe one relational funnel instead of exposing helper
    # names. The window remains a separate stage between the pre-selector rows
    # and the selector itself.
    hb_low_counts <- event_restricted$audit$counts |>
        dplyr::filter(channel == "hb_low")
    expected_counts <- c(
        pre_selector = 6L, window = 5L, selector = 4L,
        filtered_selector = 2L)
    expect_identical(
        hb_low_counts$n[match(names(expected_counts), hb_low_counts$stage)],
        unname(expected_counts))
    expect_length(
        intersect(
            unique(event_restricted$audit$counts$stage),
            c("task_join", "filter_rows", "filter_groups")),
        0L)
    # Known regression: the payload evidence follows the qualifying rows while
    # gate evidence remains the complete observed signal.
    expect_identical(
        event_restricted$evidence |>
            dplyr::filter(channel == "hb_payload") |>
            dplyr::arrange(evidence_ref) |>
            dplyr::select(source_EVTID, NUMRES),
        tibble::tibble(
            source_EVTID = c("E1", "E1"),
            NUMRES = c(9, 10)))
    expect_identical(
        sort(event_restricted$evidence$source_EVTID[
            event_restricted$evidence$channel == "hb_group"]),
        c("E1", "E1"))

    broadcast <- variable_spec(
        name = "hb_patient_gate_broadcast_to_events",
        anchor = "anchor_date",
        channels = list(
            hb_gate = use_channel(
                channel = "hb",
                concept = hemoglobin,
                window = c(-Inf, 0)),
            hb_low = use_channel(
                channel = "hb",
                concept = hemoglobin,
                filter_rows = NUMRES < 12,
                window = c(-Inf, 0))),
        combine = combine_channels("hb_gate & hb_low", by = "PATID"),
        output = bin_output(group_by = "EVTID"))
    broadcast_run <- run_variable(
        broadcast,
        tibble::tibble(
            PATID = c("P1", "P1", "P2"),
            EVTID = c("E1", "E2", "E3"),
            anchor_date = as.Date("2026-02-05")),
        sources = list(biology = biology))

    # Coarse qualification broadcasts to declared descendant output units; the
    # public relation remains at the authored combine key.
    expect_identical(broadcast_run$values$value, c(1L, 1L, 0L))
    expect_identical(
        broadcast_run$audit$combine_keys |>
            dplyr::arrange(PATID),
        tibble::tibble(
            PATID = c("P1", "P2"),
            hb_gate = c(TRUE, FALSE),
            hb_low = c(TRUE, FALSE),
            qualifies = c(TRUE, FALSE)))

    # Identical text in two source documents is not duplicate relational
    # evidence: both native stay/document keys must survive real retrieval.
    documents <- data.frame(
        ELTID = c("D1", "D2"),
        RECTXT = c("Alpha marker.", "Alpha marker. Beta marker."),
        PATID = c("P1", "P1"),
        EVTID = c("E1", "E2"),
        RECDATE = as.Date(c("2026-01-01", "2026-01-02")),
        RECTYPE = c("CR", "CR"))
    corpus <- corpustools::create_tcorpus(
        documents,
        text_columns = "RECTXT", doc_column = "ELTID",
        split_sentences = TRUE, remember_spaces = FALSE, verbose = FALSE)
    alpha_signal <- concept_spec(
        "alpha_signal",
        channels = list(text = text_channel(lucene_query("alpha"))))
    beta_signal <- concept_spec(
        "beta_signal",
        channels = list(text = text_channel(lucene_query("beta"))))
    text_variable <- function(by) variable_spec(
        name = paste0("same_unit_text_intersection_", by),
        channels = list(
            alpha = use_channel(
                "text", concept = alpha_signal,
                search_within = "PATID", method = "lucene",
                filter_rows = !is.na(RECDATE)),
            beta = use_channel(
                "text", concept = beta_signal,
                search_within = "PATID", method = "lucene")),
        combine = combine_channels("alpha & beta", by = by),
        output = bin_output(group_by = "PATID"))

    text_runs <- run_protocol(
        list(text_variable("EVTID"), text_variable("ELTID")),
        cohort = tibble::tibble(PATID = "P1"),
        sources = list(documents = corpus))
    expect_identical(
        vapply(text_runs, function(run) run$values$value, integer(1)),
        c(same_unit_text_intersection_EVTID = 1L,
          same_unit_text_intersection_ELTID = 1L))
    event_text_run <- text_runs$same_unit_text_intersection_EVTID
    document_text_run <- text_runs$same_unit_text_intersection_ELTID
    expect_identical(
        c(
            EVTID = event_text_run$audit$combine_keys$EVTID[
                event_text_run$audit$combine_keys$qualifies],
            ELTID = document_text_run$audit$combine_keys$ELTID[
                document_text_run$audit$combine_keys$qualifies]),
        c(EVTID = "E2", ELTID = "D2"))
    expect_identical(
        sort(event_text_run$evidence$source_EVTID[
            event_text_run$evidence$channel == "alpha"]),
        c("E1", "E2"))
    expect_identical(
        unique(event_text_run$evidence$evidence_kind),
        "lucene_hit")
    # Each activation carries its own catalog origin. Different concepts may
    # reuse the same origin-channel name without creating a composite concept.
    expect_identical(
        lapply(
            event_text_run$audit$execution_manifest$channels,
            \(channel) channel[c("origin_concept", "origin_channel")]),
        list(
            alpha = list(
                origin_concept = "alpha_signal", origin_channel = "text"),
            beta = list(
                origin_concept = "beta_signal", origin_channel = "text")))

    # ELTID is source-local. Distinct selectors from the same document source
    # may combine at document level, but bare ELTID values never join sources.
    cross_source_variable <- variable_spec(
        name = "cross_source_ELTID_is_invalid",
        channels = list(
            alpha = use_channel(
                "text", concept = alpha_signal,
                search_within = "PATID", method = "lucene"),
            hb = use_channel("hb", concept = hemoglobin)),
        combine = combine_channels("alpha & hb", by = "ELTID"),
        output = bin_output(group_by = "PATID"))
    expect_error(
        resolve_variable_spec(cross_source_variable),
        "same source identity domain")

    cross_source_payload_variable <- variable_spec(
        name = "cross_source_ELTID_payload_is_invalid",
        channels = list(
            alpha = use_channel(
                "text", concept = alpha_signal,
                search_within = "PATID", method = "lucene"),
            beta = use_channel(
                "text", concept = beta_signal,
                search_within = "PATID", method = "lucene"),
            hb = use_channel("hb", concept = hemoglobin)),
        combine = combine_channels("alpha & beta", by = "ELTID"),
        output = from_channel(
            "hb", group_by = "PATID", value = mean(NUMRES, na.rm = TRUE),
            filter_by_qualified = "ELTID"))
    expect_error(
        resolve_variable_spec(cross_source_payload_variable),
        "cannot apply ELTID-qualified keys")

    # Trust-boundary invariant: select_event may select matched rows, but cannot
    # synthesize a crossed EVTID/date pair that rewrites the clinical clock.
    acts <- tibble::tibble(
        PATID = "P1",
        EVTID = c("A1", "A2"),
        ELTID = c("AD1", "AD2"),
        CODEACTE = c("ABCD001", "ABCD001"),
        DATEACTE = as.Date(c("2026-02-03", "2026-02-05")))
    crossed_anchor <- variable_spec(
        name = "crossed_index_event_is_invalid",
        anchor = index_event(
            "pmsi_actes", ccam("ABCD001"), at = "DATEACTE",
            select_event = function(d) {
                selected <- d[1, , drop = FALSE]
                selected$DATEACTE <- d$DATEACTE[[2]]
                selected
            }),
        channels = list(hb = use_channel(
            "hb", concept = hemoglobin, window = c(-Inf, 0))),
        output = from_channel(
            "hb", group_by = "PATID", value = max(NUMRES, na.rm = TRUE)))
    expect_error(
        run_variable(
            crossed_anchor,
            cohort = tibble::tibble(PATID = "P1"),
            sources = list(pmsi_actes = acts, biology = biology)),
        "only rows from the matched event set")
})

test_that("LLM boundary stays grounded, isolated, and fail closed", {
    new_engine_fields <- c(
        "selection_status", "evidence_kind", "call_status",
        "response_status", "transport_attempts")
    collision_rejected <- vapply(new_engine_fields, function(field) {
        authored <- do.call(
            ellmer::type_object,
            c(list("Invalid engine-owned response field."),
              stats::setNames(
                  list(ellmer::type_string("Must be rejected.")), field)))
        inherits(
            try(
                use_channel(
                    channel = text_channel(lucene_query("taba*")),
                    search_within = "PATID",
                    method = "lucene_llm", response = authored),
                silent = TRUE),
            "try-error")
    }, logical(1))
    expect_true(all(collision_rejected))

    response <- ellmer::type_object(
        "Extraction structurée du statut tabagique.",
        statut_tabagique = ellmer::type_enum(
            c("fumeur", "non_fumeur"),
            "Statut explicitement documenté; ne jamais déduire du silence."),
        temporalite = ellmer::type_string(
            "Temporalité explicitement documentée."))
    smoking <- concept_spec(
        "tabagisme",
        channels = list(text = text_channel(selector = lucene_query("taba*"))))
    make_variable <- function(max_candidates = NULL) variable_spec(
        name = "tabagisme",
        channels = list(text_tabagisme = use_channel(
            channel = "text",
            concept = smoking,
            search_within = "PATID",
            method = "lucene_llm",
            model = "declared-test-model",
            model_params = list(temperature = 0, seed = 42),
            response = response,
            max_candidates = max_candidates)),
        output = from_channel("text_tabagisme", group_by = "EVTID"))

    cohort <- tibble::tibble(
        PATID = c("P1", "P2"), EVTID = c("TARGET1", "TARGET2"))
    task_ids <- paste(cohort$PATID, cohort$EVTID, sep = "::")
    documents <- list(
        coverage = tibble::tibble(
            task_id = task_ids,
            PATID = cohort$PATID,
            EVTID = cohort$EVTID,
            coverage_state = c("candidate", "no_candidate")),
        candidates = tibble::tibble(
            task_id = task_ids[[1]], snippet_id = "S001", hit_ref = "H001",
            PATID = "P1", EVTID = "SOURCE_STAY", ELTID = "D001",
            snippet_text = "Tabagisme actif documenté.",
            hit_text = "Tabagisme actif", RECDATE = as.Date("2026-03-01"),
            RECTYPE = "CR"))

    seen <- new.env(parent = emptyenv())
    seen$types <- list()
    seen$evidence_ids <- "S001"
    seen$calls <- 0L
    testthat::local_mocked_bindings(
        .chat_metadata = function(chat) list(
            provider = "test", model = "fake", params = list(),
            temperature = 0, seed = 1L, max_tokens = 100),
        .require_gated_chat = function(metadata) invisible(TRUE),
        .call_chat = function(chat, prompt, type, system_prompt, metadata) {
            seen$calls <- seen$calls + 1L
            seen$types[[length(seen$types) + 1L]] <- type
            fields <- names(S7::props(type)$properties)
            result <- list(
                statut_tabagique = "fumeur",
                temporalite = "actuel",
                evidence_ids = seen$evidence_ids)
            if ("rationale" %in% fields) {
                result$rationale <- "Le texte documente un tabagisme actif."
            }
            list(
                status = "completed", result = result, error = NA_character_,
                n_tries = 1L, errors = character(), started_at = Sys.time(),
                latency_ms = 0, partial_response = NA_character_,
                output_tokens = 10, inferred_finish_reason = "stop")
        },
        .package = "extractionengine")

    run <- run_variable(
        make_variable(), cohort,
        sources = list(documents = documents), chat = structure(list(), class = "fake"))

    # Public-contract invariant: a candidate publishes the authored frame while
    # no-candidate remains typed missing and does not trigger a model call.
    expect_identical(
        run$values |>
            dplyr::select(
                statut_tabagique, temporalite, rationale, channel_coverage),
        tibble::tibble(
            statut_tabagique = c("fumeur", NA_character_),
            temporalite = c("actuel", NA_character_),
            rationale = c(
                "Le texte documente un tabagisme actif.", NA_character_),
            channel_coverage = c("complete", "partial")))
    expect_identical(seen$calls, 1L)
    expect_false("evidence_ids" %in% names(run$values))

    # Selection describes the Lucene boundary; processing describes the LLM
    # boundary. No candidate therefore means no_match + not_called, whereas a
    # grounded response means matched + completed.
    expect_identical(
        run$channel_status |>
            dplyr::select(selection_status, processing_status),
        tibble::tibble(
            selection_status = c("matched", "no_match"),
            processing_status = c("completed", "not_called")))
    expect_length(
        intersect(
            c("status", "hit", "processing_state", "contribution", "error"),
            names(run$channel_status)),
        0L)

    # Grounded evidence keeps target and native stay identities distinct while
    # exposing only the canonical public coordinate.
    expect_identical(
        run$evidence |>
            dplyr::select(
                EVTID, source_EVTID, evidence_ref, evidence_kind, snippet_id),
        tibble::tibble(
            EVTID = "TARGET1", source_EVTID = "SOURCE_STAY",
            evidence_ref = "H001", evidence_kind = "llm_citation",
            snippet_id = "S001"))
    expect_identical(
        intersect(c("evidence_ref", "source_row_id", "hit_ref"),
                  names(run$evidence)),
        "evidence_ref")
    expect_identical(
        c(
            declared = run$audit$execution_manifest$channels$
                text_tabagisme$declared_model,
            observed = run$audit$llm_calls$model),
        c(declared = "declared-test-model", observed = "fake"))
    expect_identical(
        intersect(
            c("call_status", "response_status", "transport_attempts",
              "attempt_status", "processing_status", "n_tries", "definition"),
            names(run$audit$llm_calls)),
        c("call_status", "response_status", "transport_attempts"))

    # Schema-boundary invariant: engine-owned fields are injected dynamically,
    # and the citation enum contains only prompt-visible IDs.
    default_properties <- S7::props(seen$types[[1]])$properties
    expect_setequal(
        names(default_properties),
        c("statut_tabagique", "temporalite", "rationale", "evidence_ids"))
    evidence_enum <- S7::props(default_properties$evidence_ids)$items
    expect_identical(S7::props(evidence_enum)$values, "S001")

    # Ratified citation policy: mixed citations keep the grounded value and only
    # materialize the supplied ID.
    seen$evidence_ids <- c("S001", "S999")
    mixed_citations <- run_variable(
        make_variable(), cohort,
        sources = list(documents = documents),
        chat = structure(list(), class = "fake"))
    expect_identical(
        list(
            value = mixed_citations$values$statut_tabagique[[1]],
            warning = mixed_citations$values$citation_warning[[1]],
            evidence = mixed_citations$evidence$snippet_id),
        list(value = "fumeur", warning = TRUE, evidence = "S001"))

    # Invented-only citations cannot publish a value or evidence and remain
    # explicitly reviewable rather than becoming a model transport error.
    seen$evidence_ids <- "S999"
    invented_only <- run_variable(
        make_variable(), cohort,
        sources = list(documents = documents),
        chat = structure(list(), class = "fake"))
    expect_identical(
        list(
            value = invented_only$values$statut_tabagique[[1]],
            coverage = invented_only$values$channel_coverage[[1]],
            needs_review = invented_only$values$needs_review[[1]],
            selection = invented_only$channel_status$selection_status[[1]],
            processing = invented_only$channel_status$processing_status[[1]],
            evidence_rows = nrow(invented_only$evidence)),
        list(
            value = NA_character_, coverage = "partial", needs_review = TRUE,
            selection = "matched", processing = "invalid",
            evidence_rows = 0L))

    # Empty citations exercise the distinct zero-ID path: invalid, not errored.
    seen$evidence_ids <- character()
    uncited <- run_variable(
        make_variable(), cohort,
        sources = list(documents = documents),
        chat = structure(list(), class = "fake"))
    expect_identical(
        list(
            value = uncited$values$statut_tabagique[[1]],
            needs_review = uncited$values$needs_review[[1]],
            task_validity = uncited$audit$llm_calls$task_validity[[1]],
            error = uncited$audit$llm_calls$error[[1]]),
        list(
            value = NA_character_, needs_review = TRUE,
            task_validity = "invalid", error = NA_character_))

    # Native occurrences remain distinct for relational algebra, but repeated
    # normalized hit text consumes only one bounded LLM prompt slot.
    crowded_documents <- documents
    crowded_documents$candidates <- dplyr::bind_rows(
        documents$candidates,
        dplyr::mutate(
            documents$candidates,
            snippet_id = "S002", hit_ref = "H002", ELTID = "D002"),
        dplyr::mutate(
            documents$candidates,
            snippet_id = "S003", hit_ref = "H003", ELTID = "D003",
            hit_text = "Sevrage tabagique",
            snippet_text = "Sevrage tabagique documenté."))
    crowded_documents$candidates$hit_text <- NULL
    seen$evidence_ids <- "S001"
    invisible(run_variable(
        make_variable(max_candidates = 2L), cohort,
        sources = list(documents = crowded_documents),
        chat = structure(list(), class = "fake")))
    prompt_type <- seen$types[[length(seen$types)]]
    prompt_evidence_enum <-
        S7::props(S7::props(prompt_type)$properties$evidence_ids)$items
    expect_identical(
        S7::props(prompt_evidence_enum)$values,
        c("S001", "S003"))

    # Pre-retrieved fixtures must describe a possible retrieval result. A task
    # cannot claim no candidate while still supplying positive candidate rows.
    contradictory_documents <- documents
    contradictory_documents$coverage$coverage_state[[1]] <- "no_candidate"
    expect_error(
        run_variable(
            make_variable(), cohort,
            sources = list(documents = contradictory_documents),
            chat = structure(list(), class = "fake")),
        "if and only if candidate rows exist")

    # Until hit_when exists, an LLM payload has no implicit membership semantics.
    expect_error(
        variable_spec(
            name = "llm_membership_is_not_implicit",
            channels = list(
                text_llm = use_channel(
                    channel = "text",
                    concept = smoking,
                    search_within = "PATID",
                    method = "lucene_llm",
                    response = response,
                    rationale = FALSE),
                text_lucene = use_channel(
                    channel = "text",
                    concept = smoking,
                    search_within = "PATID",
                    method = "lucene")),
            combine = combine_channels(
                "text_llm & text_lucene", by = "PATID"),
            output = bin_output(group_by = "PATID")),
        "cannot currently use lucene_llm activation\\(s\\): text_llm")
})
