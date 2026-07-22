# extractionengine

> `extractionengine` is the auditable executor of a study's operational
> definitions, not the author of those definitions.

The package executes explicit study-variable specifications over prepared EDSAN
views. It returns values together with source coverage, resolvable evidence, and
execution provenance. The researcher owns the clinical definition and its
scientific interpretation; `redsan` owns source normalization; `ellmer` owns
model transport and structured output.

The package is experimental and currently intended for internal use. Its API is
allowed to break when a clearer execution contract is found. It contains no
patient data or exported clinical concepts.

## Start here

New users should begin with
[`vignette("getting-started", package = "extractionengine")`](vignettes/getting-started.Rmd).
It builds one auditable variable from synthetic data, translates the relational
contract to dplyr, and explains the result and audit objects.

## One complete authoring workflow

Assume `cohort` contains `PATID + EVTID`, `bio` is a prepared biology view, and
`documents` is a metadata-rich `corpustools::tCorpus`. A concept only locates
source rows. It does not decide which source column becomes the result or how
those rows are interpreted.

```r
anemia <- concept_spec(
  name = "anemia",
  channels = list(
    hb = lab_channel(
      selector = analyte("NGR.NGR-HB-GDL")
    ),
    text_anemia = text_channel(
      selector = lucene_query("anemi*")
    )
  )
)
```

`lab_channel()` defaults to the logical source `"biology"`; another registered
lab source can be named with `source =`. `analyte()` selects `TYPEANA` rows and
nothing else. It does not infer whether `NUMRES`, `STRRES`, or `DATEXAM` should be
read.

The variable activates concept channels explicitly. The list name is the alias
used by combine expressions, output, inspection, and provenance. The mandatory
`channel =` points either to a concept-channel name or to an inline channel
definition. It never points to another activation alias.

```r
mean_hb_for_patients_with_anemic_stays <- variable_spec(
  name = "mean_hb_for_patients_with_anemic_stays",
  concept = anemia,

  channels = list(
    text_anemia = use_channel(
      channel = "text_anemia",
      search_within = "PATID",
      method = "lucene"
    ),
    hb = use_channel(
      channel = "hb"
    ),
    hb_low = use_channel(
      channel = "hb",
      filter_rows = \(NUMRES, PATSEX) {
        NUMRES < ifelse(PATSEX == "F", 12, 13)
      }
    )
  ),

  combine = combine_channels(
    "text_anemia & hb_low",
    by = "EVTID"
  ),

  output = from_channel(
    "hb",
    column = "NUMRES",
    filter_by_qualified = "PATID",
    group_by = "PATID",
    reduce = mean
  )
)

hb_result <- run_variable(
  mean_hb_for_patients_with_anemic_stays,
  cohort = cohort,
  sources = list(biology = bio, documents = documents)
)
```

Here `filter_rows` runs separately inside each task after relational, window, and
selector filtering. Its formal arguments name real prepared-source columns and
it returns one logical per row; `NA` is treated as `FALSE`, and surviving rows
stay intact. `filter_groups`, paired with `use_channel(group_by =)`, is the
corresponding one-logical-per-group rule and retains all surviving rows of
accepted groups. That `group_by` is an intermediate grouping used only by
`filter_groups`; it is not the final output grain. The mandatory `group_by` in
`bin_output(group_by = ...)` or `from_channel(group_by = ...)` independently
defines that terminal grain.
An activation may also declare `window = c(from_days, to_days)` relative to the
variable's shared `anchor`; other activations remain unwindowed.

A character anchor names an exact `Date` or `POSIXt` column supplied by the
cohort. For example, a stay-grain cohort may carry `PATID`, `EVTID`, and
`admission_date`, and the variable may declare `anchor = "admission_date"`.
When a window consumes that anchor, every output unit must retain one
unambiguous, non-missing date after cohort projection. The engine copies it to
the internal task clock; it does not look for that column in a channel source.

Alternatively, `index_event()` derives the clock from the registered source it
names, before any channel runs. It currently accepts a code selector created by
`icd10()` or `ccam()`; `at` names the source's real date column (or defaults to
its registered clock), and `select_event` must resolve multiple matches by
selecting rows from that matched relation. It may filter or reorder those rows,
but cannot alter or invent an `EVTID`/date pair. This anchor resolution is
independent of the variable's activated channels.

