# Contract tests for the string boolean hit-set expression combine:
#   combine = "(transplant_act | transplant_status) & !dialysis_signal"
# Grammar: channel symbols + | & ! and parentheses, nothing else. Evaluation is
# three-valued (Kleene) over per-channel hit vectors (TRUE hit / FALSE ascertained
# no-hit / NA unavailable): | union, & intersection, ! complement over the task
# universe. NA propagates honestly into ascertainment. The audit is built for
# Venn/UpSet -- a membership long-form + an overlap summary -- NOT reduced to
# included/excluded. Three code channels over synthetic data; no model.

# Synthetic ICD-10 vehicles (real-shaped so they pass the usability check): Z94
# (transplant status) as the two inclusion signals from two separate sources, Z99
# (machine/dialysis dependence) as the exclusion signal, I10 as a usable
# non-matching code (-> ascertained negative). Separate sources so a channel can be
# genuinely unavailable while another is ascertained.
hx_concept <- function() {
    code_ch <- function(source, prefix) code_channel(
        source = source, selector = icd10(prefix),
        native_grain = "diagnosis_row",
        required_roles = c("subject", "event", "interval_start", "interval_end",
                           "code", "native_ref"),
        linkage = "subject")
    concept_spec(
        name = "transplant_minus_dialysis",
        channels = list(
            transplant_act    = code_ch("acts", "Z94"),
            transplant_status = code_ch("status_dx", "Z94"),
            dialysis_signal   = code_ch("dialysis_dx", "Z99")))
}

# Headline UX: combine is a BARE STRING.
HX_EXPR <- "(transplant_act | transplant_status) & !dialysis_signal"

hx_var <- function(expr = HX_EXPR,
                   channels = list(transplant_act = use_channel(),
                                   transplant_status = use_channel(),
                                   dialysis_signal = use_channel())) {
    variable_spec(
        name = "transplant_without_dialysis", concept = hx_concept(),
        unit = "transplant", anchor = "anchor_date",
        window = before_anchor(days = 1825L, grace_days = 7L),
        channels = channels, output = binary_output(),
        combine = expr, absence_policy = open_world())
}

hx_tasks <- tibble::tibble(
    task_id = paste0("HX", 1:7, "::t"),
    PATID = paste0("Q", 1:7),
    anchor_date = as.Date("2024-06-01"))

hx_row <- function(srid, patid, code) tibble::tibble(
    source_row_id = srid, PATID = patid, EVTID = paste0("E", patid),
    ELTID = paste0("L", srid), diag = code,
    DATENT = as.Date("2024-05-20"), DATSORT = as.Date("2024-05-21"))

# acts source (transplant_act): hit=Z940, ascertained-negative=I10, unavailable=none
hx_acts <- dplyr::bind_rows(
    hx_row("acts:1", "Q1", "Z940"),   # HX1 act hit
    hx_row("acts:2", "Q2", "I10"),    # HX2 act negative
    hx_row("acts:3", "Q3", "Z940"),   # HX3 act hit
    hx_row("acts:4", "Q4", "I10"),    # HX4 act negative
    hx_row("acts:5", "Q5", "Z940"),   # HX5 act hit
    # Q6 absent -> transplant_act unavailable
    hx_row("acts:7", "Q7", "Z940"))   # HX7 act hit (dup pattern of HX1)

# status_dx source (transplant_status)
hx_status <- dplyr::bind_rows(
    hx_row("st:1", "Q1", "I10"),      # HX1 status negative
    hx_row("st:2", "Q2", "Z940"),     # HX2 status hit
    hx_row("st:3", "Q3", "I10"),      # HX3 status negative
    hx_row("st:4", "Q4", "I10"),      # HX4 status negative
    hx_row("st:5", "Q5", "I10"),      # HX5 status negative
    # Q6 absent -> transplant_status unavailable
    hx_row("st:7", "Q7", "I10"))      # HX7 status negative

