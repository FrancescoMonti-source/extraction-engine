# Clean synthesis round

This is the shared implementation brief for Claude and Codex after the independent
smoking, retrieval, and transplant-anastomosis rounds.

It is not a generic variable-specification format and it does not replace
`DESIGN.md`. It freezes the lessons that must affect the next implementation so they
do not remain only review comments. Where this brief differs from older implementation
notes, it governs this synthesis round. After the two builds are compared and integrated,
the durable design documents will be reconciled once.

## Objective

Independently build a clean, owner-readable baseline that supports:

1. D0840 peri-operative smoking status;
2. D0840 recipient transplant anastomoses.

Reuse validated data artifacts, measurements, clinical contracts, and useful code.
Do not repeat historical experiments merely to recreate them. Neither existing branch
is the required starting architecture.

After the independent builds, Claude and Codex must perform one explicit integration
pass into a single baseline before starting another variable.

## Scope of the baseline

The baseline should contain only abstractions demonstrated by both real tasks:

- project adapters build task rows and exact eligible-document relations;
- one persisted canonical `tCorpus` is reused across variables;
- retrieval operates on a temporary `subset_meta(..., copy = TRUE)` containing the
  union of eligible documents;
- one variable-specific Lucene query runs on that subset;
- hits are joined back to exact task eligibility in R;
- only hit sentences and requested neighbours are reconstructed;
- task-specific ellmer builders define structured output;
- outputs are separated into coverage, values, evidence, and attempts;
- a review view joins those outputs for physician inspection.

Do not create an author-facing JSON specification, rule language, package API, or
generic derivation framework in this round.

## Tasks, anchors, and scope

`PATID` is expected in the current projects, but all other task metadata is
project-specific.

An anchor is a reference value used to interpret a task, commonly a date. It is not the
whole task identity and it does not imply temporal scoping.

Project adapters own task construction and scope:

- smoking: one recipient task around surgery, with the current D0840
  `[anchor - 365 days, anchor + 7 days]` document window;
- anastomoses: one recipient transplant-event task, scoped by exact
  `PATID + EVTID`; `DATEACTE` is retained as anchor metadata but does not define a
  fallback window.

The reusable retrieval layer consumes tasks and an already resolved
task-to-document eligibility relation. It must not know what a transplant, donor,
recipient, visit, or study-specific anchor means.

Every task declares an absence policy. `no_candidate` is an R-side coverage state,
never a clinical negative and never a model enum value.

## Evidence unit and provenance

The model-visible evidence unit is the exact assembled snippet supplied to the model:

```text
previous sentence [hit sentence] next sentence
```

No `AVANT` / `APRES` labels are added. Missing neighbours are simply omitted.

Each supplied snippet receives a short task-local `snippet_id` such as `S01`. That ID
identifies the complete assembled snippet, not only its middle sentence.

Durable provenance remains separate:

- `hit_ref`: native `ELTID::sentence` for the Lucene hit;
- `hit_text`: reconstructed hit sentence;
- `context_before` and `context_after`;
- `snippet_text`: the exact complete text shown to the model;
- document metadata including `ELTID`, date, and type where available.

This resolves the observed mismatch where a value came from a neighbouring sentence
but the returned reference appeared to cite only the uninformative middle sentence.

The physician review view may display the compact hit sentence by default, but the exact
model-visible snippet and `ELTID` must be available beside it. The physician must not
search hundreds of unrelated candidates to understand a submitted value.

## Evidence selection

The task prompt must say:

> For each field, cite the smallest sufficient evidence set. Prefer one snippet.
> Return several snippets only when each is necessary to support the value or decision.
> Do not cite related but non-supporting snippets.

Over-citation is primarily model behaviour, not a new clinical state. Record reference
counts and expose the cited material for review; do not build a complicated automatic
semantic judge in R.

The structured-output grammar already enforces everything it can express: value
types, the `status` enum, and snippet-ID membership in the supplied set (ollama
constrains sampling to the schema, so those cannot fail). R must not re-litigate them.

