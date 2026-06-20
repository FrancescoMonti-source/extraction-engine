# extraction-engine — Technical notes

This document holds implementation detail, experimental findings, and the rationale
behind the shorter owner-facing [`DESIGN.md`](DESIGN.md). It is useful when building
or debugging the engine; it is not required to understand the product.

For the chronological discussion and raw experiment log, see [`HANDOFF.md`](HANDOFF.md).

## 1. Boundary with ellmer

ellmer owns:

- provider clients and authentication;
- structured-output calls;
- JSON-to-R conversion;
- parallel request machinery;
- common request and token plumbing.

This project owns:

- clinical variable definitions;
- anchor and scope resolution;
- retrieval and source adapters;
- prompts and JSON Schemas;
- construction policies;
- attempts, evidence, and provenance;
- review and evaluation.

Phase 0 keeps retrieval configuration and the model's output type separate:
the model never sees the corpustools query, and the output type is built in R with
ellmer's **type builders** (`type_object()` / `type_enum()` / `type_array()`) by
default. Raw JSON Schema is reserved for tested constraints unavailable through the
builders (see "Schema construction" below). The eventual author-facing
variable-definition format is deliberately deferred until the workflow has been
exercised on real variables.

Raw Ollama is an escape hatch for a measured capability gap, not a parallel engine
to maintain from the beginning.

### Schema construction: builders by default, `type_from_schema()` as escape hatch

We build output types with ellmer's `type_*()` builders **by default**, and fall back
to raw JSON Schema via `type_from_schema()` only for a tested constraint the builders
cannot express. Two findings explain why builders are the default, both verified in
ellmer 0.4.1:

1. **It does not validate the schema — only the JSON.** `type_from_schema()` runs
   `jsonlite::fromJSON()` (so a malformed *string* fails loudly), then stores the
   parsed list in an opaque `TypeJsonSchema` and sends it to the provider verbatim
   (`as_json` returns `x@json` untouched). Anything that is valid JSON but a broken
   *schema* — `{"type":"banana"}`, an `"enam"` typo that silently drops an `enum`
   constraint, an object with no `properties` — passes through with no error and fails
   late (wrong values) or only at a strict provider. There is a JSON-syntax net but no
   schema-semantics net.

2. **It bypasses ellmer's typed JSON→R conversion.** Conversion is done by
   `convert_from_type(x, type)`, which dispatches on the **S7 class of the type
   object** (`TypeArray` / `TypeObject` / `TypeBasic` / `TypeEnum`). The tibble
   conversion fires only for `TypeArray` whose `items` is a `TypeObject`. A
   `TypeJsonSchema` matches none of these classes and hits the final `else { x }`, so
   it returns the **raw parsed structure unchanged** (e.g. an array-of-objects comes
   back as a list of named lists, *not* a tibble). The builder path
   (`type_array(type_object(...))`) is what drives typed columns and the tibble.

Builders are also favoured by the contract itself: `evidence_ids =
type_array(type_enum(snippet_ids))` carries a **dynamic enum** whose legal ids depend
on how many snippets *that* patient produced, so the type is rebuilt per call
(`type_enum(candidate$snippet_id)`) — natural with builders, clumsy as templated JSON.
Builders also fail loudly on a typo at construction time. (A per-patient dynamic enum
means the type is patient-specific, so it cannot be shared across prompts in one
`parallel_chat_structured()` call — see §4 on batching; the trade-off is separate
patient-specific calls vs. a fixed `S01…Sn` vocabulary with unused ids rejected in R.)

