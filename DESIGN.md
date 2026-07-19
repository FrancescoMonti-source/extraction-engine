# extractionengine design contract

## Product boundary

`extractionengine` executes and audits an operational definition supplied by a
researcher. It does not decide whether that definition is clinically or
scientifically correct.

The responsibility split is:

- `redsan`: EDSAN retrieval, identifiers, table grain, time mechanics, and
  normalized source types;
- researcher-owned code: concepts, selectors, thresholds, windows, reductions,
  model schemas, and interpretation;
- `extractionengine`: compile the definition, select eligible evidence, execute
  it, and preserve values, coverage, evidence, and provenance;
- `ellmer`: model-provider transport and structured responses.

The package is experimental. Contract clarity takes precedence over backward
compatibility.

## The three authoring layers

The executable definition has three deliberately separate layers:

1. `concept_spec()` locates possible signal rows. A named channel records its
   source and selector; it does not decide which payload column to read or how to
   aggregate it.
2. `use_channel()` activates a concept channel, or an inline channel, for one
   variable and decides how candidate rows are used.
3. `bin_output(group_by)` or `from_channel(..., group_by, reduce)` decides the
   final grain, what is published, and, for a payload, how values are reduced.

`resolve_variable_spec()` is the single compiled representation consumed by
execution, `inspect()`, and provenance. Constructors fail closed: every accepted
argument is validated and used. Reuse is ordinary R code returning a
`variable_spec()`.

## Concepts and activations

`analyte(codes)` only selects lab rows by `TYPEANA`. It does not type a result
lane. `lab_channel()` defaults to the logical source `"biology"` but accepts any
registered source override; source-specific prepared columns come from the
source contract, never from `if (source == ...)` branches.

`text_channel()` records source and selector only. Relational eligibility belongs
to its activation.

Every entry of `variable_spec(channels =)` is named and must contain
`use_channel(channel = ...)`. The outer name is the activation alias used by
combine expressions, output, inspection, and provenance. `channel =` is either
a concept-channel name or an inline channel definition; it cannot refer to
another activation alias. `selector =` is an explicit local replacement.

Operational row, group, and time rules also belong to the activation:

- `window = c(from_days, to_days)` filters this activation relative to the
  variable's shared `anchor`; an activation without a window keeps the existing
  task-grain behavior;
- `filter_rows` is evaluated independently per task after selector, relational,
  and window selection. Its formals name real prepared-source columns, it returns
  one logical per row, `NA` means `FALSE`, and complete surviving rows are kept;
- `filter_groups`, paired with `use_channel(group_by =)`, runs on those survivors
  and returns one logical per group while retaining all surviving rows of
  accepted groups. This is an intermediate activation-local grouping only; it
  never sets the published grain, which belongs exclusively to the output
  constructor.

A character `anchor` is the exact date column supplied by the cohort. The engine
copies it to the internal task clock only when a window consumes it; it never
looks for that column in a channel source. `index_event()` is the alternative
pre-channel resolution: it names its own registered source, code selector, and
physical date column independently of the activated channels.

An activation may be used only by `from_channel()`; it need not occur in a
combine expression.

## Output and cardinality

`bin_output(group_by)` publishes observed membership or the result of hit-set
algebra. `from_channel(channel, column, filter_by_qualified, group_by, reduce)`
publishes one activation's payload. `group_by` is mandatory in both constructors
and is the only declaration of final result grain; there is no default PATID.

For deterministic channels, `column` is mandatory and names the exact column in
the prepared source, for example `NUMRES`, `STRRES`, or `DATEXAM`. Candidate rows
retain the selected source row and its real columns. There is no implicit
`value -> NUMRES` mapping and no NUMRES/STRRES inference. A row carrying either,
both, or neither is valid until an explicit output read is applied. A missing
requested column is a hard error that lists the available columns.

