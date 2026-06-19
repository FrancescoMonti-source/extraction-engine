# extraction-engine (placeholder name)

Design seed for the focused successor to `gptr`: an auditable, local-first
engine that turns clinical free text **and** structured EHR sources (ICD-10,
CCAM, labs) into validated, evidenced, **evaluated** analytical variables for
longitudinal cohort studies.

**No code yet.** The whole design — architecture, rationale, open questions, and
a phased build plan — lives in **[DESIGN.md](DESIGN.md)**. Start there.

One-line architecture: four layers (anchor → extract → construct → derive) over
three linked contracts — **attempt / hit / value** (the hit is the narrow waist).
There are two kinds of variable: an **observed task** is data across four axes
(anchor × scope × construction-policy × sources); a **derived** variable is just
plain R over already-produced columns. ellmer is the transport engine; evaluation
against gold is the centerpiece.

> ⚠️ Clinical data must **never** be committed to this repo. See `.gitignore`.
> The name `extraction-engine` is a placeholder.