**The escape hatch is a real capability gap, not just portable storage.** The builders
expose only `description` / `required` (`type_string`) and `items` / `description` /
`required` (`type_array`) — there is **no `maxLength`, no `maxItems`** (passing them
errors), and the emitted JSON carries no size keyword. We have **measured** that a raw
`maxLength` *is* enforced through the Ollama schema→GBNF path (Handoff #3), so a bounded
`decision_note` or a small-`maxItems` `evidence_ids` is expressible **only** via
`type_from_schema()`. So the rule is: **builders by default** (readable, valid by
construction, typed conversion); **`type_from_schema()` as a narrow escape hatch** when a
required, tested JSON-Schema constraint is unavailable through the builders. Schemas as
external/portable data remains a separate, deferred question.

An output type belongs to an **extraction task**, not necessarily to one final cohort
column. Smoking may return a scope-bounded value, several evidence references, and a
decision note. An anastomosis task may return several related durations, techniques,
and locations. Dialysis text extraction produces observations that R later reconciles
with CCAM and pre-emptive status. There is therefore no universal output object; each
task gets one explicit, readable contract.

## 2. Data contracts

The workflow uses three linked tables rather than one overloaded result table.

### Attempts

One row per model execution, including failures:

```text
attempt_id
task_id
subject_id
timepoint_id
provider
model
schema_version
prompt_version
started_at
latency_ms
status
error
```

Phase 0 records this minimal set. Token counts, retry chains, and complete input
lineage can be added when they become useful.

### Hits

One row per source-backed observation:

```text
hit_id
subject_id
variable_id
value
unit
source
source_record_id
source_event_id
recorded_at
effective_at
evidence_id
attempt_id
```

`recorded_at` and `effective_at` are distinct because a recent note can describe a
remote historical event.

Structured sources such as ICD-10, CCAM, and labs create hits deterministically.
A bundled text extraction may create one text hit for a subject/timepoint, supported
by one or more supplied snippet ids.

### Values

One row per constructed analytical decision:

```text
subject_id
variable_id
timepoint_id
value
unit
selected_hit_ids
n_candidates
policy
policy_version
.valid
.failure
review_status
```

A flat review table is a view produced by joining values to selected hits and their
source snippets. It is not the canonical storage contract.

## 3. Evidence by reference

The model does not generate an evidence quote. Candidate snippets are assigned stable
ids and supplied with dates and source identifiers:

```text
S01 | 2024-01-10 | document 104 | Tabagisme actif à dix cigarettes par jour.
S02 | 2025-03-04 | document 287 | Patient sevré du tabac depuis six mois.
```

The output type contains a dynamic enum. The value is **scope-bounded**
(`yes`/`no`/`uncertain`/`not_stated`), not a lifetime category — see §6:

```json
{
  "value": "no",
  "evidence_ids": ["S02"],
  "decision_note": "The most recent preoperative statement reports smoking cessation."
}
```

The allowed evidence values are the supplied snippet ids. Client code resolves each
id to the complete stored snippet. The decision note is a concise explanation of how
the model handled the supplied evidence; it is not itself evidence.

This avoids:

- fabricated or paraphrased quotations;
- unbounded evidence strings and output overflow;
- character-offset counting;
- mid-word truncation;
- ambiguity when several snippets share a date.

For genuinely multi-span evidence, return an array of supplied ids with a small
`maxItems`. A free-text evidence field with `maxLength` is only a fallback for a
source that cannot provide stable snippet ids.

## 4. Text-call granularity

The Phase 0 default is one bundled call per extraction task, subject, and timepoint:

1. R resolves the anchor, filters the scope, and **filters to the target role** (e.g.
   recipient, not donor) so the model never has to infer whose record it is reading.
2. R **deduplicates copy-forward snippets**, then orders and numbers the candidates.
3. **If no candidates remain, the value is `missing` with reason `no_candidate` — never
   `never`/`not_stated` — and no model call is made.**
4. Otherwise one model call receives the in-scope snippet list, **with the anchor date
   as a context header** so it can weigh recency relative to the anchor when snippets
   conflict. R remains the gatekeeper for scope and eligibility — the model never
   recomputes the window.
5. The model returns its task-specific fields, including the value,
   `evidence_ids`, and (when useful) a `decision_note`.
6. R resolves the ids and materializes the original evidence for physician review.

**Dynamic enums and batching.** Because the legal evidence ids come from one
subject's supplied snippets, the output type is subject-specific. The initial
implementation therefore makes separate structured calls with separately built types.
`parallel_chat_structured()` cannot apply different types to different prompts in one
batch. A fixed `S01…Sn` vocabulary plus an R check for unused ids remains a later
optimization only if measured throughput justifies weakening the grammar-level
constraint.

**Copy-forward handling (step 2).** Clinical notes frequently paste a prior statement
forward unchanged, so the same sentence reappears under many later dates. Dedup here is
an **efficiency** step (smaller prompt, no anchoring on a stale pasted line), not a
correctness mechanism — the model already tolerates several agreeing snippets. Before
numbering, R deduplicates on normalized snippet text, keeping one representative. *Which*
copy to keep is a minor reviewer-facing choice — the earliest is the first-recorded date
(useful when a one-time statement was copied forward); the most recent is the latest
confirmation (often more useful for a current-status question). Either way it is **not** a
reliable `effective_at`: the true clinical date comes from the text content or a
structured source, and a *standing state* such as "non-smoker" has no single effective
date at all. Note this is only a *display* choice — the deduped value is unchanged, and an
in-window candidate still exists. Dedup runs **after** scoping, so it never drops an in-window restatement in
favour of an out-of-window original. **Exact-normalized matching is enough** — it catches
literal copy-forward, while semantic restatement ("non-fumeur" vs "pas de tabac") is left
alone, because extra *agreeing* snippets are harmless; add near-duplicate matching only
if a measured need appears.

This keeps the call count bounded. Per-snippet classification followed by
deterministic collapse is an escalation path if evaluation shows that bundled calls
mishandle contradictions, copy-forward, or target roles.

**Cross-field coupling (a measured question, not a settled fact).** A bundled call places
every field (`value`, `evidence_ids`, `decision_note`) into **one schema
generated left-to-right in one pass**, so the fields are statistically coupled — through
the shared schema and through the model priming on its own emitted tokens. This much is
established and demonstrable: a "space out the letters" directive in one field's
description carried into a *neighbouring* field's value, so descriptions are advisory text
in a shared prompt, not sandboxed per field.

What is *not* established, and must stay hypothesis until measured:

- that reordering fields cleanly separates "global-instruction interpretation" from
  autoregressive momentum — both can act at once, and a single stochastic run shows little;
- that declaring `evidence_id` first makes the model choose evidence *before* deciding —
  **serialization order is not reasoning order**; emitting the id first conditions later
  tokens, but the decision may already be latent before any token is emitted;
- that value/evidence coupling validates correctness — it likely improves citation
  *relevance*, but value-vs-evidence agreement is **circular**, not an independent check.

**Confound to control.** ellmer's `Chat` is a mutable, stateful object; reused across
calls it carries prior turns
([Chat reference](https://ellmer.tidyverse.org/reference/Chat.html)). Every experimental
run must construct a **fresh chat**, or earlier turns silently become part of the prompt
and run-to-run comparisons are contaminated.

A disciplined probe, before drawing any conclusion: fresh chat per run; fixed model and
parameters; test **both field orders**; test **with and without** the planted instruction;
**repeat each condition**; and include **separate per-field calls as the true-isolation
control**.

**Design posture given all this.** Keep bundled
`value + evidence_ids + decision_note` as the default when the task benefits from all
three — a coupled answer, citation set, and explanation are operationally useful — but
treat the coupling honestly:

- every separately judged claim carries **its own** `evidence_ids`, never one shared
  evidence field for unrelated claims;
- evidence is **provenance, not verification**; internal value↔evidence agreement proves
  nothing on its own;
- R resolves ids and may assert mechanical consistency, but does not judge whether the
  evidence clinically supports the answer;
- physician review and adjudicated evaluation determine whether the cited snippets and
  decision note appropriately support the value;
- if changing field order changes the **clinical answer**, the task is **unstable**: fix
  or split it, do not select the convenient order. (A minor shift in *which* supporting
  snippet is cited is tolerable; a flipped value is a defect.)

So the bleed finding supports bundling — not because "leakage is good," but because
coupled answers and citations are useful *provided we treat them as coupled, not as
independent checks*. Per-snippet classification followed by deterministic collapse remains
the escalation path if measured bleed proves harmful.

Deterministic single-snippet preselection is also a policy option, not a universal
rule. A latest note can contain stale or contradictory content.

## 5. Anchors, scopes, and construction policies

Anchor rules are data that select a named resolver, for example first, last, or nth
event. The resolver returns the anchor date plus the event and record identifiers
used to establish it. **An anchor is optional:** whole-history ("ever") variables have
no anchor and scope the entire record, typically with the `any` policy.

A scope can combine temporal and relational constraints:

- `all` (the entire patient history, for "ever" variables);
- `<= anchor`;
- `+/- 30 days`;
- `(anchor_a, anchor_b]`;
- `same_event`;
- `same_stay`;
- `same_event OR within [-365d, +7d]`.

**The scope *is* the clinical question — match it to intent.** No evidence in scope is
`missing`, and that is *correct*, not a bug: `smoking_status_pre_surgery` with an
`anchor − 365d` window asks "what is known about smoking in the year before surgery?",
and "nothing" is an honest answer. The lifelong-non-smoker intuition belongs to a
*different* variable — `ever_smoked` — declared with whole-history scope, where the older
"non-fumeur" notes are in scope and resolve to `never`. So pick the scope per variable to
match intent (a window for time-relative status, whole-history for monotone "ever"
questions); do not try to make one window serve both, and do not map a scoped `missing`
to a clinical value.

Source adapters turn raw records into hits. Construction policies turn scoped hits
into values. Initial policy families grounded in D0740/D0840 are:

- `identity` for a single valid source result;
- `any`;
- `nearest`, `first`, and `last`;
- `summarise` with count or count-distinct thresholds;
- `rank_select` with ordered tie-break keys;
- `reconcile` for source precedence and conflicts;
- `collect`.

Policies are named and tested R functions. The spec selects a policy and supplies
parameters. There is no generic boolean or derivation DSL.

Examples from the existing projects:

- D0740 biology selects the latest examination on or before an anchor.
- D0840 biology ranks by target distance, preferred side, analyte priority, date,
  and record id.
- D0840 dialysis combines 90-day and 365-day scopes, count-distinct thresholds,
  source precedence, and conflict review.

## 6. Derived columns

Derived variables remain ordinary project-level R:

```r
features$poids_delta <- features$poids_t1 - features$poids_t0
features$tabac_changed <- features$tabac_t0 != features$tabac_t1
```

There is no derived-variable spec, registry entry, or rule interpreter. If lineage
documentation is later needed, it should be generated from or kept next to the R
code rather than maintained as a second executable description.

**Scope-bounded values → derived lifetime categories.** An extracted value must not
assert more than its scope shows, so observed text tasks emit `yes` / `no` /
`not_stated` ("is there evidence in *this* scope?"), never `never` — an all-time claim a
window cannot support. Clinical categories that span scopes are *derived*:

```r
smoking_status <- dplyr::case_when(
  currently_smoking == "yes" ~ "current",   # windowed observed task
  ever_smoked       == "yes" ~ "former",    # whole-history observed task
  ever_smoked       == "no"  ~ "never",
  TRUE                       ~ "not_stated"
)
```

Two consequences. (1) A `no` / `never` is **evidence-absent**: "no positive evidence
found, as far as retrieval reached" — not proof of absence, so its confidence is capped
by candidate recall and is weaker than an evidence-positive `yes` (which carries an
`evidence_id`). The error budget is asymmetric — a false `no` (a missed positive) is the
dominant risk, which is exactly what the abstention/recall audit targets. (2) The model
does the minimal reading (one yes/no per scope); all temporal and lifetime reasoning
stays in auditable R.

## 7. Structured decoding and failure handling

A JSON Schema constrains legal output tokens. It guarantees structure, not clinical
truth. Unbounded string fields can still grow, and a model can still choose the wrong
legal enum.

Every candidate model must pass a grammar-enforcement gate using a bare structured
call without a strong JSON-following prompt. Reject any model that escapes the
schema. The rule is based on observed behaviour, not a permanent ban on a category
of models.

The runtime path is:

1. call structured extraction;
2. validate the returned object;
3. record success or failure in the attempt table;
4. retry under a small explicit policy when appropriate;
5. fail closed when retries are exhausted.

Partial clinical JSON is never repaired automatically because repair can invent the
field being audited.

## 8. Provider-parameter verification

Provider abstractions can silently drop parameters. A parameter is not considered
active merely because it was supplied.

For the current ellmer/Ollama OpenAI-compatible path:

- generation controls such as temperature, seed, and output cap belong in
  `ellmer::params()`;
- values passed through native-style `api_args$options` may be ignored;
- context size must be verified from the server or configured outside that request
  path when necessary.

General rule: verify determinism by running identical requests twice and comparing
outputs; verify runtime settings through server telemetry or logs.

Current model-specific results and incident history belong in `HANDOFF.md`, not in
the durable architecture.

## 9. Retrieval and evaluation

Lexical retrieval is the initial, replaceable baseline. It is tuned for sensitivity,
but may miss abbreviations, spelling variants, indirect evidence, or evidence lost by
section parsing. Copy-forward also complicates the interpretation of document dates.

Evaluate retrieval separately from extraction:

- candidate recall: did the evidence-bearing record enter the candidate set?
- extraction accuracy: given candidates, was the value correct?
- evidence grounding: did the model select the adjudicated snippet?
- abstention: how often retrieval/scoping returns `no_candidate`, with a hand-audited
  sample to confirm true absence rather than a recall miss (a `no_candidate` is never
  reported as `never`). This is where compound recall failure — a query miss *and* a
  scope miss — hides, so it is the highest-value thing to audit by hand.
- operational reliability: failures, latency, and retries.

Gold is usually absent at first. Review-ready output is still useful:

1. export values with materialized evidence;
2. record agreement or a corrected value;
3. preserve reviewed rows as gold;
4. enable evaluation as labels accrue.

Absolute retrieval recall is generally unknowable without an oracle. Report recall
on labelled samples, coded silver standards, or relative query comparisons.

## 10. Phase 0 findings and next experiment

Phase 0 has already established:

- ellmer's **type builders** are the default schema path: they validate by construction
  and drive typed JSON→R conversion (tibbles), whereas `type_from_schema()` neither
  validates the schema nor converts the result. `type_from_schema()` is kept as a narrow
  escape hatch for tested constraints the builders cannot express (`maxLength`,
  `maxItems`) (§1);
- structured calls can be made deterministic when parameters reach the provider;
- the attempt log captures real parse and server failures without aborting the run;
- model grammar enforcement must be tested rather than assumed;
- generated evidence text is the wrong contract.

The next experiment is:

1. reconstruct numbered, dated snippets rather than using an opaque concatenated
   blob;
2. make one bundled `value + evidence_ids + decision_note` call per subject-specific
   output type;
3. add synthetic negative and abstention fixtures;
4. run the frozen adjudicated smoking sample;
5. compare per-snippet extraction only if bundled errors justify its extra cost.

D0840 is the development corpus for what follows. The sequence is deliberately
heterogeneous: smoking establishes longitudinal text extraction and reviewable
evidence; transplant anastomoses tests a multi-field task with partial missingness;
dialysis tests reconciliation of LLM observations with CCAM and pre-emptive status;
biology timepoints tests deterministic anchor-relative ranking without an LLM. Only
repetition observed across these working tasks should become shared configuration.
