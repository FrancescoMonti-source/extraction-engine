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
# The ratified spelling is a plain vector on the variable: window = c(from_days,
# to_days) relative to the anchor (0 = the anchor day; negative = lookback;
# c(-Inf, 0) = unbounded lookback; NULL = no window at all). The old ctors
# (days_after / before_anchor) were wrapper-razor casualties (DESIGN invariant
# 33): they interpreted nothing the two numbers do not already say. variable_spec
# normalizes the vector into the internal ee_window record the runner reads.

# --- derived anchors ----------------------------------------------------------
# An anchor may be a task COLUMN (anchor = "inclusion_date", one date supplied per task)
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
# clock" (one task per selected event; output_one_row_per must then be the event
# key). Without it, multiple matches stay a loud error: the engine never picks.
index_event <- function(source, selector, at = NULL,
                        select_event = NULL) {
    if (!is.character(source) || length(source) != 1L || !nzchar(source)) {
        stop("index_event() needs one source name.", call. = FALSE)
    }
    if (!inherits(selector, "ee_selector")) {
        stop("index_event() needs a selector (e.g. icd10()/ccam()).", call. = FALSE)
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

# --- payload reduction ----------------------------------------------------------
# Reduction lives on the OUTPUT, not the activation (DESIGN §8, wired 2026-07-05):
# num_output(values_from =, reduce =) / cat_output(levels, values_from =, reduce =)
# collapse the surviving payload rows' values with a plain function values -> scalar.
# No bespoke operator wraps trivial base reductions (max/min/mean/length) and no
# engine tie-break exists for categorical payloads -- the researcher's closure IS
# the rule. use_channel(reducer =) is retired (rejected loudly in spec.R).

# --- cross-channel combiner ---------------------------------------------------
# The ONLY cross-channel combine is hit-set algebra (hit_set_expr); a single
# channel has no hit-algebra, so it carries combine = NULL and its value is shaped
# by output() (documented status, multi-field, numeric, or membership). There is no
# documented_status()/collect_fields() combiner: those were single-channel OUTPUT
# assembly mislabelled as combines, now reached via output = cat_output()/
# struct_output() with combine = NULL (see run_variable()'s output dispatch).
#
# any_positive() is sugar: at variable_spec() build it LOWERS to the raw hit-set
# expression "a | b | ..." over the activated channels (>=2). It is not a distinct
# evaluator -- it produces a hit_set_expr like any other boolean combine.
any_positive <- function() {
    .new_spec(list(kind = "any_positive"), "ee_combiner")
}

# String boolean hit-set expression -- the public boolean-combine surface:
#   combine = "(transplant_act | transplant_status) & !dialysis_signal"
# Channel-name symbols + the operators | (union) & (intersection) ! (complement)
# + parentheses; nothing else. Parsed + grammar-checked at construction; channel
# symbols are checked against the variable's activated channels at variable_spec
# build. The decision is OBSERVED hit-set algebra (a task is a member of a channel's
# set iff hit == TRUE; FALSE and NA both mean "no observed hit"), so it is always
# determined (included / excluded) -- an unavailable channel is reported via
# channel_coverage, not propagated into the decision. The per-channel audit keeps the
# raw TRUE/FALSE/NA. The pure parser/evaluator/overlap live in R/hitset.R. A bare
# string passed as `combine` is coerced to this operator, so callers write
# combine = "...".
hit_set_expr <- function(expr) {
    ast <- .parse_hitset_expr(expr)
    channels <- .check_hitset_grammar(ast)
    if (!length(channels)) {
        stop("A hit-set expression must reference >=1 channel.", call. = FALSE)
    }
    .new_spec(
        list(kind = "hit_set_expr", expr = expr, ast = ast, channels = channels),
        "ee_combiner")
}

# Backward-compatible sugar that LOWERS to a hit_set_expr. It is NOT a parallel
# boolean system: hit_set_difference(include = a, exclude = b) is exactly the string
# expression `a & !b` (with OR-within-role unions for multiple channels). The string
# expression DSL is the primary, documented surface; this just spares a caller the
# string for the common "include minus exclude" case.
hit_set_difference <- function(include, exclude = character()) {
    include <- as.character(include)
    exclude <- as.character(exclude)
    if (!length(include) || anyNA(include) || any(!nzchar(include))) {
        stop("hit_set_difference() needs >=1 non-empty include channel.",
             call. = FALSE)
    }
    if (length(exclude) && (anyNA(exclude) || any(!nzchar(exclude)))) {
        stop("hit_set_difference() exclude channels must be non-empty names.",
             call. = FALSE)
    }
    if (length(intersect(include, exclude))) {
        stop("A channel cannot be both an include and an exclude channel.",
             call. = FALSE)
    }
    grp <- function(chs) {
        if (length(chs) == 1L) chs else sprintf("(%s)", paste(chs, collapse = " | "))
    }
    expr <- if (length(exclude)) {
        sprintf("%s & !%s", grp(include), grp(exclude))
    } else {
        grp(include)
    }
    hit_set_expr(expr)
}

# --- text extraction methods --------------------------------------------------
# The common path is intentionally declarative: no arguments means every Lucene
# match. An optional maximum keeps the first N rows in the engine's deterministic
# candidate order. A custom selector remains available, but is named as such so a
# study author can see that it changes evidence selection.
llm_after_lucene <- function(max_candidates = NULL, select_candidates = NULL) {
    if (!is.null(max_candidates)) {
        if (!is.numeric(max_candidates) || length(max_candidates) != 1L ||
            is.na(max_candidates) || !is.finite(max_candidates) ||
            max_candidates < 1 || max_candidates != floor(max_candidates) ||
            max_candidates > .Machine$integer.max) {
            stop("llm_after_lucene() max_candidates must be one positive integer.",
                 call. = FALSE)
        }
        max_candidates <- as.integer(max_candidates)
    }
    if (!is.null(select_candidates) && !is.function(select_candidates)) {
        stop("llm_after_lucene() select_candidates must be a plain function.",
             call. = FALSE)
    }
    if (!is.null(max_candidates) && !is.null(select_candidates)) {
        stop("llm_after_lucene() takes either max_candidates or ",
             "select_candidates, not both.", call. = FALSE)
    }

    if (is.function(select_candidates)) {
        policy <- "custom"
        selector <- select_candidates
    } else if (!is.null(max_candidates)) {
        policy <- "first_n"
        selector <- function(rows) utils::head(rows, max_candidates)
    } else {
        policy <- "all"
        selector <- base::identity
    }
    .new_spec(
        list(kind = "llm_after_lucene", candidate_policy = policy,
             max_candidates = max_candidates, candidates = selector),
        "ee_extraction_method")
}

# --- output (cohort column) types ---------------------------------------------
# Constructor names are short: bin_output() / num_output() / cat_output() /
# struct_output(). Each is a thin tagged record; the internal $kind the runner
# dispatches on (binary/number/categorical/fields) is unchanged. num/cat carry the
# PAYLOAD spec (DESIGN §8): values_from = the channel whose surviving rows' values
# feed the reduction (defaults to the sole channel of a single-channel variable;
# required with a combine expression), reduce = the plain values -> scalar rule.
.check_payload_args <- function(what, values_from, reduce, reduce_required) {
    if (!is.null(values_from) &&
        (!is.character(values_from) || length(values_from) != 1L ||
         !nzchar(values_from))) {
        stop(what, " values_from must be one channel name.", call. = FALSE)
    }
    if (is.null(reduce)) {
        if (reduce_required) {
            stop(what, " requires reduce = <function values -> scalar> ",
                 "(e.g. function(x) max(x, na.rm = TRUE)).", call. = FALSE)
        }
    } else if (!is.function(reduce)) {
        stop(what, " reduce must be a function.", call. = FALSE)
    }
    invisible(TRUE)
}

bin_output <- function() {
    .new_spec(list(kind = "binary"), "ee_output_type")
}

num_output <- function(values_from = NULL, reduce = NULL) {
    .check_payload_args("num_output()", values_from, reduce,
                        reduce_required = TRUE)
    .new_spec(
        list(kind = "number", values_from = values_from, reduce = reduce),
        "ee_output_type")
}

# A categorical cohort column over a fixed level set. Two flavors, one ctor:
# with reduce = (payload flavor) the level is computed from the surviving payload
# rows' values and MUST be one of `levels`; without it (extraction flavor, e.g.
# smoking statuses) the level is a text channel's accepted documented status.
cat_output <- function(levels, values_from = NULL, reduce = NULL) {
    levels <- as.character(levels)
    if (!length(levels) || anyNA(levels) || any(!nzchar(levels)) ||
        anyDuplicated(levels)) {
        stop("cat_output() needs unique non-empty levels.", call. = FALSE)
    }
    .check_payload_args("cat_output()", values_from, reduce,
                        reduce_required = FALSE)
    if (!is.null(values_from) && is.null(reduce)) {
        stop("cat_output() values_from without reduce has no meaning: the payload ",
             "flavor needs both.", call. = FALSE)
    }
    .new_spec(
        list(kind = "categorical", levels = levels,
             values_from = values_from, reduce = reduce),
        "ee_output_type")
}

# A DATE cohort column: the value of a hit row is its CLOCK (the same date column
# the engine windows the channel on -- RECDATE for a doc, DATEACTE for an act,
# DATEXAM for a lab result), and reduce picks which one survives (min = first
# occurrence, max = last). Consumer 2026-07-07: date of the pre-op anesthesia
# consult (a doc_channel's RECDATE, reduce = max). An `at =` override naming a
# non-default clock column (e.g. DATSORT) is designed but waits for its consumer.
date_output <- function(values_from = NULL, reduce = NULL) {
    .check_payload_args("date_output()", values_from, reduce,
                        reduce_required = TRUE)
    .new_spec(
        list(kind = "date", values_from = values_from, reduce = reduce),
        "ee_output_type")
}

# A SET of cohort columns produced by one extraction task (e.g. the several
# anastomosis durations / types / locations from one operative report). The output
# contract belongs to the task, not to one scalar column.
struct_output <- function(fields) {
    fields <- as.character(fields)
    if (!length(fields) || anyNA(fields) || any(!nzchar(fields)) ||
        anyDuplicated(fields)) {
        stop("struct_output() needs unique non-empty fields.", call. = FALSE)
    }
    .new_spec(list(kind = "fields", fields = fields), "ee_output_type")
}
