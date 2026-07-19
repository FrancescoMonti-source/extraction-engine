lab_fixture <- function() {
    tibble::tibble(
        PATID = "P1",
        EVTID = c("E1", "E1", "E2", "E2", "E3"),
        ELTID = paste0("L", 1:5),
        biol_ID = paste0("B", 1:5),
        DATEXAM = as.Date("2026-01-01") + 0:4,
        TYPEANA = c("K.K", "K.K", "K.K", "ONE", "EMPTY"),
        NUMRES = c(4.2, NA, 5.1, 2, NA),
        STRRES = c(NA, "negatif", "legacy-code", NA, NA))
}

lab_variable <- function(code, column, reduce = NULL) {
    concept <- concept_spec(
        paste("lab", code),
        channels = list(result = lab_channel(selector = analyte(code))))
    variable_spec(
        name = paste(code, column, sep = "_"),
        concept = concept,
        channels = list(result = use_channel(channel = "result")),
        output = from_channel(
            "result", column = column, group_by = "PATID", reduce = reduce))
}

test_that("one lab concept publishes real columns without result-lane inference", {
    biology <- lab_fixture()
    cohort <- tibble::tibble(PATID = "P1")

    numeric_run <- run_variable(
        lab_variable("K.K", "NUMRES", max), cohort,
        sources = list(biology = biology))
    character_run <- run_variable(
        lab_variable("K.K", "STRRES", function(x) paste(x, collapse = "|")), cohort,
        sources = list(biology = biology))
    date_run <- run_variable(
        lab_variable("K.K", "DATEXAM", max), cohort,
        sources = list(biology = biology))
    direct_run <- run_variable(
        lab_variable("ONE", "NUMRES"), cohort,
        sources = list(biology = biology))
    empty_run <- run_variable(
        lab_variable("EMPTY", "NUMRES"), cohort,
        sources = list(biology = biology))

    expect_identical(numeric_run$values$value, 5.1)
    expect_identical(character_run$values$value, "negatif|legacy-code")
    expect_s3_class(date_run$values$value, "POSIXct")
    expect_identical(
        date_run$values$value,
        as.POSIXct("2026-01-03", tz = "Europe/Paris"))
    expect_identical(direct_run$values$value, 2)
    expect_identical(empty_run$values$value, NA_real_)

    # A dual-result row is ordinary evidence. Reading NUMRES does not erase the
    # qualitative row, nor does it make the source ambiguous.
    expect_equal(nrow(numeric_run$evidence), 3L)
    expect_true(any(
        is.na(numeric_run$evidence$NUMRES) &
            numeric_run$evidence$STRRES == "negatif"))
    expect_true(any(
        !is.na(numeric_run$evidence$NUMRES) &
            numeric_run$evidence$STRRES == "legacy-code"))
    expect_identical(
        names(numeric_run),
        c("values", "channel_status", "evidence", "audit"))
    expect_true("evidence_ref" %in% names(numeric_run$evidence))
    expect_false(any(c("source_row_id", "hit_ref") %in%
                     names(numeric_run$evidence)))
    expect_identical(unique(numeric_run$evidence$source_EVTID), c("E1", "E2"))

    expect_error(
        run_variable(
            lab_variable("K.K", "NUMRES"), cohort,
            sources = list(biology = biology)),
        "found 2 non-missing values")
})