# dialysis_dx source (dialysis_signal): hit=Z992, ascertained-negative=I10
hx_dia <- dplyr::bind_rows(
    hx_row("dx:1", "Q1", "I10"),      # HX1 dialysis negative
    hx_row("dx:2", "Q2", "I10"),      # HX2 dialysis negative
    hx_row("dx:3", "Q3", "Z992"),     # HX3 dialysis HIT
    hx_row("dx:4", "Q4", "I10"),      # HX4 dialysis negative
    # Q5 absent -> dialysis_signal unavailable
    hx_row("dx:6", "Q6", "I10"),      # HX6 dialysis negative
    hx_row("dx:7", "Q7", "I10"))      # HX7 dialysis negative

hx_sources <- list(acts = hx_acts, status_dx = hx_status, dialysis_dx = hx_dia)

hx_run <- function(...) run_variable(hx_var(), hx_tasks, hx_sources, ...)

# Expected per-task evaluation of (act | status) & !dialysis :
#   HX1 act T,            dia F -> (T|F)&!F = T  included     complete
#   HX2 status T,         dia F -> (F|T)&!F = T  included     complete
#   HX3 act T,            dia T -> (T|F)&!T = F  excluded     complete
#   HX4 both negative,    dia F -> (F|F)&!F = F  excluded     complete
#   HX5 act T,            dia NA-> (T|F)&!NA= NA undetermined partial   (exclusion unavailable)
#   HX6 act+status NA,    dia F -> (NA|NA)&!F=NA undetermined partial   (inclusion unavailable)
#   HX7 act T,            dia F -> same pattern as HX1 (counted together in overlap)

test_that("a bare string combine evaluates as three-valued boolean set algebra", {
    run <- hx_run()
    val <- setNames(run$values$value, run$values$task_id)
    dec <- setNames(run$values$decision, run$values$task_id)
    asc <- setNames(run$values$ascertainment, run$values$task_id)

    expect_equal(dec[["HX1::t"]], "included");     expect_equal(val[["HX1::t"]], 1L)
    expect_equal(asc[["HX1::t"]], "complete")
    expect_equal(dec[["HX2::t"]], "included");     expect_equal(val[["HX2::t"]], 1L)
    expect_equal(dec[["HX3::t"]], "excluded");     expect_equal(val[["HX3::t"]], 0L)
    expect_equal(asc[["HX3::t"]], "complete")
    expect_equal(dec[["HX4::t"]], "excluded");     expect_equal(val[["HX4::t"]], 0L)

    # NA propagation -> undetermined, partial (NOT silently excluded)
    expect_equal(dec[["HX5::t"]], "undetermined"); expect_true(is.na(val[["HX5::t"]]))
    expect_equal(asc[["HX5::t"]], "partial")
    expect_equal(dec[["HX6::t"]], "undetermined"); expect_true(is.na(val[["HX6::t"]]))
    expect_equal(asc[["HX6::t"]], "partial")

    expect_equal(run$combine_rule, "hit_set_expr")
})

# Why: don't reduce the audit to included/excluded. The membership long-form carries
# per-channel hit state, role-in-expression, processing_state, and evidence refs.
test_that("membership long-form exposes per-channel hit structure for Venn/UpSet", {
    run <- hx_run()
    m <- run$membership
    expect_true(all(c("task_id", "channel", "role", "hit",
                      "processing_state", "evidence_refs") %in% names(m)))

    get <- function(tid, ch, col) m[[col]][m$task_id == tid & m$channel == ch]
    # role in expression: the two transplant channels are asserted, dialysis negated
    expect_equal(unique(m$role[m$channel == "transplant_act"]), "asserted")
    expect_equal(unique(m$role[m$channel == "transplant_status"]), "asserted")
    expect_equal(unique(m$role[m$channel == "dialysis_signal"]), "negated")

    # three-valued hit per channel
    expect_true(get("HX1::t", "transplant_act", "hit"))           # hit
    expect_false(get("HX1::t", "transplant_status", "hit"))       # ascertained negative
    expect_true(is.na(get("HX5::t", "dialysis_signal", "hit")))   # unavailable
    expect_equal(get("HX5::t", "dialysis_signal", "processing_state"),
                 "no_eligible_source")

    # evidence refs for hits only
    expect_equal(get("HX1::t", "transplant_act", "evidence_refs"), "acts:1")
    expect_true(is.na(get("HX1::t", "transplant_status", "evidence_refs")))
    # and the full evidence table is role-tagged
    expect_true(all(c("role", "evidence_ref") %in% names(run$evidence)))
    expect_equal(run$evidence$evidence_ref[run$evidence$task_id == "HX3::t" &
                                           run$evidence$role == "negated"], "dx:3")
})

