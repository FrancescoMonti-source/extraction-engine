# extraction-engine — Design

> Status: Phase 0 is in progress. The name is temporary.

## What we are building

This project turns clinical records into analytical variables for cohort studies.

Inputs may include:

- clinical text;
- ICD-10 diagnoses;
- CCAM procedures;
- laboratory results.

Outputs are tidy cohort variables with enough provenance for a clinician to inspect
what supported each result.

The project is local-first because sensitive text may need to stay inside the
hospital. Local models are weaker than hosted models, so auditability and evaluation
are core requirements rather than optional extras.

## What we are not building

We are not rebuilding an LLM client.

[ellmer](https://ellmer.tidyverse.org/) handles providers, structured-output calls,
and JSON-to-R conversion. This project handles the clinical workflow around those
calls:

- which records matter;
- which dates matter;
- how sources are combined;
- what evidence supports a result;
- how results are reviewed and evaluated.

## The workflow

For each observed variable:

1. Resolve the patient's anchor date **if the variable is time-relative** — such as the
   first DMO examination or a transplant date. **Some variables have no anchor:** they
   cover the whole patient history (e.g. "ever smoked", "any history of cardiac
   surgery").
2. Keep records inside the relevant scope — the previous year, the same hospital stay,
   ±30 days, or **the entire history** when the variable is "ever".
3. Extract source-backed observations from codes, labs, procedures, or text.
4. Apply a named R policy to produce the analytical value.
5. Save the value with links to the observations that support it.

Afterward, ordinary project R computes derived columns such as deltas and change
indicators.

```text
records
  → anchor (optional) and scope
  → source observations
  → analytical value
  → ordinary R derivations
```

## Worked example: smoking status before surgery

Suppose a patient has many dated documents mentioning smoking. We never ask the model
for "never / former / current" — that conflates a *recent* question with a *lifetime*
one and lets a windowed answer overclaim. Instead the model answers **scope-bounded
yes/no** questions, and R composes the clinical category.

### 1. R prepares the candidates

R scopes, deduplicates, numbers the snippets, and keeps their provenance (document,
event, date, target role):

```text
S01 | 2024-01-10 | Tabagisme actif à dix cigarettes par jour.
S02 | 2025-03-04 | Patient sevré du tabac depuis six mois.
S03 | 2025-03-04 | Son conjoint est fumeur.
```

### 2. Two scope-bounded calls

Each is one bundled call over its own scope, asking for
`yes / no / uncertain / not_stated` and returning evidence references restricted to
the supplied ids plus a short decision note:

```text
currently_smoking  (window before surgery) → value: no,  evidence: [S02], note: "Most recent statement reports cessation."
ever_smoked        (whole history)         → value: yes, evidence: [S01, S02], note: "Active smoking followed by cessation."
```

The model cannot return an id outside the supplied set, never copies a quotation, and
never asserts more than its scope shows. Multiple ids can expose conflicting or
longitudinal evidence to the physician. The decision note explains the model's handling
of that evidence but does not replace it. (S03, about the spouse, is correctly ignored.)

### 3. R derives the clinical category

```r
smoking_status <- dplyr::case_when(
  currently_smoking == "yes" ~ "current",
  ever_smoked       == "yes" ~ "former",   # smoked before, not now
  ever_smoked       == "no"  ~ "never",    # "no" over ALL history = never, as far as records show
  TRUE                       ~ "not_stated"
)
# -> "former"
```

`smoking_status` is a **derived** column (plain R); only `currently_smoking` and
`ever_smoked` are observed tasks. A scoped `no`/`never` always means "no documented
evidence, as far as retrieval found" — an *evidence-absent* claim, weaker than an
*evidence-positive* `yes`, and audited via candidate recall. R verifies each
evidence reference mechanically and resolves it to the original snippet; the physician,
not R, judges whether the evidence and decision are appropriate.

## The three tables

The implementation keeps three concepts separate.

### Attempt

What happened when a model was called:

```text
model, prompt/schema version, status or error, latency
```

A failed call still creates an attempt row.

### Hit

What one source reported:

```text
patient, variable, value, source record, dates, evidence id
```

ICD codes, procedures, labs, and text all become hits with the same general shape.

### Value

What the engine retained for analysis:

```text
patient, variable, timepoint, value, selected hit ids, validity/review state
```

Keeping these tables separate makes failures, conflicting sources, and provenance
representable without stuffing everything into one wide or heavily nullable table.

## Variable definitions

Only extraction tasks that read from records need an engine definition. A definition
answers four questions:

1. **Anchor:** relative to which patient event — **or none**, for a whole-history
   ("ever") variable?
2. **Scope:** which dates, stays, or events are eligible (possibly the entire history)?
3. **Sources:** text, diagnoses, procedures, labs, or a combination?
4. **Policy:** how are eligible observations converted into one value?

The exact author-facing representation is deliberately undecided. We will implement
the smoking workflow directly, then use a second real variable to determine which
parts deserve configuration. We are not committing yet to JSON files, a shared
variable-spec schema, or a catalogue layout.

One extraction task may produce several related observations. The output contract
therefore belongs to the task, not necessarily to each final cohort column. D0840's
anastomosis task, for example, extracts several durations, techniques, and locations
from the same operative context.

Two operational concepts remain separate regardless of the eventual representation:

- **retrieval configuration** finds candidate records; the model never sees the query;
- the model's **output JSON Schema** constrains the result returned through ellmer.

For smoking, the observed tasks emit scope-bounded values such as
`currently_smoking_pre_surgery` and `ever_smoked`. The lifetime category
`smoking_status` is then derived in ordinary R. It has no engine definition of its own.

## Source adapters and construction policies

Each source adapter converts raw records into hits:

- ICD-10 diagnoses;
- CCAM procedures;
- laboratory measurements;
- LLM-assisted text extraction.

Named R policies then convert eligible hits into values. Initial policies are based
on real D0740 and D0840 logic:

- use the only valid observation directly;
- any positive observation;
- nearest, first, or last observation;
- ranked selection with explicit tie-breakers;
- counts or count-distinct thresholds;
- source precedence and conflict reconciliation;
- collection of multiple values.

This is a small registry of tested functions, not a rule language. If a calculation
is straightforward project logic, it remains straightforward R.

## Derived columns stay as R

No derivation framework is planned.

```r
features$poids_delta <- features$poids_t1 - features$poids_t0
features$tabac_changed <- features$tabac_t0 != features$tabac_t1
```

There is no derived-variable spec or interpreted expression language.

## Reliability rules

- Structured decoding guarantees output shape, not clinical correctness.
- Every candidate model must pass a grammar-enforcement test
  ([`scripts/check_grammar_enforcement.R`](scripts/check_grammar_enforcement.R)).
- Provider parameters must be verified to have taken effect.
- Model and prompt failures are recorded.
- Partial clinical output is never silently repaired; extraction fails closed.
- **No candidates after retrieval and scoping is `missing` with a recorded reason
  (`no_candidate`), never silently `never`/`not_stated`.** A query or scope miss must
  not be allowed to look like a clinical fact; the abstention rate is monitored and a
  sample audited.
- **Extracted values are scope-bounded, not lifetime claims.** The model emits
  `yes`/`no`/`not_stated` ("is there evidence in *this* scope?"), never a value like
  `never` that asserts beyond the window. Lifetime/temporal categories
  (never / former / current) are **derived in R**, sound only because R knows each scope.
  A `no`/`never` means "no documented evidence, as far as retrieval found" —
  evidence-absent and recall-bounded, so weaker than an evidence-positive `yes`.
- **Every snippet carries its target role** (e.g. donor vs recipient); R filters to the
  target person *before* the model sees it, so the model never has to infer whose record
  it is reading.
- Evidence is selected by id and materialized from stored source text.
- Retrieval recall and model accuracy are evaluated separately.
- Clinical data and model outputs containing clinical text stay outside the
  repository.

Model names, benchmark results, provider quirks, and debugging history are
configuration and implementation detail. They live in
[`TECHNICAL_NOTES.md`](TECHNICAL_NOTES.md) and [`HANDOFF.md`](HANDOFF.md), not in
this design.

## Review and evaluation

The engine must remain useful when no gold labels exist:

1. produce a value with source-backed evidence;
2. export a review-ready table;
3. let the reviewer agree or correct the value;
4. preserve reviewed rows as gold;
5. evaluate models and retrieval as gold accumulates.

Evaluation separates:

- retrieval: did the relevant record enter the candidate set?
- extraction: was the returned value correct?
- grounding: was the correct evidence snippet selected?
- operations: did the call fail, retry, or run slowly?

## Build plan

### Phase 0 — smoking spike

Current work:

- restructure the existing smoking input into numbered, dated snippets;
- return a scope-bounded value, `evidence_ids`, and a concise `decision_note`;
- add synthetic negation, contradiction, and abstention fixtures;
- adjudicate a frozen smoking sample;
- measure accuracy, grounding, failures, and latency.

The goal is to test the contract and determine whether bundled extraction is good
enough. Per-snippet calls are added only if the results justify their cost.

### Phase 1 — prove the reusable core

Implement the attempt, hit, and value tables plus the minimum adapters and policies
needed for two different D0840 task shapes:

- smoking status, for longitudinal text and conflicting evidence;
- transplant anastomoses, for several related fields and partial missingness.

Then use dialysis as the multi-source stress test: text observations are reconciled
with CCAM and pre-emptive status in explicit R.

### Phase 2 — generalize from evidence

Generalize anchor resolvers, scopes, adapters, and policies only where the two real
variables demonstrate repetition.

### Later

Add richer review tooling or extract a package only after the application has proved
the abstractions. An xlsx review round-trip is sufficient initially.

## Decisions we should protect

- ellmer handles LLM transport.
- This project owns clinical extraction, time, provenance, construction, and eval.
- The hit is the common shape between sources and policies.
- Evidence is referenced by snippet id rather than generated as text.
- One bundled call is the default; more calls require measured justification.
- Derived variables are ordinary R.
- Reusable configuration should select bounded, tested functions rather than form a
  DSL; its exact authoring format is deferred.
- Retrieval configuration and the model's output JSON Schema stay separate.
- Not every variable has a time anchor; whole-history ("ever") variables are
  first-class, not an afterthought.
- Extracted values describe their scope (`yes`/`no`), never all time; lifetime
  categories (`never`/`former`/`current`) are derived in R, and a `no`/`never` is
  always "as far as the records show".
- Build the application first and package it later.

## Open questions

- After two real variables, which parts of their workflow should become configuration?
- Which second variable best tests the architecture after smoking?
- What should the project be called?
