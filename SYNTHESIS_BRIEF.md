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

R validates only mechanical claims:

- returned snippet IDs were supplied for that task;
- required evidence is present;
- IDs resolve to stored provenance;
- output shape and status/value rules are respected.

The physician decides whether the evidence clinically supports the value.

## Structured output and nulls

Use ellmer type builders by default. Raw JSON Schema remains an escape hatch only for a
tested constraint unavailable through the builders.

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
- `structural_validity`: response obeyed the mechanical contract, requires review, or
  is invalid;
- `coverage_state`: candidate availability and other pre-model pipeline states;
- `review_decision`: later physician acceptance or rejection.

A structurally valid response is not a clinically correct response.

Use a fresh chat per task. Record model, attempt count, latency, error, and retry
outcome. A small bounded retry with backoff is appropriate for transient local-provider
failures.

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

Tests are deliberately small. Pin high-risk behaviour, not temporary organization:

- exact patient/event or patient/window scoping;
- privacy-safe input loading;
- stable snippet-ID-to-provenance mapping;
- `no_candidate` skips the model;
- documented/null/unusable status rules;
- backend placeholder values are discarded;
- unknown evidence IDs cannot become evidence;
- review rows place each field beside only its own cited evidence.

Do not build a large suite around helper names or implementation details that are still
expected to change.

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
