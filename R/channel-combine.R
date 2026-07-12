# =============================================================================
# channel-combine.R — per-channel reduction to the {status, hit, evidence} contract
# -----------------------------------------------------------------------------
# Reduces ONE selected channel's engine views (coverage / values / evidence) to a
# per-task {status, hit, evidence} triple consumed by the value assemblers in
# run_variable() -- the hit-set-expression evaluator (.hit_set_expr_variable) and the
# single-channel membership assembler (.single_membership_variable). It maps the
# engine's processing_state vocabulary (text OR structured) into a normalized
# {complete / unavailable / invalid / error} status plus a three-valued hit
# (TRUE / FALSE / NA).
#
# "source" is reserved for the warehouse/raw data source (e.g. pmsi_diag, documents,
# biology); a channel reads FROM a source but is not the source. The only raw-source
# field that survives here is the durable evidence row key (source_row_id), genuine
# warehouse metadata.
#
# (The original OR collapse combine_any_channel_hit() -- the open-world
# incomplete_value policy -- was removed once cross-channel combine became hit-set
# algebra: that value is always 0/1 with the uncertainty on channel_coverage, never
# an incomplete_value. The pre-spine diabetes orchestration helpers were likewise
# subsumed by run_variable(); OR resilience is exercised at the spine, see
# test-slice-diabetes-spec.R / test-slice-dialysis-spec.R.)
# =============================================================================

# Map an engine processing_state (text OR structured vocabulary) + the channel's
# accepted value into the {status, hit} the assemblers expect. These mappings are
# RECIPE decisions, surfaced deliberately rather than hidden:
#   - no_candidate                          -> caller-selected complete/unavailable
#   - no data for the subject at all        -> UNAVAILABLE (neither + nor -; partial)
#   - rows present but unusable             -> INVALID (not a negative)
#   - model/processing failure              -> ERROR
.channel_status_from_state <- function(
    processing_state,
    accepted_value,
    no_candidate_status = c("complete", "unavailable")) {
    no_candidate_status <- match.arg(no_candidate_status)
    hit_present <- identical(as.character(accepted_value), "present")
    switch(processing_state,
        measured             = list(status = "complete",    hit = hit_present),
        valid                = list(status = "complete",    hit = hit_present),
        no_candidate         = list(
            status = no_candidate_status,
            hit = if (identical(no_candidate_status, "complete")) FALSE else NA),
        invalid              = list(status = "invalid",     hit = NA),
        no_eligible_source   = list(status = "unavailable", hit = NA),
        no_eligible_document = list(status = "unavailable", hit = NA),
        not_called           = list(status = "unavailable", hit = NA),
        model_error          = list(status = "error",       hit = NA),
        processing_error     = list(status = "error",       hit = NA),
        list(status = "unavailable", hit = NA))
}

# Reduce one channel's full result (the engine's coverage/values/evidence views) to
# a per-task {status, hit, evidence} list keyed by task_id. `id_col` is the durable
# row key in that channel's evidence: source_row_id (structured) or hit_ref (text).
.reduce_channel_result <- function(
    res,
    task_ids,
    id_col,
    no_candidate_status = c("complete", "unavailable")) {
    no_candidate_status <- match.arg(no_candidate_status)
    cov <- res$coverage; val <- res$values; ev <- res$evidence
    # run_extraction returns COLUMN-LESS empty tibbles when no task produced a value
    # (e.g. every task no_candidate); guard so $task_id access on such a tibble does
    # not warn ("Unknown or uninitialised column"). Behaviour is unchanged.
    has_val <- nrow(val) > 0L && all(c("task_id", "accepted_value") %in% names(val))
    has_ev  <- nrow(ev) > 0L && "task_id" %in% names(ev)
    out <- vector("list", length(task_ids)); names(out) <- task_ids
    for (tid in task_ids) {
        state <- cov$processing_state[cov$task_id == tid]
        state <- if (length(state)) state[[1]] else "no_eligible_source"
        av <- if (has_val) val$accepted_value[val$task_id == tid] else character()
        av <- if (length(av)) av[[1]] else NA_character_
        sh <- .channel_status_from_state(
            state, av, no_candidate_status = no_candidate_status)
        tev <- if (has_ev) ev[ev$task_id == tid, , drop = FALSE] else ev[0, ]
        ids <- if (id_col %in% names(tev)) as.character(tev[[id_col]]) else character()
        out[[tid]] <- list(status = sh$status, hit = sh$hit,
                           evidence = tibble::tibble(source_row_id = unique(ids)))
    }
    out
}
