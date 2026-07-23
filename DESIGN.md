# extractionengine design contract

## Product boundary

`extractionengine` executes and audits an operational definition supplied by a
researcher. It does not decide whether that definition is clinically or
scientifically correct.

The responsibility split is:

- `redsan`: EDSAN retrieval, identifiers, table grain, time mechanics, and
  normalized source types;
- researcher-owned code: concepts, selectors, thresholds, windows, value expressions,
  model schemas, and interpretation;
- `extractionengine`: compile the definition, select eligible evidence, execute
  it, and preserve values, coverage, evidence, and provenance;
- `ellmer`: model-provider transport and structured responses.

The package is experimental. Contract clarity takes precedence over backward
compatibility.

## The three authoring layers

The executable definition has three deliberately separate layers:

1. `concept_spec()` locates possible signal rows. A named channel records its
   source and selector; it does not decide which prepared columns a published
   value uses or how it is calculated.
2. `use_channel()` activates one named channel from an explicitly supplied
   concept, or one self-contained inline channel, and decides how candidate rows
   are used.
3. `bin_output(group_by)` or `from_channel(..., group_by, value)` decides the
   final grain, what is published, and, for a deterministic payload, the
   data-masked value expression.

`resolve_variable_spec()` is the single compiled representation consumed by
execution, `inspect()`, and provenance. Constructors fail closed: every accepted
argument is validated and used. Reuse is ordinary R code returning a
`variable_spec()`.

## Concepts and activations

`analyte(codes)` only selects lab rows by `TYPEANA`. It does not type a result
lane. `lab_channel()` defaults to the logical source `"biology"` but accepts any
registered source override; source-specific prepared columns come from the
source contract, never from `if (source == ...)` branches.

The built-in biology source uses `ELTID` as its required generic source-item
coordinate. Native `BIOL_ID` is preserved with canonical casing when available,
but is not required for execution.

`text_channel()` records source and selector only. Relational eligibility belongs
to its activation.

Every entry of `variable_spec(channels =)` is named and must contain
`use_channel(channel = ...)`. The outer name is the activation alias used by
combine expressions, output, inspection, and provenance. A character `channel =`
requires `concept = <concept_spec>` on that activation. An inline channel
definition requires `concept = NULL` because it is already self-contained.
`variable_spec()` has no global concept: different activations may draw from
different reusable concepts, and identical channel names remain unambiguous
inside their explicitly named catalogs. Neither form can refer to another
activation alias. `selector =` is an explicit local replacement.

Operational row, group, and time rules also belong to the activation:

- `window = c(from_days, to_days)` filters this activation relative to the
  variable's shared `anchor`; an activation without a window keeps the existing
  task-grain behavior;
- `filter_rows` is evaluated independently per task after selector, relational,
  and window selection. It is a data-masked expression over the real
  prepared-source columns, returns one logical per row, treats `NA` as `FALSE`,
  and keeps complete surviving rows;
- `filter_groups`, paired with `use_channel(group_by =)`, runs on those survivors
  in the same data mask and returns exactly one non-missing logical per group
  while retaining all surviving rows of accepted groups. `.data` supports
  programmatic column selection and `.env` disambiguates captured external
  values. This is an intermediate activation-local grouping only; it never sets
  the published grain, which belongs exclusively to the output constructor.

A character `anchor` is the exact date column supplied by the cohort. The engine
copies it to the internal task clock only when a window consumes it; it never
looks for that column in a channel source. `index_event()` is the alternative
pre-channel resolution: it names its own registered source, code selector, and
physical date column independently of the activated channels. Its `select_event`
closure may filter or reorder the matched event rows but cannot synthesize or
alter an `EVTID`/date tuple.

An activation may be used only by `from_channel()`; it need not occur in a
combine expression.

## Output and cardinality

`bin_output(group_by)` publishes observed membership or the result of hit-set
algebra. `from_channel(channel, group_by, value = NULL,
filter_by_qualified = NULL)` publishes one activation's payload. `group_by` is
mandatory in both constructors and is the only declaration of final result
grain; there is no default PATID.

