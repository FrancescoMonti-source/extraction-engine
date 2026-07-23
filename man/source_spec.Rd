\name{source_spec}
\alias{source_spec}
\alias{source_roles}
\alias{validate_source_view}
\alias{edsan_source_specs}
\title{Declare and validate prepared EDSAN source views}
\usage{
source_spec(
  name,
  module,
  table,
  roles,
  required_columns = NULL,
  unique_columns = character()
)

source_roles(spec)

validate_source_view(data, spec)

edsan_source_specs()
}
\arguments{
\item{name}{One descriptive source name.}
\item{module,table}{An EDSAN module and normalized table known to
\code{redsan::edsan_sources()}.}
\item{roles}{A named list mapping engine roles to columns of the prepared view.}
\item{required_columns}{Columns that must be present. By default, all role-bound
columns; an explicit subset permits role-bound provenance columns to remain
optional.}
\item{unique_columns}{Columns required to be non-missing and unique.}
\item{spec}{A source specification.}
\item{data}{A prepared data frame. Values are validated but never coerced.}
}
\value{
\code{source_spec()} returns a source specification; \code{source_roles()} returns
its role map; \code{validate_source_view()} returns \code{data} invisibly;
\code{edsan_source_specs()} returns the package's prepared-view specifications.
}
\description{
Source mechanics are read from the live \pkg{redsan} registry. These functions
bind already typed view columns to engine roles and fail closed on incompatible
inputs; they do not parse warehouse values.

The built-in biology contract requires the generic source-item coordinate
\code{ELTID}. Native \code{BIOL_ID} is retained with canonical casing when
available but is optional for execution.
}
