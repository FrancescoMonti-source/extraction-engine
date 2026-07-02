# extraction-engine (placeholder name)

Auditable, local-first extraction framework for turning stable hospital data
warehouse sources into protocol-specific analytical variables.

Project data preparation remains upstream: the files supplied in `/data` already define
the study population and outer protocol period. The engine only constructs variables
within that supplied study universe.

The engine is HDW-aware and protocol-agnostic. It exposes source-backed signal
channels, executes concrete `variable_spec`s, and returns values with traceable
coverage, evidence, and provenance. Researchers remain responsible for clinical and
scientific interpretation.

The LLM step is review-by-design. The engine does not claim LLM accuracy; it
guarantees controlled, auditable execution around the LLM call. See
[`DESIGN.md`](DESIGN.md) §1 and §9.

Run the deterministic test suite with:

```sh
Rscript tests/testthat.R
```

Start with:

- **[DESIGN.md](DESIGN.md)** — the target architecture and vocabulary contract (§16 lists deferred capabilities gated on a consumer).
- **[HANDOFF.md](HANDOFF.md)** — chronological collaboration log for maintainers.

In one sentence: ellmer handles LLM transport; this project gathers dated clinical
evidence, constructs auditable cohort variables, and evaluates them.

> ⚠️ Clinical data must **never** be committed to this repo. See `.gitignore`.
> The name `extraction-engine` is a placeholder.
