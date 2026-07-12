# extractionengine design contract

## Product boundary

`extractionengine` executes and audits an operational definition supplied by a
researcher. It does not decide whether that definition is clinically or
scientifically correct.

The responsibility split is:

- `redsan`: EDSAN retrieval, identifiers, table grain, time mechanics, and
  normalized source types;
- researcher-owned code: concepts, thresholds, windows, aggregation rules, and
  interpretation;
- `extractionengine`: compile the authored specification, select eligible
  evidence, measure it, and preserve values, coverage, evidence, and provenance;
- `ellmer`: model-provider transport and structured responses.

## Executable definition

A study variable is a `variable_spec()` built from explicit channel definitions,
scope, combination, output, and grain. `resolve_variable_spec()` is the single
compiled representation consumed by execution, inspection, and provenance.

Constructors fail closed: every accepted argument is validated and used. There
are no open `...` bags and no separate template representation. Reuse is plain R:
a builder is an ordinary function that returns a `variable_spec()`.

## Sources

The engine accepts EDSAN tables normalized by `redsan`, or compatible prepared
views with the same declared columns and types. `source_spec()` binds those
prepared columns to engine payload roles; it does not parse warehouse values or
copy the `redsan` source registry.

Native identifiers are retained whenever present. Temporal scope respects each
source's point or interval mechanics. Relational scope and temporal scope remain
separate, explicit parts of the study definition.

## Execution and audit

The existing semantics are preserved:

- task and output grain are checked explicitly;
- windows and event selection run before measurement;
- structured and text channels report coverage independently of their value;
- multi-channel combination operates on observed hit sets and reports partial or
  failed channel coverage separately;
- payload reduction is scoped to the keys that passed the combination;
- evidence links resolve to native source coordinates;
- provenance records the compiled definition and relevant runtime facts.

Text measurement accepts an `ellmer` Chat supplied by the caller. Each task uses
isolated conversation state. Provider, model, parameters, call status, and
available truncation diagnostics are audit facts. Model output remains
review-by-design; the engine does not claim model accuracy.

## Non-goals

This package does not contain study concepts, infer clinical absence from source
silence, retrieve arbitrary warehouses, define a universal biology schema, or
silently repair invalid specifications.

Capabilities that existed only as deferred ideas in the prototype remain
deferred until a real consumer requires them.