# Why: the overlap summary is the scientifically useful view -- how the source hit
# sets overlap, with counts + the pattern-determined decision/ascertainment.
test_that("overlap summary groups tasks by membership pattern (UpSet-style)", {
    run <- hx_run()
    ov <- run$overlap
    expect_true(all(c("transplant_act", "transplant_status", "dialysis_signal",
                      "pattern", "decision", "ascertainment", "n") %in% names(ov)))

    # the summary partitions the cohort
    expect_equal(sum(ov$n), nrow(hx_tasks))
    # HX1 and HX7 share a membership pattern -> grouped, n = 2
    inc_pat <- ov[ov$transplant_act %in% TRUE &
                  ov$transplant_status %in% FALSE &
                  ov$dialysis_signal %in% FALSE, ]
    expect_equal(inc_pat$n, 2L)
    expect_equal(inc_pat$decision, "included")
    expect_equal(inc_pat$ascertainment, "complete")

    # aggregate decision counts across patterns
    dec_n <- tapply(ov$n, ov$decision, sum)
    expect_equal(unname(dec_n[["included"]]), 3L)       # HX1, HX2, HX7
    expect_equal(unname(dec_n[["excluded"]]), 2L)       # HX3, HX4
    expect_equal(unname(dec_n[["undetermined"]]), 2L)   # HX5, HX6
})

# --- the parser / grammar, in isolation --------------------------------------
test_that("hit_set_expr() accepts the allowed grammar and derives roles", {
    e <- hit_set_expr("(a | b) & !c")
    expect_equal(e$kind, "hit_set_expr")
    expect_setequal(e$channels, c("a", "b", "c"))
    expect_equal(unname(e$roles[c("a", "b", "c")]),
                 c("asserted", "asserted", "negated"))
    # a channel that appears both plain and negated is "mixed"
    expect_equal(unname(hit_set_expr("a & !a")$roles[["a"]]), "mixed")
})

test_that("hit_set_expr() rejects everything outside the grammar", {
    expect_error(hit_set_expr("a + b"), "operators")        # arithmetic
    expect_error(hit_set_expr("a == b"), "operators")       # comparison
    expect_error(hit_set_expr("foo(a)"), "operators")       # function call
    expect_error(hit_set_expr("a && b"), "operators")       # disallowed operator
    expect_error(hit_set_expr("a & 5"), "literal")          # constant
    expect_error(hit_set_expr("a &"), "[Mm]alformed")       # parse error
    expect_error(hit_set_expr("a; b"), "[Mm]alformed")      # two expressions
    expect_error(hit_set_expr(""), "non-empty")             # empty
})

# Why: the evaluator is pure three-valued (Kleene) logic; verify NA short-circuits.
test_that(".eval_hitset_expr is Kleene three-valued logic", {
    ast <- hit_set_expr("(a | b) & !c")$ast
    res <- .eval_hitset_expr(ast, list(
        a = c(TRUE,  FALSE, TRUE,  NA),
        b = c(FALSE, TRUE,  FALSE, FALSE),
        c = c(FALSE, FALSE, TRUE,  FALSE)))
    expect_equal(res, c(TRUE, TRUE, FALSE, NA))

    # FALSE & NA short-circuits to FALSE (decision determined despite an unknown);
    # TRUE & NA stays NA (decision depends on the unavailable channel)
    expect_false(.eval_hitset_expr(hit_set_expr("a & b")$ast,
                                   list(a = FALSE, b = NA)))
    expect_true(is.na(.eval_hitset_expr(hit_set_expr("a & b")$ast,
                                        list(a = TRUE, b = NA))))
})

# --- spec-time channel validation --------------------------------------------
test_that("a referenced-but-unactivated channel is a build-time error", {
    expect_error(
        hx_var(channels = list(transplant_act = use_channel(),
                               transplant_status = use_channel())),  # dialysis missing
        "non-activated")
})

test_that("an activated-but-unreferenced channel is a build-time error", {
    expect_error(
        hx_var(expr = "transplant_act | transplant_status"),  # dialysis activated, unused
        "not used")
})
