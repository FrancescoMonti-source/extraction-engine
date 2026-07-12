\name{new_task_definition}
\alias{new_task_definition}
\alias{binary_presence_text_definition}
\title{Define structured text measurements}
\usage{
new_task_definition(
  name,
  system_prompt,
  type_builder,
  prompt_builder,
  parser,
  summary_field = NULL,
  summary_required = FALSE
)

binary_presence_text_definition(
  name,
  status_key,
  field,
  system_prompt,
  evidence_max_items = 5L
)
}
\arguments{
\item{name}{Definition name.}
\item{system_prompt}{Task-owned system instruction.}
\item{type_builder}{Function from supplied snippet IDs to an \pkg{ellmer} type.}
\item{prompt_builder}{Function from a task row and candidate rows to a prompt.}
\item{parser}{Function validating the structured result and its evidence IDs.}
\item{summary_field}{Optional field name used for a task summary.}
\item{summary_required}{Whether a non-empty summary is required.}
\item{status_key}{Structured response key containing documented status.}
\item{field}{Engine output field name.}
\item{evidence_max_items}{Maximum evidence identifiers in the generated type.}
}
\value{A text task definition consumed by \code{text_channel()} or
\code{use_channel()}.}
\description{
Task definitions own the response schema and parser. The engine controls the call,
evidence resolution, failure isolation, and audit envelope.
}
