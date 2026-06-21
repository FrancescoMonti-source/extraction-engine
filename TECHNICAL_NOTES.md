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
column. Smoking may return a peri-operative status, several evidence references, and a
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
evidence_ids
attempt_id
```

`recorded_at` and `effective_at` are distinct because a recent note can describe a
remote historical event.

`evidence_ids` is a **list-column**: the snippet ids supporting *one* hit (a single hit
may rest on several snippets, e.g. an `uncertain` call citing two conflicting notes).
This is distinct from `selected_hit_ids` on a value (§ below): `evidence_ids` links a hit
to its supporting snippets, while `selected_hit_ids` links a constructed value to the
hits used to build it.

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
S01 | 2025-02-20 | document 104 | Ancien fumeur, sevré depuis 2010.
S02 | 2025-03-04 | document 287 | Tabac : sevré.
```

For `smoking_status_periop`, these snippets were selected from documents recorded in
`[anchor − 365 days, anchor + 7 days]` around surgery. The output type contains a dynamic
evidence enum and a task-specific status enum:

```json
{
  "smoking_status_periop": "sevre",
  "evidence_ids": ["S01", "S02"],
  "decision_note": "Both peri-operative notes describe smoking cessation."
}
```

The allowed evidence values are the supplied snippet ids. Client code resolves each
id to the complete stored snippet. The decision note is a concise explanation of how
the model handled the supplied evidence; it is not itself evidence.

The status enum for this task is `actif` / `sevre` / `non_fumeur` / `indetermine`,
matching D0840's `tabac_statut` so outputs use the same vocabulary as the legacy task.
D0840 currently has no adjudicated smoking gold.
`actif` = an in-scope record describes current smoking; `sevre` = ex-smoker or cessation;
`non_fumeur` transcribes a documented non-smoker label (D0840 deliberately lumps
"non-fumeur", "jamais fumé", and "absence de tabagisme" here — it is not upgraded to the
lifetime claim "never smoked"); `indetermine` = the supplied evidence is contradictory or
insufficient. `no_candidate` is a separate workflow state produced by R before any model
call and is not part of the enum. Splitting `indetermine` into distinct `uncertain`
(conflicting) vs `not_stated` (silent) states, or adding a stronger lifetime `never`, are
deferred refinements that would each require reviewed labels encoding the distinction.

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
3. **If no candidates remain, the value is `missing` with reason `no_candidate` —
   never a clinical status or `not_stated` — and no model call is made.**
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
- that declaring `evidence_ids` first makes the model "choose evidence before deciding" —
  this is **conceptually backwards**, not merely unproven: the *supporting* ids are defined
  relative to the value, so you cannot select what justifies an answer you have not yet
  formed. Evidence selection is posterior to, or co-determined with, the decision, never
  prior to it. Emitting the ids first only conditions later tokens; **serialization order
  is not reasoning order**, and the decision may already be latent before any token is
  emitted. (The reasoning-first pattern that *does* help is CoT — emit a rationale such as
  `decision_note` before the value — which is distinct from pre-selecting citations.)
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

**The declared source scope bounds which records may answer the question; it does not
erase history explicitly summarized inside those records.** For
`smoking_status_periop`, a `[anchor − 365 days, anchor + 7 days]` source scope means only
documents recorded in the year before surgery through the first post-operative week are
eligible. An eligible note saying “ex-fumeur, sevré en 2010” supports `sevre` directly:
the note is an in-scope assessment that contains historical information. We do not combine
a current-status task with a whole-history `ever_smoked` task to manufacture the status.

The variable dictionary must state at least:

```text
variable:     smoking_status_periop   (≙ D0840 tabac_statut)
anchor:       surgery date
source scope: recorded_at in [anchor - 365 days, anchor + 7 days]
meaning:      smoking status documented around surgery
values:       actif / sevre / non_fumeur / indetermine
absence:      open world
no candidate: no_candidate (R-side, no model call); never infer non_fumeur
```