For deterministic channels, `value` is mandatory and is evaluated once per
final group in a data mask containing its complete, row-aligned prepared-source
rows. It may reference several columns; missing values are not removed
automatically. If no payload row remains, the expression is not evaluated and a
logical `NA` is published. Otherwise it must return exactly one cell: one atomic
scalar or one list cell. Longer or dimensional results are cardinality errors.
A row carrying `NUMRES`, `STRRES`, both, or neither is valid until the authored
expression uses those columns.

For a `lucene_llm` activation, `value` must be omitted and the complete
structured result frame is published.

## Relational keys and output grain

The combine and output contracts are self-contained:

- `search_within` in a text `use_channel()` controls the document relation
  searched before Lucene retrieval and is initially limited to `PATID` or
  `EVTID`;
- `combine = combine_channels(expr, by)` defines both the boolean expression and
  the identity-spine key where activated signals must coexist;
- `filter_by_qualified` in `from_channel()` chooses the key used to
  `semi_join()` payload rows to the qualifying combine relation;
- `output$group_by` is the final result grain.

`expr` is one boolean expression string over activation aliases using `|`, `&`,
`!`, and parentheses. No separate public hit-set helper constructors are part of
the authoring surface.

`ELTID` identifies an element only inside its source identity domain. A combine
at `by = "ELTID"` may use multiple aliases or selectors resolving to that same
domain, but a cross-source ELTID combine is invalid. If a payload consumes those
qualified keys at `ELTID`--through its final `group_by` or
`filter_by_qualified`--that payload must belong to the same domain. Projecting
qualification first to `EVTID` or `PATID` permits a legitimate cross-source use.

Both `by` and `group_by` are mandatory; neither is inferred from the other. A
combine may be finer than the output (existential projection), equal to it
(direct match), or coarser (explicit broadcast to output units).
`filter_by_qualified` is admitted and mandatory only for the fine-to-coarse
case. It may then equal `combine$by`, retaining rows of qualifying subunits, or
`output$group_by`, retaining all payload rows of final units with at least one
qualifying subunit. It must be `NULL` without a combine, at equal grain, and for
coarse-to-fine broadcast. The filter never creates an intermediate aggregation.

Payload execution is ordered: `combine by -> filter by qualified -> group by ->
evaluate value`. The value expression is evaluated once per final group on the
aligned raw rows; there is no implicit missing-value removal or lower-grain
aggregation. Public evidence for the payload channel is restricted by the same
qualified-row relation; its complete pre-gate intermediate remains internal
audit data.

LLM responses are compiled as one row per output task. Consequently, an LLM
activation used as a fine-to-coarse payload may set `filter_by_qualified` only
to `output$group_by`; lower-level LLM payload restriction would require per-key
model calls and is outside the current execution contract. An LLM output omits
`value` and publishes the complete structured record.

`search_within = "EVTID"` requires tasks carrying both `PATID` and `EVTID`,
through stay-grain output or an `index_event()`. When stay-grain output searches
within the patient, the target stay remains public `EVTID`; an evidence row's
native stay is kept separately as `source_EVTID`. Text retrieval may collapse a
repeated normalized sentence only within the same native `EVTID`/`ELTID`
identity; identical wording in distinct source units remains distinct relational
evidence. For an LLM activation, task-level normalized-text deduplication is then
applied to the model-candidate view before `max_candidates`, using `snippet_text`
when a pre-retrieved input has no usable `hit_text`; it does not alter the
identity-preserving retrieval view.

A pre-retrieved text fixture must be relationally coherent with real retrieval:
one coverage row per task, only `candidate`, `no_candidate`, or
`no_eligible_document`, and candidate rows exactly for the tasks whose state is
`candidate`.

## LLM contract

An LLM activation receives a native `ellmer::TypeObject` in `response =`.
Authored object and field descriptions contain the variable-specific
instructions. The package supplies a general, overrideable `system_prompt` and
constructs the user message from the target plus numbered excerpts; optional
`user_prompt` is only a prefix for cross-field instructions that do not fit the
schema descriptions.

`rationale` is one activation argument. Omission or `TRUE` adds a required field
with the package's generic evidence-bound description; a non-empty string
overrides that description; `FALSE` or `NULL` omits the field. The engine also
adds `evidence_ids`, constrained to the snippets actually shown, then resolves
those identifiers into the evidence table rather than publishing them as a JSON
field. Authored collisions with engine, grain, or audit fields fail at compile
time. A completed response is valid only if at least one ID resolves. Mixed real
and invented IDs retain the grounded result with a citation warning and discard
invented IDs; zero resolved IDs make the result invalid, typed-missing, and
reviewable while preserving the raw response in audit.

