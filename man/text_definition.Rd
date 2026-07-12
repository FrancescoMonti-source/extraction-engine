\name{llm_task}
\alias{llm_task}
\title{Define an LLM extraction task}
\usage{
llm_task(prompt)
}
\arguments{
\item{prompt}{One detailed instruction describing how the model should derive
the study variable from the supplied excerpts.}
}
\value{An LLM task consumed by \code{use_channel(extractor = ...)}.}
\description{
An LLM task contains only the study-authored prompt. For a categorical text
variable, the engine derives the structured \pkg{ellmer} response type from
\code{cat_output()}, appends numbered candidate excerpts, validates returned
evidence identifiers, and records provenance.
}
\details{
The prompt owns the meaning of the requested variable. The engine does not
judge clinical or scientific correctness and does not require users to write a
prompt builder, response parser, or dynamic evidence schema.
}