The relational declarations answer different questions:

- `search_within = "PATID"` makes the patient's documents eligible before
  retrieval; their native `EVTID`, when present, can still support a finer
  combine; text activations must declare `"PATID"` or `"EVTID"`;
- `combine_channels(..., by = "EVTID")` requires the text and low-Hb signals to
  coexist in a stay;
- `filter_by_qualified = "PATID"` lets the reducer read all Hb rows of each
  qualified patient; changing it to `"EVTID"` restricts the mean to qualifying
  stays;
- `group_by = "PATID"` publishes one final row per patient.

`filter_by_qualified` is admitted, and required, only when `combine$by` is finer
than `output$group_by`; it may then be only the combine key or the output key.
It must be `NULL` when there is no combine, the grains are equal, or a coarser
combine is broadcast to finer output units. A channel may be payload-only: `hb`
feeds `from_channel()` even though only `text_anemia` and `hb_low` occur in the
combine expression. Here *payload* simply means the source data selected for
publication; it is not a hidden engine column.

### Why the qualifying-row filter and output grain are different

The subtle case is a combine evaluated at a finer key than the final output,
followed by a `from_channel()` reducer. Suppose one patient has two stays:

| PATID | EVTID | Hb values | Combine result |
|---|---|---|---|
| P1 | E1 | 8, 10 | qualifying |
| P1 | E2 | 14, 16 | not qualifying |

With `combine_channels(..., by = "EVTID")`, the combine answers only that E1
qualifies. With `group_by = "PATID"`, the reducer must ultimately publish one
value for P1. Those declarations still leave two scientifically different
questions.

To ask *what is the patient's mean Hb in qualifying stays?*, restrict the input
rows by the combine key:

```r
from_channel(
  "hb",
  column = "NUMRES",
  filter_by_qualified = "EVTID",
  group_by = "PATID",
  reduce = mean
)
```

This is relationally equivalent to:

```r
hb_rows |>
  semi_join(qualified_evtids, by = c("PATID", "EVTID")) |>
  group_by(PATID) |>
  summarise(value = mean(NUMRES))
# P1: mean(c(8, 10)) = 9
```

To ask *among patients with at least one qualifying stay, what is the patient's
mean Hb across all stays?*, restrict by the output key instead:

```r
from_channel(
  "hb",
  column = "NUMRES",
  filter_by_qualified = "PATID",
  group_by = "PATID",
  reduce = mean
)
```

This first projects the qualifying stays to their patients, then filters the Hb
rows:

```r
qualified_patids <- qualified_evtids |>
  distinct(PATID)

hb_rows |>
  semi_join(qualified_patids, by = "PATID") |>
  group_by(PATID) |>
  summarise(value = mean(NUMRES))
# P1: mean(c(8, 10, 14, 16)) = 12
```

Both routes correctly produce one row per PATID. Execution always follows
`combine by -> filter by qualified -> group by -> reduce`, and the three
declarations answer separate questions:

- `combine$by`: where is qualification decided?
- `filter_by_qualified`: rows from which qualified units feed the reducer?
- `output$group_by`: at which key is the final result grouped and published?

The payload channel's public evidence follows the same qualified-row relation:
it cannot include rows from units excluded before grouping. The complete
pre-gate channel intermediate remains available under `audit$internal`.

The filter must be `NULL` when there is no combine, when
`bin_output(group_by = ...)` publishes membership directly, when combine and
output use the same key, or when a coarser combine is broadcast to a finer
output grain.

An LLM response is already one row per output task. When it is used as a
fine-to-coarse payload, `filter_by_qualified` must therefore equal
`output$group_by`; lower-level LLM payload scope would require one model call per
lower-level key and is not implemented.

