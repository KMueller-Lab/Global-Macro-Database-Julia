"""
    GMD

Julia access to the [Global Macro Database](https://www.globalmacrodata.com):
a single [`gmd`](@ref) function that fetches and caches the published
macroeconomic data. This is the Julia port of the Python, R and MATLAB
packages; see the README for usage.
"""
module GMD

using DataFrames
using CSV
using HTTP

include("config.jl")
include("helpers.jl")
include("dta.jl")
include("fetch.jl")
include("tables.jl")
include("dispatch.jl")

export gmd, get_available_versions, get_current_version,
       list_variables, list_countries, GMDCommandError

end # module
