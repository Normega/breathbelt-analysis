# =====================================================================
#  utils.R — small helpers with no domain meaning
#
#  Anything here is generic plumbing. Keeping it out of the analysis files
#  matters for more than tidiness: a helper defined in, say, quality.R and
#  used everywhere makes every other file look as though it depends on the
#  quality module, which obscures the layering the package is built around.
# =====================================================================

# NULL-coalescing. R gained a native `%||%` in 4.4.0; this definition keeps
# the package working on 4.1 and later, which is what DESCRIPTION claims.
`%||%` <- function(a, b) if (is.null(a)) b else a