For a deterministic channel, `column` is the exact prepared-source column name.
There is no hidden `value` alias. With `reduce = NULL`, zero non-missing values
produce a typed `NA`, one is returned directly, and more than one is a cardinality
error. With `reduce =`, the reducer receives only non-missing values and must
return exactly one scalar. It may intentionally change type, for example from a
numeric measurement to a categorical label. Consequently the same lab concept
can be published with `column = "NUMRES"`, `"STRRES"`, or `"DATEXAM"`; a row
containing both result columns is valid because the read is explicit.

The reducer is terminal: `group_by = "EVTID"` with `reduce = mean` computes one
stay mean, while `group_by = "PATID"` pools the patient's raw values.
`filter_by_qualified` filters rows before that grouping and reducer; it does not
implement a mean of stay means. Such a two-stage aggregation requires an
explicit derived variable and is intentionally future work.

## Structured text extraction

LLM-specific fields are declared directly with a native `ellmer::TypeObject`.
The concept still only locates candidate text:

```r
tabagisme <- concept_spec(
  name = "tabagisme",
  channels = list(
    text_tabagisme = text_channel(
      selector = lucene_query("taba*")
    )
  )
)

tabagisme_levels <- c("actif", "sevre", "non_fumeur", "indetermine")

tabagisme_enum <- variable_spec(
  name = "tabagisme_enum",
  concept = tabagisme,

  channels = list(
    text_tabagisme = use_channel(
      channel = "text_tabagisme",
      search_within = "EVTID",
      method = "lucene_llm",
      model = "gemma3:4b",
      model_params = list(temperature = 0, seed = 42),
      response = ellmer::type_object(
        "Extraction structurée du statut tabagique.",
        statut_tabagique = ellmer::type_enum(
          tabagisme_levels,
          paste(
            "Statut explicitement documenté;",
            "ne jamais déduire non_fumeur du silence."
          )
        )
      )
    )
  ),

  output = from_channel("text_tabagisme", group_by = "EVTID")
)

smoking_result <- run_variable(
  tabagisme_enum,
  cohort = cohort,
  sources = list(documents = documents)
)
```

`from_channel("text_tabagisme", group_by = "EVTID")` publishes the complete
structured frame: every authored TypeObject field plus `rationale` by default.
Supplying `column =` instead projects one field. In `use_channel()`,
`rationale = TRUE` or omission uses:
“Justification brève du choix, fondée uniquement sur les extraits et sans ajouter
d'information non documentée.” A non-empty string overrides that description;
`FALSE` or `NULL` omits the field.

The package-level system prompt contains only general structured-extraction
instructions and can be overridden with `system_prompt =`. The engine constructs
the user prompt from the target and numbered excerpts; `user_prompt =` is an
optional prefix for cross-field instructions. Variable-specific meaning belongs
in the TypeObject and individual `type_*()` descriptions.

Before `chat_structured()`, the engine adds `rationale` and an `evidence_ids` enum
limited to the snippets actually shown. Those names, grain keys, and audit fields
are reserved and cannot collide with authored fields. Evidence identifiers are
resolved to the evidence table rather than published as JSON columns. No manual
`json_format` is used.

A completed response is valid only when at least one returned evidence ID
resolves to a supplied snippet. Mixed real and invented IDs keep the grounded
result, discard the invented IDs, and raise a citation warning. A response with
no real ID is invalid and publishes typed missing fields plus review state while
retaining its raw response in the audit.

Retrieval retains identical wording from distinct native source units for
relational evidence. Before applying `max_candidates`, the LLM prompt separately
keeps one canonical occurrence of each normalized hit sentence per task (or
normalized snippet text for pre-retrieved inputs without `hit_text`), so repeated
documents do not crowd distinct excerpts out of a bounded prompt.

Pre-retrieved text inputs are a test/debug boundary and must describe a possible
retrieval result: `coverage_state` uses the three canonical states, and a task has
candidate rows if and only if its state is `candidate`.

An LLM response does not implicitly define boolean channel membership. A
`lucene_llm` activation may be published with `from_channel()` (including as a
payload gated by a deterministic combine), but it cannot currently appear in
`combine = combine_channels(...)`. Compilation fails with an explanatory error
until an explicit response-to-hit rule such as `hit_when` is implemented. Use
`method = "lucene"` when Lucene-hit presence itself is the intended membership
signal.

