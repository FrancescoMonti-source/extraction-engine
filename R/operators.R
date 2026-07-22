# =============================================================================
# operators.R -- experimental operators / helpers
# -----------------------------------------------------------------------------
# Generic reusable computational pieces used INSIDE a variable_spec or template:
# windows, reducers, combiners, output types, and extraction methods. These are
# operators/helpers, NOT variable templates (a variable template is
# concept-specific; these are not). Each is a thin tagged record the runner reads
# by class/kind.
# =============================================================================

# --- relative windows ---------------------------------------------------------
# The ratified spelling is a plain vector on each use_channel() activation:
# window = c(from_days, to_days) relative to the variable anchor (0 = the anchor
# day; negative = lookback;
# c(-Inf, 0) = unbounded lookback; NULL = no window at all). The old ctors
# (days_after / before_anchor) were wrapper-razor casualties (DESIGN invariant
# 33): they interpreted nothing the two numbers do not already say. use_channel()
# normalizes the vector into the internal ee_window record the runner reads.

# --- derived anchors ----------------------------------------------------------
# An anchor may be a cohort COLUMN (anchor = "inclusion_date", one date supplied
# per output unit)
# or DERIVED from an event. index_event() is the GENERIC derived anchor -- DESIGN §14's
# transplant_date()/surgery_date() are domain-specific forms of it: per subject, find the
# event in `source` whose `code` matches `selector`, and anchor at its `at` date
# COLUMN. `at` names the source's own column (e.g. "DATEACTE", "DATENT", "DATSORT")
# -- owner ruling 2026-07-07: role vocabulary is indirection the engine never
# interprets here, and raw names are self-documenting; the registry's roles stay
# internal where the engine does interpret them. Omitted, `at` defaults to the
# source's windowing clock (its registered source_time_start). run_variable
# resolves it in an anchor PASS -- producing (PATID, anchor_date) before
# windowing, NOT an inter-channel dependency.
#
# `select_event` is the researcher's rule for a subject with SEVERAL matching
# events (DESIGN §7 / invariant 35): a plain closure over the subject's matched
# rows (columns PATID, EVTID, and the `at` date column, e.g. DATEACTE), returning
# the row(s) that anchor the clock -- e.g. \(d) dplyr::slice_min(d, DATEACTE,
# n = 1) for "the first surgery", or identity for "every surgery starts its own
# clock" (one task per selected event; output$group_by must then be the event key).
# It may filter or reorder only those matched rows; changing an EVTID/date pair is
# not selection. Without it, multiple matches stay a loud error: the engine never
# picks.
index_event <- function(source, selector, at = NULL,
                        select_event = NULL) {
    if (!is.character(source) || length(source) != 1L || !nzchar(source)) {
        stop("index_event() needs one source name.", call. = FALSE)
    }
    if (!inherits(selector, "ee_selector") ||
        !identical(selector$kind, "code")) {
        stop("index_event() needs a code selector created with icd10() or ccam().",
             call. = FALSE)
    }
    if (!is.null(at) &&
        (!is.character(at) || length(at) != 1L || !nzchar(at))) {
        stop("index_event() `at` must be one date column name of the source ",
             "(e.g. \"DATEACTE\", \"DATENT\") or NULL (the source's windowing ",
             "clock).", call. = FALSE)
    }
    if (!is.null(select_event) && !is.function(select_event)) {
        stop("index_event() select_event must be a plain function over the ",
             "subject's matched event rows (or NULL: single match required).",
             call. = FALSE)
    }
    .new_spec(list(source = source, selector = selector, at = at,
                            select_event = select_event),
                       "ee_index_event")
}

# --- payload reduction ---------------------------------------------------------
# Reduction lives on from_channel(), not the activation. It collapses the selected
# real source column with a plain values -> scalar function; no bespoke operator
# wraps trivial base reductions or invents tie-breaks.