This holds **only for models that pass the grammar-enforcement gate**
(`scripts/check_grammar_enforcement.R`). Reasoning models such as `gpt-oss` and `gemma4`
emit unconstrained reasoning text that escapes the grammar and must not be used. Vet each
model once with the gate; do not re-validate types/enums per call. (This is why the dev
default is `gemma3:4b`, not `gpt-oss:20b` — the latter is both CUDA-unstable here and a
reasoning model the gate rejects.)

R validates only the CONDITIONAL, cross-field invariants the grammar cannot express:

- a `documented` field carries a usable value AND at least one snippet ID;
- an `unusable` field carries at least one snippet ID;
- the required summary is present.

These are general, not variable-specific. Do NOT add per-variable value checks (e.g.
"duration is a whole integer") -- that is the field type's job, already grammar-enforced.
At most one defensive guard may confirm the response parsed and conformed to the declared
schema, for backends that do not constrain sampling; that is a single check, not per-field
type/enum re-validation.

Separately, R MUST assert **pipeline/provenance integrity** — these check our own
deterministic transforms, not the model:

- every returned snippet ID resolves to exactly one stored snippet;
- no evidence is dropped or duplicated across joins;
- every review row contains only its own field's evidence.

(The grammar gate only proved prose-escape on a trivial `{string, number}` schema, so it
never proved dynamic-enum enforcement; "resolves to exactly one snippet" is the cheap
backstop. The recent field/evidence data-masking bug is exactly what these catch.)

The physician decides whether the evidence clinically supports the value.

## Structured output and nulls

Use ellmer type builders by default. Raw JSON Schema remains an escape hatch only for a
tested constraint unavailable through the builders.

### A growing library of response types

In ellmer terminology, `type_object()` describes one complete structured model response.
In ordinary R terms, it describes the shape of a named `list`. It does **not** necessarily
mean one clinical variable.

For example:

```r
type_object(
  smoking_status = type_enum(c(
    "actif",
    "sevre",
    "non_fumeur",
    "indetermine"
  )),
  evidence_ids = type_array(type_enum(snippet_ids)),
  decision_note = type_string()
)
```

describes one response shaped like:

```r
list(
  smoking_status = "sevre",
  evidence_ids = c("S02", "S05"),
  decision_note = "Two supplied snippets document cessation."
)
```

R may subsequently store these elements in different tables. Being returned in one
object does not mean that the value and evidence occupy one dataframe cell.

One outer `type_object()` may contain several clinical variables from the same call.
A nested `type_object()` is useful when one variable has several components:

```r
type_object(
  arterial_duration = type_object(
    status = type_enum(c(
      "documented",
      "not_documented",
      "unusable"
    )),
    value = type_integer(required = FALSE),
    evidence_ids = type_array(type_enum(snippet_ids))
  ),
  arterial_location = type_object(
    status = type_enum(c(
      "documented",
      "not_documented",
      "unusable"
    )),
    value = type_string(required = FALSE),
    evidence_ids = type_array(type_enum(snippet_ids))
  ),
  summary = type_string()
)
```

Mental translation:

```text
type_object()  -> named R list
type_array()   -> R vector
type_string()  -> length-one character value
type_integer() -> length-one integer value
```

Build a library that grows with real use cases:

```text
R/types/
  smoking.R
  anastomoses.R
  dialysis.R
```

Entries whose shape is completely fixed may be stored as type objects. Entries containing
task-specific values—especially the legal `snippet_ids`—must be builder functions such as
`type_smoking(snippet_ids)` that return a fresh type object for that task.

Start with explicit, understandable task builders. Only after several real tasks repeat
the same nested pattern should that pattern be extracted into a shared helper such as an
evidenced-field builder. This is a composable response-type library, not a generic schema
language or a variable-specification framework.

For fields with partial missingness, use an explicit status:

- `documented`: a usable value is present and at least one evidence ID is required;
- `not_documented`: no usable statement is present and evidence may be empty;
- `unusable`: relevant information is explicit but cannot be converted under the task
  rules; at least one evidence ID is required.

Status is authoritative. Some structured-output backends populate optional scalar
properties with placeholders such as integer `0`; R discards those values when status
is not `documented`.

