# Target Contract Migration

This note tracks shipped-vs-target gaps while `DESIGN.md` stays clean as the
target contract.

Current state: the spec-layer spine is executable and validated across multiple
concept shapes, but some names and envelopes still carry migration-era vocabulary.

| Area | Shipped today | Target contract | Migration status |
| --- | --- | --- | --- |
| Output constructors | Target names exist; legacy names still work as aliases. Internal output kinds still use the older runner names. | `bin_output()`, `num_output()`, `cat_output()`, `struct_output()` | Target vocabulary is executable; later cleanup can rename internal kinds if the runner surface needs it. |
| Absence policy | Removed from `variable_spec()` and templates; old `absence_policy=` calls now fail loudly. | Coverage/audit semantics owned by output and channel evaluability | Completed for the spec layer; preserve uncertainty through `channel_coverage`, `channel_status`, and evidence/audit views. |
| Source registry and roles | Default source specs carry redsan-shaped metadata and target role names; normalized output columns still use historical runner names, with legacy role aliases kept for migration. | `source_spec()` is seeded from `redsan::edsan_sources()` and exposes an open canonical role set: identifier spine, point/interval time roles, query/batch date keys, payload roles, and auxiliary row coordinates. | Target vocabulary is executable for the default docs/PMSI-diagnosis/biology sources. Later slices can make executors consume roles directly instead of physical column names. |
| Channel shape | `channel(..., produces=...)`; no `act_channel()` | Constructor implies signal shape; `act_channel()` for CCAM | Remove user-facing `produces`; add act-channel route. |
| Text method | `llm_after_lucene(top_n=...)` | `llm_after_lucene(candidates = candidate_selection(arrange=..., limit=...), prompt=..., type=..., positive_hit_when=...)` | Replace naked candidate limits with explicit selection rules. |
| Boolean envelope | `values` may expose `decision` / `decision_state`; membership/evidence may expose `role` | Public output centered on `value`, `channel_coverage`, membership/audit, evidence, `combine_rule` | Keep polarity internal to hit-set lowering; remove public role/decision fields unless retained as presentation output. |
| Inspection | Minimal `inspect()` / `resolve_variable_spec()` exists for concept, channel, and variable specs. | `inspect()` and `resolve_variable_spec()` expose inherited channel defaults and final executable view | Keep as experimental; broaden only as later slices reveal missing fields. |
| Event/stay grain | Text event linkage exists; structured event/stay linkage incomplete | Event/stay grain works across relevant channel types | Add structured event/stay linkage as an executor extension. |
| Whole-history text | Whole-history structured code exists; text still needs fixtures when no window is supplied | Whole-history subject text can retrieve all subject documents | Add no-window subject text eligibility. |
| LLM boundary | Existing parsers call ellmer through local definition bundles | Ellmer owns structured call/type validation/parsing; engine owns candidate selection, prompt rendering, evidence-ID validation, response-to-hit mapping, provenance | Align method declarations and provenance with the target contract. |

Tests should distinguish contract tests from temporary migration tests. Before
freezing a public API rule, exercise it against code, text, thresholded lab,
unthresholded lab, patient-grain, and event/stay-grain variables.
