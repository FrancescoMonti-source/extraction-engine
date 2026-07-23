\name{variable_spec}
\alias{concept_spec}
\alias{variable_spec}
\alias{use_channel}
\alias{resolve_variable_spec}
\alias{inspect}
\title{Author and compile study variable specifications}
\usage{
concept_spec(name, channels)

variable_spec(
  name,
  anchor = NULL,
  channels = list(),
  combine = NULL,
  output = NULL
)

use_channel(
  channel,
  concept = NULL,
  selector = NULL,
  filter_rows = NULL,
  group_by = NULL,
  filter_groups = NULL,
  search_within = NULL,
  window = NULL,
  method = NULL,
  model = NULL,
  model_params = list(),
  response = NULL,
  rationale = TRUE,
  user_prompt = NULL,
  system_prompt = NULL,
  max_candidates = NULL
)

resolve_variable_spec(variable)

inspect(x, ...)
}
\arguments{
\item{name}{One non-empty name. For \code{variable_spec()}, this is the canonical
public variable identifier used by results, inspection, audit, and protocol
naming; the local R binding is not an identifier.}
\item{channels}{For \code{concept_spec()}, a named catalog of channel
definitions. For \code{variable_spec()}, a named list of \code{use_channel()}
activations; character shorthand and bare inline channels are not accepted.}
\item{concept}{For a character \code{channel}, the concept specification whose
catalog owns that channel. It must be \code{NULL} for an inline channel
definition. A variable has no single global concept, so different activations
may use different concept specifications.}
\item{anchor}{\code{NULL}, the exact name of a \code{Date} or \code{POSIXt}
column supplied by the cohort, or an \code{index_event()}. A cohort column is
shared by the variable's windowed activations and must have one non-missing value
per output unit when consumed.}
\item{output}{A \code{bin_output(group_by)} or \code{from_channel()} specification.}
\item{combine}{Optional \code{combine_channels(expr, by)} specification. Its
expression uses activation aliases, and \code{by} is the key where their signals
must coexist. A payload-only activation need not occur in the expression. A
\code{lucene_llm} activation cannot currently occur because a valid structured
response does not implicitly define positive membership; it may still be
published with \code{from_channel()}.}
\item{channel}{Mandatory origin for this activation: one channel name paired
with its owning \code{concept}, or one self-contained inline channel definition.
It cannot name another activation alias.}
\item{selector}{Optional local replacement for the origin channel's selector.}
\item{filter_rows}{Optional per-task data-masked expression over real
prepared-source columns. It returns one logical per row; missing results are
treated as false.}
\item{group_by}{Optional \code{"PATID"}, \code{"EVTID"}, or \code{"ELTID"}
intermediate grouping key for \code{filter_groups}. This activation-local
argument does not set the final output grain; output constructors have their own
mandatory \code{group_by}.}
\item{filter_groups}{A data-masked expression evaluated on survivors of
\code{filter_rows}. It must return exactly one non-missing logical per group.}
\item{search_within}{Text-source search relation, \code{"PATID"} or
\code{"EVTID"}. It is mandatory for text activations and does not determine
combine, payload, or output grain.}
\item{window}{Activation-specific \code{NULL} or
\code{c(from_days, to_days)} relative to the variable's explicit anchor.}
\item{method}{For text channels, \code{"lucene"} or
\code{"lucene_llm"}; non-text activations leave it \code{NULL}.}
\item{model}{Optional non-empty Ollama model name owned by this activation.
It is valid only for \code{lucene_llm} and is required for automatic execution
unless \code{run_variable()} receives an explicit \pkg{ellmer} Chat override.}
\item{model_params}{Named parameters used to construct this activation's Chat.
Non-empty parameters require \code{model}.}
\item{response}{For \code{lucene_llm}, a native \pkg{ellmer}
\code{TypeObject} describing every authored response field.}
\item{rationale}{For \code{lucene_llm}, omission or \code{TRUE} adds the
package's required generic rationale field; a non-empty string overrides its
description; \code{FALSE} or \code{NULL} omits it.}
\item{user_prompt}{Optional prefix for cross-field user instructions. The engine
appends the target and numbered evidence excerpts.}
\item{system_prompt}{Optional override of the package's general structured-data
system prompt.}
\item{max_candidates}{Optional positive integer limiting Lucene candidates
supplied to the model.}
\item{variable}{An authored or compiled variable specification.}
\item{x}{An object with an \code{inspect()} method.}
\item{...}{Arguments passed to an S3 inspection method.}
}
\value{
Authoring functions return typed specifications. \code{resolve_variable_spec()}
and \code{inspect()} return the compiled representation consumed by execution
and provenance.
}
\description{
These constructors record the researcher's executable operational definition:
concepts locate rows, each activation names its own concept/channel origin and
controls variable-local use, and the output publishes membership or an explicit
channel payload.
}
\details{
Text activations must declare \code{search_within}. Event-level search requires
an EVTID-bearing task through \code{output$group_by = "EVTID"} or
\code{index_event()}. Output \code{group_by} is always explicit and is the only
source of final grain. When \code{combine$by} is finer than that grain, a
\code{from_channel()} output must set \code{filter_by_qualified} to either the
combine key or the output key; it must be \code{NULL} in all other grain
relationships. Execution then proceeds as combine by, filter by qualified,
group by, and evaluate the output value expression. Prepared-source columns are
available as bare names in data-masked expressions; \code{.data} supports
programmatic selection and \code{.env} disambiguates external values.

For \code{lucene_llm}, authored instructions live in the TypeObject and its
field descriptions. The engine dynamically adds the optional rationale and an
evidence-ID enum limited to supplied snippets, then delegates structured output
to \code{ellmer::chat_structured()}. Model and transport parameters belong to
the individual activation, so one variable may activate more than one model. An
explicit response-to-hit rule is not yet implemented, so LLM activations are
rejected when referenced by \code{combine = combine_channels(...)}; use
\code{method = "lucene"} when retrieval-hit presence is the intended signal.
}
