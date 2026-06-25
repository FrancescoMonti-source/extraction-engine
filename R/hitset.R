# =============================================================================
# hitset.R -- boolean operators as set algebra over explicit hit sets
# -----------------------------------------------------------------------------
# A hit set is the set of ids (task/patient ids) matched by ONE signal definition
# (a channel under a variable_spec). Boolean operators are plain set algebra over
# those sets:
#
#     A OR  B  = union(A, B)
#     A AND B  = intersect(A, B)
#     A NOT B  = setdiff(A, B)
#
# This is set algebra over EXPLICIT hit sets, NOT clinical ontology. `A NOT B`
# means "in A's hit set and not in B's hit set under the SELECTED B definition" --
# it does NOT mean "B is clinically absent". The engine never infers clinical
# absence from silence; the caller keeps the audit label honest (e.g. "act and no
# dialysis HIT", not "act and no dialysis"). See the design note (operator/
# interpretation boundary) and the source-contribution invariants.
#
# This file is the PURE core (named id sets in, decision tibble out), deliberately
# decoupled from the channel/reduce machinery. run_variable.R wraps it to attach
# per-channel status + evidence provenance. No expression DSL yet -- just named
# sets partitioned into include/exclude roles.
# =============================================================================

suppressWarnings(suppressMessages(library(dplyr)))

# Resolve setdiff(union(include hit sets), union(exclude hit sets)) over a universe
# of ids, keeping per-id membership provenance so the audit can say WHICH role put
# each id in or out. OR-within-role (a union of the named sets in each role); the
# difference is between the two unions. `universe` bounds the result to the ids the
# variable is actually being computed over (so an exclude-only id is reported, not
# silently dropped). Returns one row per universe id with:
#   in_include / in_exclude -> membership of each role's union
#   included                -> final set membership (in_include & !in_exclude)
#   decision                -> the honest reason:
#       "no_include_hit"  not matched by any include signal       (value 0)
#       "excluded"        in include set but matched an exclude    (value 0)
#       "included"        in include set, no exclude hit           (value 1)
hit_set_decision <- function(universe, include_sets = list(),
                             exclude_sets = list()) {
    universe <- unique(as.character(universe))
    flatten <- function(sets) unique(as.character(unlist(sets, use.names = FALSE)))
    include_union <- flatten(include_sets)
    exclude_union <- flatten(exclude_sets)
    in_include <- universe %in% include_union
    in_exclude <- universe %in% exclude_union
    tibble::tibble(
        id = universe,
        in_include = in_include,
        in_exclude = in_exclude,
        included = in_include & !in_exclude,
        decision = dplyr::case_when(
            !in_include ~ "no_include_hit",
            in_exclude  ~ "excluded",
            TRUE        ~ "included"))
}