`ellmer::chat_structured()` owns structured generation; the engine does not
construct a manual JSON format. One successful named-list response becomes one
row containing all authored fields and the rationale. No-candidate, model-error,
and invalid-schema paths preserve the same typed frame with missing values plus
separate processing/review state, raw response, evidence, and provenance.

A valid structured response is not implicitly a positive hit. Until the API has
an authored response-to-membership rule, an activation with
`method = "lucene_llm"` cannot be referenced by
`combine = combine_channels(...)`; compilation
fails explicitly. It may still be published by `from_channel()`, including as a
payload gated by a combine over deterministic channels.

Each `lucene_llm` activation owns its `model`, `model_params`, response schema,
and prompt configuration. This permits two activations in one variable to use
different models. `run_variable(chat =)` is a global test/debug override for all
LLM activations in that run; execution still isolates conversation state with a
fresh task clone.

## Audit contract

`run_variable()` exposes exactly four top-level components: `values`,
`channel_status`, `evidence`, and `audit`. Published frames use native grain keys
while composite task identifiers remain internal. Coverage is separate from
value. Hit-set combination reports partial or failed channel coverage without
silently changing the observed decision.

`channel_status` has one row per output unit and activated channel. Its stable
core identifies output unit, variable, channel, and source. `selection_status`
is exactly `matched`, `no_match`, or `unavailable`. `processing_status` is
`not_required` for non-LLM channels; for `lucene_llm` it is exactly `completed`,
`not_called`, `invalid`, or `failed`. Selection and model processing are separate
axes and neither label carries a clinical interpretation.

Public evidence retains source-specific prepared-row columns and classifies each
row with `evidence_kind = "source_row"`, `"lucene_hit"`, or
`"llm_citation"`. `evidence_ref` is an opaque, non-missing coordinate local to
the executed run and source snapshot, not a globally durable warehouse key. An
LLM citation additionally carries its task-local `snippet_id`. Internal
`source_row_id` and `hit_ref` coordinates remain available only in
`audit$internal$channel_intermediates`. A native evidence `EVTID` is published as
`source_EVTID`; at stay-grain output the target remains `EVTID`, even when the
two values are equal.

`audit$counts` is a long table with output-grain keys, `channel`, `stage`,
`unit`, and `n`. The controlled stages are `pre_selector`, `window`, `selector`,
`filtered_selector`, `model_input`, and `output_input`. They count,
respectively, associated structured rows or searchable text documents before
selection, window survivors, selector matches, matches surviving activation
filters, model snippets, and source rows supplied to the terminal value
expression. Stages appear only when separately instrumented, so absence does not
prove an operation did not run. The audit also contains `llm_calls`, one row per
task/channel model invocation actually made. Its independent public fields are
`call_status`, `response_status`, `task_validity`, and `transport_attempts`; the
zero-row table keeps the same schema. The resolved `execution_manifest` is a
configuration snapshot rather than an activity log. Combination runs additionally retain
`overlap`, the task-level channel-membership intersections, and `combine_keys`,
the evaluated key-level relation, inside the audit rather than as ordinary
output tables. The live `resolved_spec` and raw `channel_intermediates` are debugging details under
`audit$internal`, not ordinary audit tables. The execution manifest has a compact
print method while retaining its complete machine-readable structure.

The execution manifest and `inspect()` record activation alias,
`origin_concept`, `origin_channel`, source, and inline/catalog origin,
original and effective selector, row/group filters, activation window,
`search_within`, `combine$by`, `filter_by_qualified`, `output$group_by`, selected
output value expression, response schema, and LLM configuration. Their output
view follows the execution order `combine by -> filter by qualified -> group by
-> evaluate value`.

`variable_spec(name =)` is the canonical public identifier. `run_protocol()`
accepts an entirely unnamed list or an entirely named list whose names match
each `spec$name` in order, rejects duplicate canonical names and partial or
discordant naming, and always names returned results from `spec$name`.

## Non-goals

The package does not contain study concepts, infer clinical absence from source
silence, retrieve arbitrary warehouses, define a universal biology schema,
silently repair cardinality or schema violations, or decide scientific meaning.