If no eligible candidate exists, record `no_candidate` and make no model call. If
eligible supplied material is contradictory or does not establish a status, return
`indetermine` (D0840 folds both cases into this one value). `non_fumeur` requires an
explicit documented non-smoker statement and is never inferred from silence. Two
refinements are deliberately deferred until reviewed labels can encode them: splitting
`indetermine` into distinct `uncertain` (conflicting) vs `not_stated` (silent) states, and
adding a stronger lifetime `never` (which would require explicit “jamais fumé” evidence). A
question such as “ever smoked anywhere in the available record” would be a separate
whole-history variable.

### Two text-extraction modes

The earlier blanket rule—“the model never returns current/former/never; R always derives
the category”—was too broad. Use one of two modes according to the variable's meaning:

1. **Documented-status transcription.** An eligible clinical record already states the
   category. The model returns the task's enum directly and cites the record. The source
   scope filters where that documented assessment may come from; the statement itself
   may summarize older history. `smoking_status_periop` uses this mode.
2. **Derived synthesis.** No single documented status answers the question. The engine
   extracts independently meaningful observations from their appropriate scopes, and R
   combines them with an explicit rule. This remains appropriate for genuine lifetime
   reconstruction or cross-source composites.

Neither mode permits inference from silence. The first transcribes a documented
assessment; the second combines explicit observations.

### Absence policy

`no_candidate` describes retrieval and scoping: no eligible candidate reached the
extractor. It is not a universal clinical value. Every task must separately declare what
may be concluded when no positive evidence is found.

Absence policies may differ by source. No qualifying ICD-10 code in a complete,
well-defined extract can support a stronger conclusion than no lexical text hit, which
may simply be a retrieval miss. Preserve the source-level reason and coverage state;
never pool unlike absences into one undocumented negative.

Use three broad policies:

1. **Open world (default).** Absence of documentation is unknown. Keep the analytical
   value missing or explicitly report `no_documented_evidence`; do not return a clinical
   negative.
2. **Explicit negative required.** A negative value is allowed only when an eligible
   source explicitly states it. Smoking uses this pattern: `non_fumeur` requires a
   documented non-smoker statement. Silence remains `no_candidate` or `indetermine`,
   depending on whether any relevant candidate reached the model.
3. **Closed world by construction.** Absence may become negative only when the task
   defines sufficient source coverage and a defensible ascertainment rule. The rule and
   coverage requirements must be versioned and preserved with the result. A retrieval
   or source-access failure remains missing even for an otherwise closed-world task.

Diabetes illustrates why this is necessary. Clinical notes rarely say “not diabetic.”
A text or code search with no candidate means only “no diabetes evidence was retrieved,”
not `diabetes = no`. A diabetes variable may produce:

```text
yes                     explicit qualifying evidence exists
no_documented_evidence  required sources were available, but no qualifying evidence exists
missing                 source coverage was insufficient or retrieval failed
```

Calling `no_documented_evidence` simply `no` requires a deliberate, documented
closed-world decision. Even then, retain the underlying candidate and coverage state so
the analytical negative remains auditable.

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

Do not introduce derivation merely to split one clinical question across mismatched
horizons. `smoking_status_periop` is an observed categorical value extracted directly
from eligible in-scope records. Ordinary R derivation remains appropriate for true
computed variables such as deltas, change indicators, or composites over independently
meaningful inputs.

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
  sample to distinguish true lack of documented evidence from a recall miss. A
  `no_candidate` is interpreted only through the task's absence policy and is never
  silently reported as `non_fumeur` or `diabetes = no`. This is where compound recall
  failure—a query miss and a scope miss—hides, so it is the highest-value thing to audit
  by hand.
- operational reliability: failures, latency, and retries.

Gold is usually absent at first. Review-ready output is still useful:

1. export values with materialized evidence;
2. record agreement or a corrected value;
3. preserve reviewed rows as gold;
4. enable evaluation as labels accrue.

That is the current D0840 situation: the available smoking pool contains inputs, and
`tabac_gpt` / `test tabac.xlsx` contain prior model outputs, not adjudicated truth.
Posterior physician review creates reviewed labels. Because the reviewer sees the
suggested answer and evidence, agreement on that same run is descriptive and
model-assisted; it must not be reported as an independent accuracy estimate. A later
independent estimate requires fresh cases or adjudication performed without exposing
the tested model's prediction.

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
2. make one bundled
   `smoking_status_periop + evidence_ids + decision_note` call per subject-specific
   output type, using only documents in the declared peri-operative source scope;