test_that("aliases, activation filters, combine keys, and restriction keys stay distinct", {
    biology <- tibble::tibble(
        PATID = "P1",
        EVTID = c("E1", "E1", "E1", "E2", "E2", "E2"),
        ELTID = paste0("L", 1:6),
        biol_ID = paste0("B", 1:6),
        DATEXAM = as.Date("2026-02-01") + c(0, 1, 1, 2, 3, 5),
        TYPEANA = c("HB.HB", "HB.HB", "OTHER", "HB.HB", "HB.HB", "HB.HB"),
        NUMRES = c(9, 10, 99, 14, 16, 7),
        STRRES = NA_character_)
    hemoglobin <- concept_spec(
        "hemoglobin",
        channels = list(hb = lab_channel(selector = analyte("HB.HB"))))
    make_variable <- function(filter_by) variable_spec(
        name = paste0("mean_hb_filtered_by_", filter_by),
        concept = hemoglobin,
        anchor = "anchor_date",
        channels = list(
            hb_gate = use_channel(
                channel = "hb",
                window = c(-Inf, 0)),
            hb_low = use_channel(
                channel = "hb",
                filter_rows = function(NUMRES) NUMRES < 12,
                window = c(-Inf, 0)),
            hb_payload = use_channel(
                channel = "hb",
                window = c(-Inf, 0))),
        combine = combine_channels("hb_gate & hb_low", by = "EVTID"),
        output = from_channel(
            "hb_payload", column = "NUMRES",
            filter_by_qualified = filter_by,
            group_by = "PATID", reduce = mean))

    patient_cohort <- tibble::tibble(
        PATID = c("P1", "P1"),
        EVTID = c("E1", "E2"),
        task_id = c("caller-E1", "caller-E2"),
        anchor_date = as.Date("2026-02-05"))

    protocol_specs <- list(make_variable("EVTID"), make_variable("PATID"))
    protocol_names <- vapply(protocol_specs, `[[`, character(1), "name")
    protocol_run <- run_protocol(
        protocol_specs,
        cohort = patient_cohort,
        sources = list(biology = biology))
    expect_identical(
        names(protocol_run),
        c("mean_hb_filtered_by_EVTID", "mean_hb_filtered_by_PATID"))
    expect_identical(
        names(run_protocol(
            stats::setNames(protocol_specs, protocol_names),
            cohort = patient_cohort,
            sources = list(biology = biology))),
        protocol_names)
    event_restricted <- protocol_run$mean_hb_filtered_by_EVTID
    patient_restricted <- protocol_run$mean_hb_filtered_by_PATID

    expect_identical(event_restricted$values$value, 9.5)
    expect_identical(patient_restricted$values$value, 12.25)
    expect_identical(
        event_restricted$audit$combine_keys$EVTID[
            event_restricted$audit$combine_keys$qualifies],
        "E1")
    expect_identical(
        unname(vapply(event_restricted$audit$execution_manifest$channels,
                      `[[`, character(1), "origin_name")),
        c("hb", "hb", "hb"))
    expect_true(any(event_restricted$evidence$channel == "hb_payload"))
    hb_low_counts <- event_restricted$audit$counts |>
        dplyr::filter(channel == "hb_low") |>
        dplyr::select(stage, n)
    expect_identical(
        hb_low_counts,
        tibble::tibble(
            stage = c("task_join", "window", "selector", "filter_rows"),
            n = c(6L, 5L, 4L, 2L)))
    expect_identical(
        event_restricted$audit$counts$n[
            event_restricted$audit$counts$channel == "hb_payload" &
                event_restricted$audit$counts$stage == "output_input"],
        2L)
    expect_identical(
        patient_restricted$audit$counts$n[
            patient_restricted$audit$counts$channel == "hb_payload" &
                patient_restricted$audit$counts$stage == "output_input"],
        4L)
    expect_false(any(c("membership", "channel_results", "combine_keys") %in%
                     names(event_restricted)))

    broadcast <- variable_spec(
        name = "hb_patient_gate_broadcast_to_events",
        concept = hemoglobin,
        anchor = "anchor_date",
        channels = list(
            hb_gate = use_channel(
                channel = "hb",
                window = c(-Inf, 0)),
            hb_low = use_channel(
                channel = "hb",
                filter_rows = function(NUMRES) NUMRES < 12,
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

    expect_identical(broadcast_run$values$value, c(1L, 1L, 0L))
    expect_identical(
        broadcast_run$audit$combine_keys,
        tibble::tibble(
            PATID = c("P1", "P2"),
            hb_gate = c(TRUE, FALSE),
            hb_low = c(TRUE, FALSE),
            qualifies = c(TRUE, FALSE)))
})

test_that("native TypeObject yields a stable multi-column LLM frame and evidence", {
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
    make_variable <- function(rationale = TRUE) variable_spec(
        name = if (isFALSE(rationale)) "tabagisme_sans_rationale" else "tabagisme",
        concept = smoking,
        channels = list(text_tabagisme = use_channel(
            channel = "text",
            search_within = "PATID",
            method = "lucene_llm",
            model = "declared-test-model",
            model_params = list(temperature = 0, seed = 42),
            response = response,
            rationale = rationale)),
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
    testthat::local_mocked_bindings(
        .chat_metadata = function(chat) list(
            provider = "test", model = "fake", params = list(),
            temperature = 0, seed = 1L, max_tokens = 100),
        .require_gated_chat = function(metadata) invisible(TRUE),
        .call_chat = function(chat, prompt, type, system_prompt, metadata) {
            seen$types[[length(seen$types) + 1L]] <- type
            fields <- names(S7::props(type)$properties)
            result <- list(
                statut_tabagique = "fumeur",
                temporalite = "actuel",
                evidence_ids = "S001")
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
    run_without_rationale <- run_variable(
        make_variable(FALSE), cohort,
        sources = list(documents = documents), chat = structure(list(), class = "fake"))

    expect_identical(run$values$statut_tabagique, c("fumeur", NA_character_))
    expect_identical(run$values$temporalite, c("actuel", NA_character_))
    expect_identical(
        run$values$rationale,
        c("Le texte documente un tabagisme actif.", NA_character_))
    expect_identical(run$values$channel_coverage, c("complete", "partial"))
    expect_false("evidence_ids" %in% names(run$values))
    expect_identical(run$evidence$EVTID, "TARGET1")
    expect_identical(run$evidence$source_EVTID, "SOURCE_STAY")
    expect_identical(run$evidence$evidence_ref, "H001")
    expect_identical(run$evidence$snippet_id, "S001")
    expect_false(any(c("source_row_id", "hit_ref") %in% names(run$evidence)))
    expect_identical(
        run$audit$execution_manifest$channels$text_tabagisme$declared_model,
        "declared-test-model")
    expect_identical(run$audit$llm_calls$model, "fake")
    expect_true("hit_ref" %in%
                names(run$audit$internal$channel_intermediates$
                      text_tabagisme$candidates))
    expect_identical(
        run$audit$counts$n[
            run$audit$counts$channel == "text_tabagisme" &
                run$audit$counts$stage == "model_input"],
        c(1L, 0L))
    expect_false("model" %in% names(formals(variable_spec)))
    expect_true("model" %in% names(formals(use_channel)))

    default_properties <- S7::props(seen$types[[1]])$properties
    expect_setequal(
        names(default_properties),
        c("statut_tabagique", "temporalite", "rationale", "evidence_ids"))
    expect_identical(
        S7::props(default_properties$rationale)$description,
        paste(
            "Justification brève du choix, fondée uniquement sur les extraits",
            "et sans ajouter d'information non documentée."))
    evidence_enum <- S7::props(default_properties$evidence_ids)$items
    expect_identical(S7::props(evidence_enum)$values, "S001")
    expect_false("rationale" %in% names(run_without_rationale$values))
    expect_false(
        "rationale" %in% names(S7::props(seen$types[[2]])$properties))

    expect_error(
        variable_spec(
            name = "llm_membership_is_not_implicit",
            concept = smoking,
            channels = list(
                text_llm = use_channel(
                    channel = "text",
                    search_within = "PATID",
                    method = "lucene_llm",
                    response = response,
                    rationale = FALSE),
                text_lucene = use_channel(
                    channel = "text",
                    search_within = "PATID",
                    method = "lucene")),
            combine = combine_channels(
                "text_llm & text_lucene", by = "PATID"),
            output = bin_output(group_by = "PATID")),
        "cannot currently use lucene_llm activation\\(s\\): text_llm")
})