No candidate, model failure, or invalid schema still yields a stable result row
with typed missing fields and separate status/review information. Raw response
and provenance remain auditable. Public evidence has one durable
`evidence_ref`; LLM evidence also keeps the prompt-local `snippet_id` when
available. Internal `source_row_id` and `hit_ref` coordinates remain in
`audit$internal$channel_intermediates`, not in the public evidence frame. When
an evidence row carries a native `EVTID`, the public evidence frame names it
`source_EVTID`; at stay-grain output, the target stay remains `EVTID`.

`run_variable()` returns only `values`, `channel_status`, `evidence`, and
`audit`. `channel_status` has one row per output task and activated channel. Its
stable core identifies the output unit, variable, channel, and source, then
records `status`, `hit`, and `processing_state`; some execution paths add review
or contribution fields. `status` is the coarse execution outcome: `complete`
means that ascertainment finished, not that a signal was present. Presence is
recorded separately as `TRUE`, `FALSE`, or `NA` in `hit`, while
`processing_state` retains the more specific executor outcome. On a combine,
`contribution` summarizes the channel as `signal`, `negative`,
`silent`, `invalid`, `error`, or `unknown`; here `negative` means "successfully
ascertained with no observed hit", not a clinical negative finding.

`evidence` has one row per retained source row or text snippet. Structured
evidence preserves the prepared source's row columns, such as `TYPEANA`,
`NUMRES`, `STRRES`, and `DATEXAM` when available, together with its public
coordinates. Every row receives one canonical `evidence_ref`; internal
`source_row_id` and `hit_ref` identifiers are removed from this public frame.

`run_protocol()` accepts either an entirely unnamed variable list or an entirely
named one whose names exactly equal each `spec$name` in the same order. Canonical
names must be unique, and the returned result list is always named from
`spec$name`; an R binding such as `local_name <- variable_spec(name = "canonical",
...)` never changes the public identifier.

The audit contains a tidy `counts` table with output-grain keys plus `channel`,
`stage`, `unit`, and `n`. Its stages describe the following counts when the
corresponding executor emits them:

| `stage` | What `n` counts |
|---|---|
| `task_join` | source rows associated with the task by its relational keys |
| `window` | source rows remaining after the activation's time window |
| `selector` | rows matching the channel selector |
| `filter_rows` | rows surviving the row predicate |
| `filter_groups` | rows retained inside accepted groups |
| `model_input` | snippets supplied to the model |
| `output_input` | non-missing values supplied to the terminal reducer |

Stages are included only when that executor records a distinct count. Their
absence alone does not prove that an operation did not run; in particular, text
retrieval does not currently emit a separate `window` row.

`llm_calls` contains one row per task/channel model invocation, including model
configuration, call and processing outcomes, timing, prompt/schema/query
fingerprints, diagnostics, and the raw or partial response. A task that never
reaches the model, for example because it has no candidate, has no call row. The
`execution_manifest` is a resolved snapshot of what was configured and executed,
not a chronological activity log. Combination runs additionally keep `overlap`,
a tabular Venn/UpSet-style count of observed `TRUE`/`FALSE`/`NA` channel patterns,
and `combine_keys`, the key-level relation evaluated at `combine$by`, including
each channel's membership and the final `qualifies` decision. `overlap` is
computed from task-level hit patterns; it is not an aggregation of
`combine_keys`.

Executable and debugging details are explicitly separated under
`audit$internal` as `resolved_spec` and `channel_intermediates`. Printing
`audit$execution_manifest` gives a compact author-facing summary; its complete
resolved fields remain directly addressable for programmatic audit.

`bin_output(group_by = ...)` remains the output for source membership or a
combine result. A deterministic `method = "lucene"` activation never creates a
Chat.

## Development

```text
R CMD build .
R CMD check extractionengine_0.1.0.tar.gz
```

Before adding a model to the package approval list, run
`Rscript scripts/check_grammar_enforcement.R` against that model. The concise
package contract is in [DESIGN.md](DESIGN.md); the pre-package prototype remains
available at tag `checkpoint/pre-package-rebuild-2026-07-12`.
