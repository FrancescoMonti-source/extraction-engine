# =============================================================================
# hitset.R -- the deterministic boolean layer: string hit-set expressions
# -----------------------------------------------------------------------------
# A hit set is the set of ids (task/patient ids) matched by ONE signal definition
# (a channel under a variable_spec). The public boolean-combine surface is a string
# expression over channel names, e.g.
#   "(transplant_act | transplant_status) & !dialysis_signal"
# Allowed grammar: channel-name symbols (matching the variable's activated
# channels), the operators | & !, and parentheses. NOTHING else -- no function
# calls, arithmetic, comparisons, literals, or unknown operators.
#
# Boolean operators are plain set algebra over the hit sets -- | union, & intersect,
# ! complement relative to the task universe -- NOT clinical ontology. `!dialysis_
# signal` means "not in the dialysis_signal hit set within the current task
# universe", NOT "clinically no dialysis". The engine never infers clinical absence
# from silence; the audit keeps "no hit observed" distinct from "ascertained
# negative" (see the design note's operator/interpretation boundary).
#
# The expression is parsed to an R AST, structurally validated, then evaluated as
# THREE-VALUED (Kleene) logic over per-channel hit vectors. Each channel is a
# logical vector over the task universe: TRUE = hit, FALSE = ascertained no-hit,
# NA = unavailable/unascertained. R's own vectorised operators already implement
# Kleene logic, which is exactly what we want:
#   |  union        (TRUE | NA = TRUE,  FALSE | NA = NA)
#   &  intersection (FALSE & NA = FALSE, TRUE & NA = NA)
#   !  complement relative to the task universe (!NA = NA)
# So NA-propagation gives honest ascertainment for free: the result is NA exactly
# when its truth depends on an unavailable channel -> ascertainment "partial", and
# the final decision is included / excluded / undetermined (never silently binary).
#
# This file is the PURE core (parser / grammar / role derivation / evaluator /
# overlap), decoupled from the channel/reduce machinery; run_variable.R wraps it to
# attach per-channel status + evidence provenance + the Venn/UpSet audit.
# =============================================================================

suppressWarnings(suppressMessages(library(dplyr)))

.HITSET_OPS <- c("(", "!", "&", "|")

# Parse one expression string to a single AST node, or stop() with "malformed".
.parse_hitset_expr <- function(expr) {
    if (!is.character(expr) || length(expr) != 1L || !nzchar(trimws(expr))) {
        stop("A hit-set expression must be one non-empty string.", call. = FALSE)
    }
    parsed <- tryCatch(parse(text = expr), error = function(e) NULL)
    if (is.null(parsed) || length(parsed) != 1L) {
        stop("Malformed hit-set expression: ", expr, call. = FALSE)
    }
    parsed[[1L]]
}

# Structural grammar check. Returns the unique referenced channel symbols. Rejects
# function calls, arithmetic, comparisons, disallowed operators, literals/constants,
# and bad arity. Does NOT check symbols against activated channels (callers do that
# once the variable's channel list is known).
.check_hitset_grammar <- function(node) {
    if (is.name(node)) return(as.character(node))
    if (is.call(node)) {
        op <- as.character(node[[1L]])
        if (!op %in% .HITSET_OPS) {
            stop("Hit-set expressions allow only channel names and the operators ",
                 "| & ! () ; got: ", op, call. = FALSE)
        }
        arity <- length(node) - 1L
        if (op %in% c("(", "!") && arity != 1L) {
            stop("Malformed hit-set expression near '", op, "'.", call. = FALSE)
        }
        if (op %in% c("&", "|") && arity != 2L) {
            stop("Malformed hit-set expression near '", op, "'.", call. = FALSE)
        }
        return(unique(unlist(lapply(as.list(node)[-1L], .check_hitset_grammar),
                             use.names = FALSE)))
    }
    stop("Hit-set expressions allow only channel names and | & ! () ; got a ",
         "literal/constant: ", deparse(node), call. = FALSE)
}

# Per-channel polarity ("role in expression"): a channel under an odd number of `!`
# is "negated", an even number "asserted", and "mixed" if it appears both ways.
.hitset_expr_roles <- function(node) {
    seen <- list()
    walk <- function(n, negated) {
        if (is.name(n)) {
            ch <- as.character(n)
            seen[[ch]] <<- unique(c(seen[[ch]], negated))
            return(invisible())
        }
        if (is.call(n)) {
            op <- as.character(n[[1L]])
            if (identical(op, "!")) { walk(n[[2L]], !negated); return(invisible()) }
            for (i in seq_along(n)[-1L]) walk(n[[i]], negated)
        }
    }
    walk(node, FALSE)
    vapply(names(seen), function(ch) {
        pol <- seen[[ch]]
        if (length(pol) > 1L) "mixed" else if (isTRUE(pol)) "negated" else "asserted"
    }, character(1))
}

# Evaluate a validated AST over a named list of per-channel logical vectors. Pure
# three-valued logic via R's own operators; no eval(), no base-function exposure.
.eval_hitset_expr <- function(node, vectors) {
    if (is.name(node)) return(vectors[[as.character(node)]])
    op <- as.character(node[[1L]])
    if (identical(op, "(")) return(.eval_hitset_expr(node[[2L]], vectors))
    if (identical(op, "!")) return(!.eval_hitset_expr(node[[2L]], vectors))
    a <- .eval_hitset_expr(node[[2L]], vectors)
    b <- .eval_hitset_expr(node[[3L]], vectors)
    if (identical(op, "|")) return(a | b)
    a & b
}

# UpSet-style overlap summary: group tasks by their membership PATTERN across the
# expression channels (the scientifically useful overlap structure), with the count,
# the (pattern-determined) final decision and ascertainment. `wide` is one row per
# task: task_id + one logical column per channel (hit T/F/NA). Keeps the per-channel
# state columns so it is directly pivotable for ggupset/UpSetR.
hit_set_overlap <- function(wide, channels, decision, ascertainment) {
    state_str <- function(x) ifelse(is.na(x), "NA", ifelse(x, "TRUE", "FALSE"))
    parts <- lapply(channels, function(ch) sprintf("%s:%s", ch, state_str(wide[[ch]])))
    pattern <- do.call(paste, c(parts, list(sep = " | ")))
    df <- wide
    df$pattern <- pattern
    df$decision <- decision
    df$ascertainment <- ascertainment
    df %>%
        dplyr::group_by(dplyr::across(dplyr::all_of(
            c(channels, "pattern", "decision", "ascertainment")))) %>%
        dplyr::summarise(n = dplyr::n(), .groups = "drop") %>%
        dplyr::arrange(dplyr::desc(n))
}
