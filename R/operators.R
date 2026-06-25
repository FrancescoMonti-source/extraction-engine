# =============================================================================
# operators.R -- experimental operators / helpers
# -----------------------------------------------------------------------------
# Generic reusable computational pieces used INSIDE a variable_spec or template:
# windows, reducers, combiners, output types, absence policies, extraction
# methods. These are operators/helpers, NOT variable templates (a variable
# template is concept-specific; these are not). Each is a thin tagged record the
# runner reads by class/kind.
# =============================================================================

# --- relative windows ---------------------------------------------------------
before_anchor <- function(days, grace_days = 0L) {
    .experimental_spec(
        list(kind = "relative_window", from_days = -as.integer(days),
             to_days = as.integer(grace_days), relation = "before_anchor"),
        "ee_window")
}

days_after <- function(from_days = 0L, to_days) {
    .experimental_spec(
        list(kind = "relative_window", from_days = as.integer(from_days),
             to_days = as.integer(to_days), relation = "days_after"),
        "ee_window")
}

# --- within-channel reducers --------------------------------------------------
max_value <- function() {
    .experimental_spec(list(kind = "max_value"), "ee_reducer")
}

# --- cross-channel combiners / collapses --------------------------------------
any_positive <- function() {
    .experimental_spec(list(kind = "any_positive"), "ee_combiner")
}

# Non-`any` collapse for a categorical documented status: take the activated
# channel's documented status as the value, keeping `indetermine` (model judged
# the evidence inconclusive) distinct from `no_candidate` (nothing retrieved) and
# from `invalid` (definitive status without grounding -> needs_review). For one
# channel it is a passthrough; the slot is ready for a categorical reconcile if a
# second channel is ever activated.
documented_status <- function() {
    .experimental_spec(list(kind = "documented_status"), "ee_combiner")
}

# Collect one extraction task's several fields, keeping field-level acceptance: a
# valid grounded field survives an invalid sibling, and the task is flagged for
# review iff any field is invalid (or the call failed). Not a binary collapse.
collect_fields <- function() {
    .experimental_spec(list(kind = "collect_fields"), "ee_combiner")
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
    .experimental_spec(
        list(kind = "hit_set_expr", expr = expr, ast = ast,
             channels = channels, roles = .hitset_expr_roles(ast)),
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
# top_n is carried for provenance; the slice's text source is pre-retrieved, so it
# is not yet consumed by run_extraction (a retrieval-ordering seam is future work).
llm_after_lucene <- function(top_n = NULL) {
    .experimental_spec(list(kind = "llm_after_lucene", top_n = top_n),
                       "ee_extraction_method")
}

# --- output (cohort column) types ---------------------------------------------
# Suffix avoids masking base::numeric()/the word "binary"; the design note's
# binary()/numeric() spelling is deferred to avoid the shadowing.
binary_output <- function() {
    .experimental_spec(list(kind = "binary"), "ee_output_type")
}

number_output <- function() {
    .experimental_spec(list(kind = "number"), "ee_output_type")
}

# A categorical cohort column over a fixed level set (e.g. smoking statuses).
categorical_output <- function(levels) {
    .experimental_spec(list(kind = "categorical", levels = as.character(levels)),
                       "ee_output_type")
}

# A SET of cohort columns produced by one extraction task (e.g. the several
# anastomosis durations / types / locations from one operative report). The output
# contract belongs to the task, not to one scalar column.
fields_output <- function(fields) {
    .experimental_spec(list(kind = "fields", fields = as.character(fields)),
                       "ee_output_type")
}

# --- absence policies ---------------------------------------------------------
# Absence is interpreted at variable_spec level. The carried incomplete_value is
# what the combiner returns when ascertainment is partial (no positive + a source
# was unavailable), so missing evidence is never silently turned into a negative.
open_world <- function(incomplete_value = NA_integer_) {
    .experimental_spec(list(kind = "open_world", incomplete_value = incomplete_value),
                       "ee_absence_policy")
}

missing_if_no_measurement <- function() {
    .experimental_spec(
        list(kind = "missing_if_no_measurement", incomplete_value = NA_real_),
        "ee_absence_policy")
}
