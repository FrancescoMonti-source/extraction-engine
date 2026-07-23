\name{code_channel}
\alias{code_channel}
\alias{act_channel}
\alias{lab_channel}
\alias{text_channel}
\alias{doc_channel}
\alias{icd10}
\alias{ccam}
\alias{lucene_query}
\alias{doc_meta}
\alias{analyte}
\title{Declare source channels and selectors}
\usage{
code_channel(source, selector, native_grain = NA_character_,
  required_roles = character())

act_channel(source, selector, native_grain = NA_character_,
  required_roles = character())

lab_channel(source = "biology", selector, native_grain = NA_character_,
  required_roles = character())

text_channel(selector, source = "documents", native_grain = NA_character_,
  required_roles = character())

doc_channel(source, selector, native_grain = NA_character_,
  required_roles = character())

icd10(pattern, match = c("regex", "exact"))

ccam(codes, match = c("exact", "regex"))

lucene_query(query)

doc_meta(...)

analyte(codes)
}
\arguments{
\item{source}{A logical source name. Lab and text channels default to
\code{"biology"} and \code{"documents"}; callers may override them for another
registered source. Caller objects are bound through
\code{run_variable(sources =)}.}
\item{selector}{A selector compatible with the channel type.}
\item{native_grain}{Optional descriptive native grain.}
\item{required_roles}{Source roles the channel requires.}
\item{pattern,codes}{Code values or analyte \code{TYPEANA} values.}
\item{match}{Exact or regular-expression matching.}
\item{query}{One non-empty Lucene query.}
\item{...}{Uniquely named document-metadata filters.}
}
\value{A channel or selector specification.}
\description{
Channels locate possible signal rows. They do not choose the output payload or
assign clinical meaning. \code{analyte()} selects rows by \code{TYPEANA} only;
the prepared-source columns used by a deterministic result are referenced later
inside \code{from_channel(value =)}.
}
\details{
Relational text eligibility and row/group filtering are variable-local execution
rules declared by \code{use_channel()}, not properties of a concept channel.
Its row and group predicates are data-masked expressions over the prepared-source
columns.
Its \code{group_by} is an intermediate grouping used only with
\code{filter_groups}; the output constructor's mandatory \code{group_by} alone
defines the published grain.
}