Without `reduce`, zero non-missing values produce a typed `NA`, one is returned
unchanged, and more than one is a cardinality error. With `reduce`, the function
receives only non-missing values and must return exactly one scalar. A deliberate
type change by the reducer is valid.

For a `lucene_llm` activation, `column = NULL` publishes the complete structured
result frame; `column =` projects one declared response field.

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

Both `by` and `group_by` are mandatory; neither is inferred from the other. A
combine may be finer than the output (existential projection), equal to it
(direct match), or coarser (explicit broadcast to output units).
`filter_by_qualified` is admitted and mandatory only for the fine-to-coarse
case. It may then equal `combine$by`, retaining rows of qualifying subunits, or
`output$group_by`, retaining all payload rows of final units with at least one
qualifying subunit. It must be `NULL` without a combine, at equal grain, and for
coarse-to-fine broadcast. The filter never creates an intermediate aggregation.

Payload execution is ordered: `combine by -> filter by qualified -> group by ->
reduce`. The reducer is called once per final group on non-missing raw values;
there is no implicit lower-grain aggregation.

LLM responses are compiled as one row per output task. Consequently, an LLM
activation used as a fine-to-coarse payload may set `filter_by_qualified` only
to `output$group_by`; lower-level LLM payload restriction would require per-key
model calls and is outside the current execution contract. `reduce` remains
invalid for an LLM output.

`search_within = "EVTID"` requires tasks carrying both `PATID` and `EVTID`,
through stay-grain output or an `index_event()`. When stay-grain output searches
within the patient, the target stay remains public `EVTID`; an evidence row's
native stay is kept separately as `source_EVTID`.

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
time.

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

`channel_status` has a stable core identifying output unit, variable, channel,
source, coarse `status`, observed `hit`, and detailed `processing_state`;
execution paths may append review or contribution fields. `complete` means that
ascertainment completed, not that the channel hit. Combine results may carry
`contribution`; its `negative` label means ascertained without an observed hit
and is not a clinical interpretation.

Public evidence retains source-specific prepared-row columns and has one
canonical `evidence_ref`. LLM evidence may additionally carry the prompt-local
`snippet_id`; internal `source_row_id` and `hit_ref` coordinates remain available
only in `audit$internal$channel_intermediates`. A native evidence `EVTID` is
published as `source_EVTID`; at stay-grain output the target remains `EVTID`.

`audit$counts` is a long table with output-grain keys, `channel`, `stage`,
`unit`, and `n`. The controlled stages are `task_join`, `window`, `selector`,
`filter_rows`, `filter_groups`, `model_input`, and `output_input`; stages appear
only when separately instrumented, so absence does not prove an operation did
not run. The audit also contains `llm_calls`, one row per task/channel model
invocation actually made, and the resolved `execution_manifest`, a configuration
snapshot rather than an activity log. Combination runs additionally retain
`overlap`, the task-level channel-membership intersections, and `combine_keys`,
the evaluated key-level relation, inside the audit rather than as ordinary
output tables. The live `resolved_spec` and raw `channel_intermediates` are debugging details under
`audit$internal`, not ordinary audit tables. The execution manifest has a compact
print method while retaining its complete machine-readable structure.

The execution manifest and `inspect()` record activation alias and
concept/inline origin,
original and effective selector, row/group filters, activation window,
`search_within`, `combine$by`, `filter_by_qualified`, `output$group_by`, selected
output column and reducer, response schema, and LLM configuration. Their output
view follows the execution order `combine by -> filter by qualified -> group by
-> reduce`.

`variable_spec(name =)` is the canonical public identifier. `run_protocol()`
accepts an entirely unnamed list or an entirely named list whose names match
each `spec$name` in order, rejects duplicate canonical names and partial or
discordant naming, and always names returned results from `spec$name`.

## Non-goals

The package does not contain study concepts, infer clinical absence from source
silence, retrieve arbitrary warehouses, define a universal biology schema,
silently repair cardinality or schema violations, or decide scientific meaning.
