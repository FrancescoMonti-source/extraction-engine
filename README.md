# extraction-engine (placeholder name)

Design seed for the focused successor to `gptr`: an auditable, local-first
engine that turns clinical free text **and** structured EHR sources (ICD-10,
CCAM, labs) into validated, evidenced, **evaluated** analytical variables for
longitudinal cohort studies.

**No code yet.** The whole design — architecture, rationale, open questions, and
a phased build plan — lives in **[DESIGN.md](DESIGN.md)**. Start there.

One-line architecture: four layers (anchor → extract → construct → derive) over a
narrow-waist **hit** contract `(subject, date, value, source, evidence)`; a
variable is data across four dimensions (anchor × window × behaviour × sources);
ellmer as the transport engine; evaluation against gold as the centerpiece.

> ⚠️ Clinical data must **never** be committed to this repo. See `.gitignore`.
> The name `extraction-engine` is a placeholder.