# --- cross-channel combiner ---------------------------------------------------
# The ONLY cross-channel combine is hit-set algebra. A single channel has no
# hit-algebra, so it carries combine = NULL and its value is shaped by output (a
# channel payload or membership). There is no separate reconciliation combiner:
# single-channel assembly is reached with from_channel().
#
# The expression and the identity level where its signals must coexist form one
# contract:
#   combine = combine_channels(
#       "(transplant_act | transplant_status) & !dialysis_signal",
#       by = "EVTID"
#   )
# Channel-name symbols + the operators | (union) & (intersection) ! (complement)
# + parentheses; nothing else. Parsed + grammar-checked at construction; channel
# symbols are checked against the variable's activated channels at variable_spec
# build. The decision is OBSERVED hit-set algebra (a task is a member of a channel's
# set iff hit == TRUE; FALSE and NA both mean "no observed hit"), so it is always
# determined (included / excluded) -- an unavailable channel is reported via
# channel_coverage, not propagated into the decision. The per-channel audit keeps the
# raw TRUE/FALSE/NA. The pure parser/evaluator/overlap live in R/hitset.R.
combine_channels <- function(expr, by) {
    if (!is.character(expr) || length(expr) != 1L || is.na(expr) ||
        !nzchar(trimws(expr))) {
        stop("combine_channels() expr must be one non-empty boolean expression.",
             call. = FALSE)
    }
    if (!is.character(by) || length(by) != 1L || is.na(by) ||
        !by %in% c("PATID", "EVTID", "ELTID")) {
        stop("combine_channels() by must be PATID, EVTID, or ELTID.",
             call. = FALSE)
    }
    ast <- .parse_hitset_expr(expr)
    channels <- .check_hitset_grammar(ast)
    if (!length(channels)) {
        stop("A hit-set expression must reference >=1 channel.", call. = FALSE)
    }
    .new_spec(
        list(kind = "hit_set_expr", expr = expr, ast = ast, channels = channels,
             by = by),
        "ee_combiner")
}

# --- output contract ----------------------------------------------------------
# Membership is the one output that does not publish a channel payload. Every
# payload output names its activation alias and, for deterministic channels, the
# real prepared-source column to publish. Reduction is deliberately an ordinary
# values -> scalar function supplied by the study author.

.check_output_group_by <- function(group_by, what) {
    if (!is.character(group_by) || length(group_by) != 1L || is.na(group_by) ||
        !group_by %in% c("PATID", "EVTID", "ELTID")) {
        stop(what, " group_by must be PATID, EVTID, or ELTID.", call. = FALSE)
    }
    group_by
}

bin_output <- function(group_by) {
    group_by <- .check_output_group_by(group_by, "bin_output()")
    .new_spec(list(kind = "binary", group_by = group_by), "ee_output_type")
}

DEFAULT_RATIONALE_DESCRIPTION <- paste(
    "Justification br\u00e8ve du choix, fond\u00e9e uniquement sur les extraits",
    "et sans ajouter d'information non document\u00e9e.")

from_channel <- function(channel, column = NULL, filter_by_qualified = NULL,
                         group_by, reduce = NULL) {
    if (!is.character(channel) || length(channel) != 1L || is.na(channel) ||
        !nzchar(channel)) {
        stop("from_channel() channel must be one activation alias.", call. = FALSE)
    }
    if (!is.null(column) &&
        (!is.character(column) || length(column) != 1L || is.na(column) ||
         !nzchar(column))) {
        stop("from_channel() column must be one prepared-source column name or NULL.",
             call. = FALSE)
    }
    if (!is.null(reduce) && !is.function(reduce)) {
        stop("from_channel() reduce must be a function or NULL.", call. = FALSE)
    }
    if (!is.null(filter_by_qualified) &&
        (!is.character(filter_by_qualified) ||
         length(filter_by_qualified) != 1L ||
         is.na(filter_by_qualified) ||
         !filter_by_qualified %in% c("PATID", "EVTID", "ELTID"))) {
        stop("from_channel() filter_by_qualified must be PATID, EVTID, ",
             "ELTID, or NULL.", call. = FALSE)
    }
    group_by <- .check_output_group_by(group_by, "from_channel()")
    .new_spec(
        list(kind = "from_channel", channel = channel, column = column,
             filter_by_qualified = filter_by_qualified,
             group_by = group_by, reduce = reduce),
        "ee_output_type")
}
