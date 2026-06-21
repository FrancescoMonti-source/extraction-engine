# extraction-engine (placeholder name)

Focused successor to `gptr`: an auditable, local-first
engine that turns clinical free text **and** structured EHR sources (ICD-10,
CCAM, labs) into validated, evidenced, **evaluated** analytical variables for
longitudinal cohort studies.

Development is grounded in real D0840 tasks. Independent smoking, retrieval, and
transplant-anastomosis rounds are complete; the current work is a clean synthesis of
their lessons into one reusable baseline.

Start with:

- **[SYNTHESIS_BRIEF.md](SYNTHESIS_BRIEF.md)** — the current clean-rebuild contract
  derived from the smoking and anastomosis rounds.
- **[DESIGN.md](DESIGN.md)** — the short, owner-facing product and architecture.
- **[TECHNICAL_NOTES.md](TECHNICAL_NOTES.md)** — contracts, decoding, evidence,
  provider details, and implementation rationale.
- **[HANDOFF.md](HANDOFF.md)** — chronological collaboration and experiment log.

In one sentence: ellmer handles LLM transport; this project gathers dated clinical
evidence, constructs auditable cohort variables, and evaluates them.

> ⚠️ Clinical data must **never** be committed to this repo. See `.gitignore`.
> The name `extraction-engine` is a placeholder.
