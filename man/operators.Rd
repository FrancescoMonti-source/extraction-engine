\name{index_event}
\alias{index_event}
\alias{any_positive}
\alias{hit_set_expr}
\alias{hit_set_difference}
\alias{bin_output}
\alias{num_output}
\alias{cat_output}
\alias{date_output}
\alias{struct_output}
\title{Compose anchors, channel algebra, and outputs}
\usage{
index_event(source, selector, at = NULL, select_event = NULL)

any_positive()

hit_set_expr(expr)

hit_set_difference(include, exclude = character())

bin_output()

num_output(values_from = NULL, reduce = NULL)

cat_output(
  levels,
  values_from = NULL,
  reduce = NULL,
  description = NULL,
  rationale = NULL
)

date_output(values_from = NULL, reduce = NULL)

struct_output(fields)
}
\arguments{
\item{source,selector}{The source and selector used to derive an index event.}
\item{at}{Optional source date column; otherwise the registered source clock.}
\item{select_event}{Optional plain function selecting matched event rows.}
\item{expr}{A hit-set expression using channel names and \code{|}, \code{&},
\code{!}, and parentheses.}
\item{include,exclude}{Channel names for difference sugar.}
\item{values_from}{The channel carrying an output payload.}
\item{reduce}{A plain function reducing payload values to one value.}
\item{levels}{Allowed categorical values. For a \code{lucene_llm} variable these
levels also define the model's generated \pkg{ellmer} value enum.}
\item{description}{Optional study-owned meaning of a categorical output. For a
\code{lucene_llm} variable this becomes the description of the generated
\pkg{ellmer} value enum; the engine supplies descriptions for the enclosing
object and evidence identifiers.}
\item{rationale}{Optional study-owned description of a short rationale requested
from a \code{lucene_llm} model. When supplied, the generated structured response
requires a non-empty \code{rationale} string and the published values include it.}
\item{fields}{Names of fields emitted by a structured text definition.}
}
\value{A typed operator, anchor, or output specification.}
\description{
These objects describe mechanical execution. Hit-set expressions operate on
observed row membership and do not encode clinical ontology.
}
