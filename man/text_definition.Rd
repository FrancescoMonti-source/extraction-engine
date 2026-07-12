\name{llm_task}
\alias{llm_task}
\alias{binary_presence_text_definition}
\title{Define explicit LLM tasks}
\usage{
llm_task(
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
\item{type_builder}{Function from supplied snippet IDs to a plain
\pkg{ellmer} response type. Keeping this builder in the authored specification
makes the model-visible schema explicit while allowing evidence IDs to be
constrained per task.}
\item{prompt_builder}{Function from a task row and candidate rows to a prompt.}
\item{parser}{Function validating the structured result and its evidence IDs.}
\item{summary_field}{Optional field name used for a task summary.}
\item{summary_required}{Whether a non-empty summary is required.}
\item{status_key}{Structured response key containing documented status.}
\item{field}{Engine output field name.}
\item{evidence_max_items}{Maximum evidence identifiers in the generated type.}
}
\value{An explicit LLM task consumed by \code{text_channel()} or
\code{use_channel()}.}
\description{
An LLM task keeps its instruction, plain \pkg{ellmer} response type, prompt, and
parser together in the study specification. The engine controls the call,
evidence resolution, failure isolation, and audit envelope.
}
