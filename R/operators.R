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
# A within-channel reducer is just a plain function numeric -> scalar, supplied on
# the variable's channel activation: use_channel(reducer = function(x) max(x, na.rm =
# TRUE)). No bespoke operator wraps trivial base reductions (max/min/mean/length);
# the numeric-output assembler applies the function to the channel's candidate values.

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
    .experimental_spec(list(kind = "any_positive"), "ee_combiner")
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
# Constructor names are short: bin_output() / num_output() / cat_output() /
# struct_output(). Each is a thin tagged record; the internal $kind the runner
# dispatches on (binary/number/categorical/fields) is unchanged.
bin_output <- function() {
    .experimental_spec(list(kind = "binary"), "ee_output_type")
}

num_output <- function() {
    .experimental_spec(list(kind = "number"), "ee_output_type")
}

# A categorical cohort column over a fixed level set (e.g. smoking statuses).
cat_output <- function(levels) {
    .experimental_spec(list(kind = "categorical", levels = as.character(levels)),
                       "ee_output_type")
}

# A SET of cohort columns produced by one extraction task (e.g. the several
# anastomosis durations / types / locations from one operative report). The output
# contract belongs to the task, not to one scalar column.
struct_output <- function(fields) {
    .experimental_spec(list(kind = "fields", fields = as.character(fields)),
                       "ee_output_type")
}