The current smoking and anastomosis clinical meanings and value vocabularies remain the
ones recorded in `DESIGN.md` and the ratified anastomosis HANDOFF contract.

For multi-field extraction, `transplantation_resume_anastomoses` is required. It must be
brief, remain consistent with the structured fields, and must not introduce a value that
the structured fields omit. Its evidence is the deterministic union of field-level
evidence.

## Operational states

Do not call every successful model response “valid.” Keep distinct concepts:

- `attempt_status`: provider call completed or failed;
- `structural_validity`: BINARY per field -- the response satisfied the conditional
  contract (`valid`) or did not (`invalid`), with a granular reason message. There is no
  separate "requires review" structural state: once the grammar guarantees type/enum
  conformance, the only mechanical failures are ungrounded or inconsistent fields, and an
  ungrounded value must never enter the analytical dataset as an accepted value (it still
  appears in the review/debug output with its reason). The boundary is "is this field safe
  to accept as a cohort value?"; `documented`-without-evidence is therefore `invalid`, not
  a soft flag;
- `coverage_state`: candidate availability and other pre-model pipeline states;
- `review_decision`: later physician acceptance or rejection.

A structurally valid response is not a clinically correct response.

Validity exists at two levels: per-field validity, and task validity derived from all
fields plus required-summary PRESENCE. Summary *consistency* with the fields stays a
physician judgment unless we later define deterministic checks; only presence is mechanical.

Use a fresh chat per task. Record model, attempt count, latency, error, and retry
outcome. A small bounded retry with backoff is appropriate only for transient
local-provider failures (`attempt_status`). It is NOT appropriate for `structural_validity
== invalid`: under `temperature = 0` and a fixed seed the call is deterministic, so a
retry reproduces the same output. Invalid -> excluded from accepted cohort values but
RETAINED in the review/debug output with its reason (never silently dropped, or no one can
diagnose it); valid -> physician review.

## Review output

Produce a physician-oriented flat view with one row per task and clinical field:

```text
task identifiers
field
value
status
required task summary or decision note
structural validity and reason
cited snippet IDs
compact hit sentence
exact model-visible snippet
ELTID / native hit reference
review_decision
review_note
```

The canonical storage remains coverage, values, evidence, and attempts; the flat table
is a review view.

## Privacy and local artifacts

Read only required columns from files containing direct identifiers. Selecting safe
columns after loading the complete workbook does not satisfy this rule.

Patient text, model responses, review workbooks, cached corpora, and other derived
clinical artifacts remain outside version control. Console output is aggregate-only.

## Testing discipline

During the independent builds, write exactly FOUR black-box contract tests. They pin the
shared OBSERVABLE contract (not helper organization), so the two implementations cannot
silently encode different contracts and then be compared invalidly:

- exact task/document scoping;
- a snippet ID maps to the exact model-visible snippet it was given;
- `no_candidate` skips the model;
- a field's review row contains only that field's evidence.

These are black-box (fixture in, behaviour out), so they survive refactors and lock the
contract, not the interface. Test nothing else during the independent builds; validate the
rest by small real-data sample runs and aggregate inspection.

Defer the remaining set until AFTER the two builds are integrated into the single baseline.
Then add a deliberately small set pinning other high-risk, durable behaviour:

- privacy-safe input loading;
- the conditional documented/unusable evidence rules;
- backend placeholder values are discarded;
- pipeline/provenance integrity (IDs resolve once; no evidence lost in joins).

Do not pin type/enum conformance the grammar already guarantees (e.g. unknown evidence
IDs cannot occur under a schema-honouring backend), and do not build a large suite around
helper names or implementation details still expected to change.

## Verification and convergence

Each implementation should first run on small representative smoking and anastomosis
samples. Compare:

- scope and candidate sets;
- exact text shown to the model;
- output and evidence contracts;
- review usability;
- failure handling, retries, and runtime;
- simplicity and the human owner's ability to understand the code.

There is no adjudicated gold, so real-data differences are findings for review, not
accuracy claims.

Do not run both independent implementations over the complete cohort merely for
symmetry. After comparison, integrate the chosen pieces into one baseline, test that
baseline, and perform the next full run only there.
