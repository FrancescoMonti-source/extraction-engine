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
  concept,
  output_one_row_per = "PATID",
  anchor = NULL,
  window = NULL,
  channels = list(),
  output = NULL,
  combine_channels = NULL,
  combine_at_level = NULL,
  model = NULL,
  model_params = list()
)

use_channel(method = NULL, extractor = NULL, selector = NULL,
  keep_when = NULL, reducer = NULL)

resolve_variable_spec(variable)

inspect(x, ...)
}
\arguments{
\item{name}{One non-empty name.}
\item{channels}{For \code{concept_spec()}, a named channel catalog; for
\code{variable_spec()}, activated or inline channels.}
\item{concept}{A concept specification that supplies channel definitions.}
\item{output_one_row_per}{The output-grain column, usually \code{"PATID"} or
\code{"EVTID"}.}
\item{anchor}{\code{NULL}, a typed task date column, or an \code{index_event()}.
A named task column is normalized to the internal execution clock.}
\item{window}{\code{NULL} or \code{c(from_days, to_days)} relative to an explicit
anchor.}
\item{output}{An output constructor result.}
\item{combine_channels}{A hit-set expression string or combiner.}
\item{combine_at_level}{Optional identity-spine key at which to evaluate a
multi-channel expression.}
\item{model}{Optional Ollama model name owned by this variable. It is required
for automatic execution of selected text channels unless \code{run_variable()}
receives an explicit \pkg{ellmer} Chat override.}
\item{model_params}{Named list of parameters used when constructing this
variable's Ollama Chat.}
\item{method,extractor,selector}{Optional local replacements for an activated
channel. A selector replaces the complete inherited selector.}
\item{keep_when}{Optional row predicate that extends an inherited analyte
selector without repeating its analyte codes. Its formal arguments name source
row columns.}
\item{reducer}{Retired argument; reduction belongs to the output and is rejected.}
\item{variable}{An authored or compiled variable specification.}
\item{x}{An object with an \code{inspect()} method.}
\item{...}{Arguments passed to an S3 inspection method.}
}
\value{
Authored functions return typed specification objects.
\code{resolve_variable_spec()} and \code{inspect()} return the single compiled
representation consumed by execution and provenance.
}
\description{
These constructors record the researcher's executable operational definition.
They validate every accepted argument and do not judge its scientific correctness.
}
