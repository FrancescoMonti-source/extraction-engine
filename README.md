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

Start with:

- **[DESIGN.md](DESIGN.md)** — the current owner-facing product and architecture.
- **[TECHNICAL_NOTES.md](TECHNICAL_NOTES.md)** — contracts, decoding, evidence,
  provider details, and implementation rationale.
- **[HANDOFF.md](HANDOFF.md)** — chronological collaboration and experiment log.

In one sentence: ellmer handles LLM transport; this project gathers dated clinical
evidence, constructs auditable cohort variables, and evaluates them.

> ⚠️ Clinical data must **never** be committed to this repo. See `.gitignore`.
> The name `extraction-engine` is a placeholder.
