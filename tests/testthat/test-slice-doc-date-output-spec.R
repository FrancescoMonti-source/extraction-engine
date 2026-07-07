# Disposable probe (NOT a shipped concept): the doc channel + date_output pair
# (consumer named by owner 2026-07-07: date of the pre-op anesthesia consult =
# a document of a given type from unite medicale ANES). Two new axes at once,
# each the simplest of its family:
#   - doc_channel(doc_meta(...)): the document's EXISTENCE is the hit, selected
#     on docs_index METADATA -- no content, no Lucene, no LLM. Hit rows are
#     docs_index rows: identity spine + their own clock (RECDATE).
#   - date_output(reduce =): the value of a hit row is its CLOCK (the same date
#     the row was windowed on), and reduce picks which one survives (max = the
#     LAST consult before the operation). Before this, values_from handed reduce
#     a lab value or a CODE -- "when" was unreachable (min() over code strings =
#     the silent-wrong failure the Date contract check exists to prevent).
# The metadata pick is the consumer's full shape: RECTYPE (document type) AND
# SEJUM (the unite medicale the document is attributed to -- owner-named column,
# 2026-07-07, declared in DOCS_SOURCE). Filter semantics (owner-mandated: "ANES
# OR ORTH" is a certain need): values WITHIN a column are any-of (OR), columns
# CONJOIN (AND).

dd_tasks <- tibble::tibble(
    grain_id = paste0("D", 1:3, "::t"),
    PATID = paste0("D", 1:3),
    anchor_date = as.Date("2024-06-01"))   # each patient's surgery day

dd_docs_index <- tibble::tibble(
    ELTID   = paste0("DOC", 1:8),
    PATID   = c("D1", "D1", "D1", "D1", "D1", "D2", "D2", "D2"),
    EVTID   = c("V1", "V1", "V2", "V3", "V4", "W1", "W1", "W2"),
    RECDATE = as.Date(c("2024-05-10", "2024-05-25",   # D1: two pre-op consults
                        "2024-06-10",                  # D1: consult AFTER surgery
                        "2024-05-20",                  # D1: another doc type
                        "2024-05-28",                  # D1: CR-ANES, WRONG unit --
                                                       #     would change the max
                        "2024-05-15", "2024-05-18",    # D2: other types only
                        "2024-05-12")),                # D2: consult via the OR arm
    RECTYPE = c("CR-ANES", "CR-ANES", "CR-ANES", "CRH", "CR-ANES",
                "CRH", "CR-OP", "CR-ANES"),
    SEJUM   = c("ANES", "ANES", "ANES", "ANES", "CHIR",
                "ANES", "CHIR", "ORTH"))
    # D3 has no documents at all.

dd_concept <- concept_spec(
    name = "consultation_anesthesie",
    channels = list(
        doc_anes = doc_channel(
            source = "documents",
            selector = doc_meta(RECTYPE = "CR-ANES",
                                SEJUM = c("ANES", "ORTH")),
            linkage = "subject")))

dd_var <- function(reduce = max) {
    variable_spec(
        name = "date_consult_anesthesie",
        concept = dd_concept,
        output_one_row_per = "PATID",
        anchor = "anchor_date",
        window = c(-90, 0),
        channels = "doc_anes",
        output = date_output(reduce = reduce))
}

test_that("the document's existence is the hit and its clock the value (last pre-op consult)", {
    run <- run_variable(dd_var(), dd_tasks,
                        list(documents = dd_docs_index))
    value <- setNames(run$values$value, run$values$grain_id)
    coverage <- setNames(run$values$channel_coverage, run$values$grain_id)

    # D1: max over the IN-WINDOW rows matching BOTH filters -- the post-op
    # consult (06-10), the CRH (other type) and the 05-28 CR-ANES from a unit
    # OUTSIDE the any-of set (SEJUM = CHIR) never enter the pool: a later date
    # that a single-column filter would have silently returned.
    expect_s3_class(run$values$value, "Date")
    expect_equal(value[["D1::t"]], as.Date("2024-05-25"))
    # D2: qualifies through the OR arm of the column's any-of set (ORTH); the
    # same-patient CRH/CR-OP rows still fail the type filter.
    expect_equal(value[["D2::t"]], as.Date("2024-05-12"))
    expect_true(is.na(value[["D3::t"]]))    # no documents at all
    expect_equal(unname(coverage[["D3::t"]]), "partial")

    # Provenance = the docs_index rows the date was reduced from, and ONLY those.
    ev1 <- run$evidence[run$evidence$grain_id == "D1::t", ]
    expect_setequal(ev1$source_row_id, c("DOC1", "DOC2"))
})

test_that("a reduce breaking the Date contract is a hard error, not a silent coercion", {
    expect_error(
        run_variable(dd_var(reduce = length), dd_tasks,
                     list(documents = dd_docs_index)),
        "Date")
})
