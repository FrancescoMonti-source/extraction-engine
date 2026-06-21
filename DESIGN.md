# extraction-engine — Design

> Status: active development on D0840. Smoking spikes are complete; anastomoses and
> biology are next. The name is temporary.

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

1. A project adapter creates a task table: who the task concerns, its optional anchor,
   and any project-specific context. The engine does not know how a transplant,
   consultation, or study visit was identified.
2. Resolve the eligible records for all tasks — the previous year, the same hospital
   stay, ±30 days, or **the entire history** when the variable is "ever".
3. Retrieve source-backed observations from codes, labs, procedures, or text.
4. Apply a task-specific extractor or named R policy.
5. Save the value with native source references and enough coverage information to
   explain missing results.

Afterward, ordinary project R computes derived columns such as deltas and change
indicators.

```text
records
  → project task table (optional anchor)
  → scope
  → source observations
  → analytical value
  → ordinary R derivations
```

For text, one canonical persisted corpus is built per document collection and reused
across variables. Each variable computes the union of documents eligible for its tasks,
temporarily subsets the canonical corpus without mutating it, runs one retrieval query,
then joins hits back to each task's exact scope.

## Worked example: smoking status around surgery

Suppose the analytical variable is `smoking_status_periop` (≙ D0840's `tabac_statut`):
the smoking status documented around surgery. Its definition—not the model—sets the
horizon. We adopt D0840's task vocabulary so the new results can be reviewed alongside
the legacy outputs; D0840 does not currently provide adjudicated gold labels.

```text
anchor:       surgery date
source scope: documents recorded in [anchor - 365 days, anchor + 7 days]
meaning:      smoking status documented around surgery
values:       actif / sevre / non_fumeur / indetermine
absence:      open world — no candidate does not imply non_fumeur
```

This is one observed extraction task. We do not combine a current-status task with a
separate whole-history task.

### 1. R retrieves citable evidence

The project adapter supplies patient/transplant tasks. R computes the union of eligible
documents, temporarily subsets the canonical corpus, runs the smoking Lucene query once,
and joins sentence hits back to each task's exact window.

The citable unit is the hit sentence. Its native reference is stable within the
canonical corpus; neighbouring sentences provide context but are not independently
citable unless they are themselves hits:

```text
context:                  Habitus :
104::42 | 2025-02-20 | Ancien fumeur, sevré depuis 2010.
context:                  Arrêt confirmé en consultation.

287::7  | 2025-03-04 | Tabac : sevré.
319::12 | 2025-03-04 | Son conjoint est fumeur.
```

An in-scope note may summarize older history. “Sevré depuis 2010” legitimately supports
`sevre` because it is an in-scope assessment recorded inside the peri-operative source
scope. The engine does not need to retrieve records from 2010 to construct another
variable.

Literal copy-forward sentences are deduplicated within each task using a deterministic
tie-break, while duplicate source references and dates remain available for audit.

### 2. One task-specific call

The bundled call returns the requested status, evidence references restricted to the
supplied native references, and an optional decision note:

```text
smoking_status_periop → value: sevre, evidence: [104::42, 287::7],
                        note: "Both peri-operative notes describe smoking cessation."
```

The model cannot return a reference outside the supplied set, never copies a quotation,
and never asserts more than its scope shows. Multiple references can expose conflicting or
longitudinal evidence to the physician. The decision note explains the model's handling
of that evidence but does not replace it. (The spouse sentence is correctly ignored.)

The states are distinct (matching D0840's `tabac_statut`):

- `actif`: an in-scope record describes current smoking;
- `sevre`: an in-scope record describes former smoking or cessation;
- `non_fumeur`: an in-scope record documents the patient as a non-smoker (D0840 lumps
  "non-fumeur", "jamais fumé", and "absence de tabagisme" here, without claiming whether
  the patient smoked earlier in life — it is not upgraded to a lifetime "never");
- `indetermine`: relevant in-scope evidence is contradictory or insufficient;

`no_candidate` is not a model value. It is a coverage state used when no eligible
candidate exists and no model call is made.

Separating `indetermine` into distinct conflicting (`uncertain`) vs silent (`not_stated`)
states, or adding a stronger lifetime `never`, are deferred refinements that would each
require reviewed labels that encode the distinction.

R stores the returned status directly, resolves each evidence reference to the original
sentence and document, and prepares the review view. The physician—not R—judges whether the evidence
and decision are appropriate.

## The four operational tables

The current working contract keeps four concepts separate. These are operational views,
not a claim that every source must share one universal internal row shape.

### Coverage

Which tasks were expected and whether evidence was available:

```text
task id, subject, anchor/context, eligible document count, candidate count,
processing state
```

Coverage includes tasks with no candidates. This distinguishes “nothing retrieved”
from “not processed” without turning absence into a clinical value.

### Attempt

What happened when a model was called:

```text
model, prompt/schema version, status or error, latency
```

A failed call still creates an attempt row.

### Value

What the extractor returned for a modelled task:

```text
task id, variable, value, validity/review state, evidence references,
decision note
```

Invalid or review-required responses are retained for diagnosis but cannot silently
become cohort values.

### Evidence

One row per cited source reference:

```text
task id, evidence reference, source record, source date, hit text, surrounding context
```

Structured sources may later expose additional observation tables where that helps their
construction policies. They do not need to imitate text retrieval artificially.

## Variable definitions

Only extraction tasks that read from records need an engine definition. A definition
answers five questions:

1. **Anchor:** relative to which patient event — **or none**, for a whole-history
   ("ever") variable?
2. **Scope:** which dates, stays, or events are eligible (possibly the entire history)?
3. **Sources:** text, diagnoses, procedures, labs, or a combination?
4. **Policy:** how are eligible observations converted into one value?
5. **Absence policy:** what, if anything, may be concluded when no eligible positive
   evidence is found, given the coverage and failure modes of each source?

The exact author-facing representation is deliberately undecided. We will implement
multiple real variables independently, then determine which parts deserve
configuration. We are not committing yet to JSON files, a shared
variable-spec schema, or a catalogue layout.

At runtime, the generic engine consumes a task table with stable engine-facing columns
such as:

```text
task_id, PATID, anchor_date
```

`anchor_date` may be missing for whole-history tasks. Project adapters may attach any
additional metadata needed by the extractor. They own source-specific columns such as
`DATEACTE`, donor/recipient pairing, visit identifiers, or study timepoints.

One extraction task may produce several related observations. The output contract
therefore belongs to the task, not necessarily to each final cohort column. D0840's
anastomosis task, for example, extracts several durations, techniques, and locations
from the same operative context.

Two operational concepts remain separate regardless of the eventual representation:

- **retrieval configuration** finds candidate records; the model never sees the query;
- the model's **output JSON Schema** constrains the result returned through ellmer.

For smoking, `smoking_status_periop` is one observed task whose definition records the
surgery anchor, the `[anchor − 365 days, anchor + 7 days]` source scope, and the meaning
of its categorical values. A
different question such as “ever smoked anywhere in the available record” would be a
different variable with a whole-history scope.

Text tasks can therefore use two distinct modes:

- **documented-status transcription:** an eligible record already states the clinical
  category, so the model returns that category directly;
- **derived synthesis:** no single documented status answers the question, so the
  engine extracts independently meaningful observations and ordinary R combines them.

Choose the mode per variable. `smoking_status_periop` uses documented-status
transcription; a future variable reconstructing lifetime smoking history from scattered
events could use derived synthesis.

## Source adapters and construction policies

Each source adapter converts raw records into source-backed observations:

- ICD-10 diagnoses;
- CCAM procedures;
- laboratory measurements;
- LLM-assisted text extraction.

Named R policies then convert eligible observations into values. Initial policies are based
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
- Partial clinical output is never silently repaired. Raw responses remain available
  for diagnosis, but invalid or review-required responses cannot silently become cohort
  values.
- **No candidates after retrieval and scoping is recorded in coverage as
  `no_candidate`; no model call or value row is created.** Joining values back to the
  cohort naturally produces `NA`. This is a pipeline fact, not a clinical negative. The task's
  declared absence policy determines whether downstream construction leaves it missing,
  reports `no_documented_evidence`, or—only under an explicit closed-world rule with
  adequate source coverage—constructs a negative value. The original `no_candidate`
  state remains auditable.
- **Every value is interpreted through its declared anchor, source scope, and meaning.**
  The model may return `actif`, `sevre`, or `non_fumeur` for `smoking_status_periop` only
  when an eligible in-scope record explicitly supports that status. Absence of a smoking
  statement is never converted into `non_fumeur`: no eligible candidate is `no_candidate`
  (R-side), while contradictory or insufficient supplied material is `indetermine`.
- **Every evidence unit carries its target context** (e.g. donor vs recipient); R filters to the
  target person *before* the model sees it, so the model never has to infer whose record
  it is reading.
- Evidence is selected by native source reference when available and materialized from
  stored source text.
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

D0840 currently has no adjudicated smoking gold. Initial labels will be created by the
physician reviewing the model value, decision note, and materialized source evidence.
Those posterior reviews are useful for corrections and future regression tests, but
they are not an independent accuracy estimate for the same run that produced the
suggested answers.

Evaluation separates:

- retrieval: did the relevant record enter the candidate set?
- extraction: was the returned value correct?
- grounding: was the correct evidence reference selected?
- operations: did the call fail, retry, or run slowly?

## Build plan

### D0840 as the development corpus

D0840 is the main development corpus because it contains several genuinely different
task shapes in one completed project. We are not fine-tuning a model on it. We are using
it to develop prompts, output contracts, R policies, review tables, and evaluation
methods.

The representative sequence is:

1. smoking — longitudinal text, contradictions, evidence references, and a decision note;
2. transplant anastomoses — several related outputs with partial missingness;
3. biology timepoints — deterministic anchor-relative ranking without an LLM;
4. dialysis — explicit reconciliation of text, CCAM, and pre-emptive status in R;
5. delayed graft function and surgical antecedents — conflict routing and whole-history
   multi-category extraction.

Cases are split by patient or transplant pair—not by snippet—into development,
validation, and held-out sets. Development cases may be inspected while prompts and code
change. Validation cases choose among competing approaches. The held-out set is opened
only after the approach is fixed, so it remains a credible estimate of performance.

### Completed smoking rounds

Independent smoking implementations established the task contract, native evidence by
reference, bundled structured extraction, and the difference between clinical values
and coverage states.

Independent retrieval implementations then established:

- one canonical corpus per document collection;
- persistence and reload rather than retokenization per variable;
- temporary metadata subsetting to the union of eligible documents;
- one query followed by an exact task-window join;
- hit-sentence evidence with configurable neighbouring-sentence context;
- deterministic copy-forward deduplication.

### Next independent rounds

Claude and Codex continue implementing the same real variables independently before
reviewing each other's code:

1. transplant anastomoses — several related outputs, shared operative evidence, and
   partial missingness;
2. biology timepoints — deterministic structured-source selection around anchors.

Dialysis remains the later multi-source stress test. Only repetition demonstrated across
these implementations should become shared configuration or a reusable package core.

### Later

Add richer review tooling or extract a package only after the application has proved
the abstractions. An xlsx review round-trip is sufficient initially.

## Decisions we should protect

- ellmer handles LLM transport.
- This project owns clinical extraction, time, provenance, construction, and eval.
- A project adapter builds generic engine tasks; the engine does not construct
  transplant-, visit-, or study-specific anchors.
- Text collections use one persisted canonical corpus, temporarily subset to the union
  of eligible documents before each query.
- Evidence is referenced by native source coordinates where available rather than
  generated as text.
- One bundled call is the default; more calls require measured justification.
- Derived variables are ordinary R.
- Reusable configuration should select bounded, tested functions rather than form a
  DSL; its exact authoring format is deferred.
- Retrieval configuration and the model's output JSON Schema stay separate.
- Not every variable has a time anchor; whole-history ("ever") variables are
  first-class, not an afterthought.
- Every extracted value has a declared source scope and meaning. Do not combine
  mismatched horizons to manufacture a category; extract the requested status directly
  when eligible records state it.
- Every extraction task declares an absence policy. Open-world is the default: missing
  evidence does not prove absence of disease or exposure.
- Distinguish documented-status transcription from derived synthesis; choose the mode
  per variable rather than imposing either mode universally.
- Build the application first and package it later.

## Open questions

- After several independent variable rounds, which repeated parts should become
  configuration?
- What should the project be called?