3. add two distinct absence-path fixtures:
   - no smoking-related retrieval candidate → `no_candidate`, with no model call;
   - a retrieved but non-informative smoking-related candidate (for example,
     “père fumeur”) → `indetermine`, never `non_fumeur`;
4. freeze an unlabelled real smoking sample, run extraction, then export it for
   posterior physician review and correction;
5. preserve those reviewed labels for future regression and compare per-snippet
   extraction only if bundled errors justify its extra cost.

## 11. D0840 development corpus

### Purpose and inventory

D0840 is a development corpus, not a model-fine-tuning dataset. It is used to develop
and compare extraction workflows: retrieval, scoping, prompts, output contracts,
deterministic policies, provenance, review exports, and evaluation.

It does not currently contain adjudicated gold. Existing cached outputs are useful
baselines and debugging material, not truth labels.

The existing project contains 134 final output columns, but those columns arise from a
much smaller number of reusable task shapes:

- 58 columns use the same biology timepoint-selection machinery;
- 31 columns are labelled as LLM-produced in the data dictionary;
- the implementation contains roughly ten `gpt_column()` task families;
- several final variables are constructed by combining LLM observations with PMSI or
  other deterministic sources.

The important unit is therefore the **extraction task**, not the final wide-table
column. One task may emit several related observations, and one final variable may
combine several tasks or sources.

### Representative task set

| D0840 task | What it teaches |
|---|---|
| Smoking status around surgery (`[anchor − 365d, +7d]`) | Window-bounded source selection, target-role filtering, explicit status categories, contradictions, `evidence_ids`, and a useful `decision_note`. |
| Transplant anastomoses | One context producing several related durations, techniques, and locations; partial missingness; cross-field coupling. |
| Dialysis before transplant | Multi-source construction: pre-emptive status, CCAM counts and thresholds, text observations, source precedence, and disagreement review. |
| Biology timepoints | Deterministic anchor-relative selection with tolerances and ordered tie-breakers; proves the engine is not an LLM-only system. |
| Delayed graft function | Explicit positive and negative text rules, risk-only mentions, conflicting values, and routing to review. |
| Surgical antecedents | Whole-history scope, several clinical categories in one task, repeated mentions, exclusions, and multi-item evidence. |

The implementation order is smoking → anastomoses → dialysis → biology. Delayed graft
function and surgical antecedents then test whether the emerging abstractions survive
different conflict and scope patterns. Only repetition demonstrated across working
tasks should become shared configuration or package code.

### Development, validation, and held-out discipline

Split at the **patient or transplant-pair level**, never at the snippet or document
level. Otherwise records from the same clinical case can leak across sets and make
performance look better than it is. If a patient has several linked episodes, keep
those episodes in the same split unless the evaluation question explicitly concerns
generalisation across episodes.

- **Development set:** visible during implementation. Use it to inspect failures,
  improve retrieval and prompts, refine output types, and write synthetic regression
  fixtures. Posterior physician corrections may become frozen regression labels.
- **Validation set:** frozen while one round of alternatives is compared. Use it to
  choose models, prompts, bundling strategy, thresholds, and other design options.
  Repeatedly consulting it eventually turns it into development data; when that
  happens, freeze a new validation set.
- **Held-out set:** untouched until the task contract and decision rules are fixed.
  Use it for the final estimate reported for that version. Do not alter the approach
  in response to held-out errors without declaring a new development cycle and
  reserving a new held-out set. For a defensible accuracy estimate, adjudicate these
  cases without showing the tested model's prediction, or use an independently reviewed
  set.

Stratify each split where feasible so rare but important cases are represented:
positive, explicit negative, not stated/no candidate, uncertain or contradictory,
multi-document, long-context, and known retrieval traps. Synthetic fixtures complement
these sets but do not replace held-out real cases.

Keep all clinical text, split assignments, adjudications, and row-level model outputs
local and gitignored. The repository may contain code, synthetic fixtures, aggregate
metrics, and documented conclusions. Persist split membership and task/prompt/model
versions locally so later comparisons use the same cases.
