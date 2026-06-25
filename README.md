# extraction-engine (placeholder name)

Focused successor to `gptr`: an auditable, local-first
engine that turns clinical free text **and** structured EHR sources (ICD-10,
CCAM, labs) into validated, evidenced, **evaluated** analytical variables for
longitudinal cohort studies.

Development is grounded in real D0840 tasks. The canonical baseline now supports four
variables across both engine paths: smoking and transplant anastomoses through
text → LLM extraction, and diabetes and hyperkalaemia through deterministic structured
measurement. All four paths have been exercised against real normalized data over the
full 244-task cohort, with review-ready artifacts produced for physician adjudication.

Project data preparation remains upstream: the files supplied in `/data` already define
the study population and outer protocol period. The engine only constructs variables
within that supplied study universe.

## Checkpoint: spec-layer architecture validated

Tag `checkpoint/spec-layer-validated` marks a validated state of the spec-layer spine
(concept → channel → variable_template → variable_spec → run_variable), exercised end-to-end across:

- a categorical single-channel text variable (smoking);
- a binary multi-source OR variable with transparent source contribution (diabetes);
- an event-scoped multi-field text variable (anastomoses);
- deterministic code / lab / text execution (ICD-10 presence, analyte max-value, retrieval/eligibility);
- real retrieval + real local-model runs (gemma3:4b) on de-identified data — not just fakes.

The LLM step is **review-by-design**. The engine does **not** claim LLM accuracy; it guarantees the
deterministic eligibility / retrieval / combine / audit behavior around the LLM call and emits a
reviewable, grounded envelope (evidence, status/provenance, field-level acceptance, `needs_review`,
source contribution). See the LLM-boundary promise in
[`extraction_engine_design_formalization.md`](extraction_engine_design_formalization.md) §1 and §11.

Reproduce: deterministic suite `Rscript tests/testthat.R` (340 tests, 0 warnings); real-model runs
(need a local Ollama + de-identified data outside the repo) `scripts/run_variable_smoking_real.R`,
`scripts/run_variable_diabetes_real.R`, `scripts/run_variable_anastomoses_real.R`.

Start with:

- **[DESIGN.md](DESIGN.md)** — the current owner-facing product and architecture.
- **[TECHNICAL_NOTES.md](TECHNICAL_NOTES.md)** — contracts, decoding, evidence,
  provider details, and implementation rationale.
- **[HANDOFF.md](HANDOFF.md)** — chronological collaboration and experiment log.

In one sentence: ellmer handles LLM transport; this project gathers dated clinical
evidence, constructs auditable cohort variables, and evaluates them.

> ⚠️ Clinical data must **never** be committed to this repo. See `.gitignore`.
> The name `extraction-engine` is a placeholder.
