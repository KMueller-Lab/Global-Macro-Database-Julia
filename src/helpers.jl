# Small argument-coercion and formatting helpers. Ports the equivalent
# _coerce_flag / _coerce_year / _kw / _tokens / _fail / _emit helpers from the
# Python package (and the matching MATLAB private functions).

"""
    GMDCommandError(code, msg; data=nothing)

Error type raised by every `gmd` failure. `code` mirrors the Stata/Python
error codes (e.g. 498, 198). All failures funnel through [`fail`](@ref).
"""
struct GMDCommandError <: Exception
    code::Int
    msg::String
    data::Any
end
GMDCommandError(code::Integer, msg::AbstractString; data=nothing) =
    GMDCommandError(Int(code), String(msg), data)

function Base.showerror(io::IO, e::GMDCommandError)
    print(io, "GMDCommandError(", e.code, "): ", e.msg)
end

"""
    GMDFetchError(msg)

Raised when a download (or a test-fixture read) fails. Kept distinct from
[`GMDCommandError`](@ref) so the offline fallback can tell a network failure
apart from a genuine validation error. Ports the MATLAB `GMD:fetch` identifier.
"""
struct GMDFetchError <: Exception
    msg::String
end
Base.showerror(io::IO, e::GMDFetchError) = print(io, "GMDFetchError: ", e.msg)
fetch_error(msg::AbstractString) = throw(GMDFetchError(String(msg)))

"""
    fail(code, lines...)

Raise a [`GMDCommandError`](@ref). Never returns. Message lines are joined with
newlines, matching the single error funnel in the other ports.
"""
function fail(code::Integer, lines...; data=nothing)
    msg = join(string.(lines), "\n")
    isempty(msg) && (msg = "GMD command error")
    throw(GMDCommandError(code, msg; data=data))
end

"Print each argument on its own line (ports the Python `_emit`)."
emit(lines...) = (for l in lines; println(string(l)); end; nothing)

"Coerce a logical / boolean-like string to a `Bool`. Ports `_coerce_flag`."
function coerce_flag(value, name::AbstractString="flag")
    value === nothing && return false
    value isa Bool && return value
    if value isa Real
        value == 1 && return true
        value == 0 && return false
        fail(498, "Invalid value for $name: $value")
    end
    if value isa AbstractString
        token = lowercase(strip(value))
        token in ("yes", "y", "true", "t", "on", "1") && return true
        token in ("no", "n", "false", "f", "off", "0", "") && return false
        fail(498, "Invalid value for $name: $value")
    end
    fail(498, "Invalid type for $name")
end

"Coerce a year argument to an `Int`, or `nothing` when unset. Ports `_coerce_year`."
function coerce_year(value, name::AbstractString="year")
    value === nothing && return nothing
    if value isa Real && isfinite(value)
        return round(Int, value)
    end
    if value isa AbstractString
        s = strip(value)
        n = tryparse(Float64, s)
        n === nothing || return round(Int, n)
    end
    fail(498, "$name must be an integer year, got $(value)")
end

"""
    kw(value, words)

Lower-case a string argument only when it is one of `words`; leave real version
numbers, source names and cite keys untouched. Ports the inner `_kw` helper.
"""
function kw(value, words)
    if value isa AbstractString
        lowered = lowercase(strip(value))
        lowered in words && return lowered
    end
    return value
end

"""
    tokens(v) -> Vector{String}

Normalize an argument into string tokens, splitting on whitespace and commas
and dropping empties. Ports the Python `_tokens` helper.
"""
function tokens(v)::Vector{String}
    v === nothing && return String[]
    parts = if v isa AbstractString
        [v]
    elseif v isa AbstractVector || v isa Tuple
        [x isa AbstractString ? x : string(x) for x in v]
    elseif v isa Real
        [string(v)]
    else
        fail(498, "Unsupported argument type for tokens()")
    end
    out = String[]
    for p in parts
        for piece in split(p, r"[\s,]+")
            s = strip(piece)
            isempty(s) || push!(out, String(s))
        end
    end
    return out
end

"Pretty-print a one-line BibTeX entry onto multiple lines. Ports `_format_bibtex_for_print`."
function format_bibtex(entry)
    s = strip(string(entry))
    s = replace(s, r",\s*([a-zA-Z0-9_]+\s*=)" => s",\n  \1")
    s = replace(s, r"\}\s*$" => "\n}")
    return s
end

# Public name of a country source: CS<n>_<ISO3>, any number of digits, any case.
const CS_ALIAS = r"^CS(\d+)_([A-Za-z]{3})$"i

"Convert a CS alias (e.g. \"CS1_ARG\", \"cs10_ita\") to its file name (\"ARG_1\", \"ITA_10\"). Ports `_normalize_source_name`."
function normalize_source_name(source)
    s = strip(string(source))
    m = match(CS_ALIAS, s)
    m === nothing && return s
    return string(uppercase(m.captures[2]), "_", m.captures[1])
end

"Column prefix inside a CS alias's file (\"CS10\" for \"cs10_ita\"); \"\" for any other name."
function cs_column_prefix(source)
    m = match(CS_ALIAS, strip(string(source)))
    return m === nothing ? "" : string("CS", m.captures[1])
end

"Raise a GMD error when a mode requires internet access. Ports `_fail_needs_internet`."
fail_needs_internet(action) =
    fail(498, "You need access to the internet in order to $action", NETWORK_HINT)

"Raise a GMD error pointing at the issue tracker. Ports `_fail_with_issue`."
fail_with_issue(resource) =
    fail(498, "Unable to access $resource. Please raise an issue at $ISSUES_URL")

"Drop the \"<source>_\" prefix from data column names (skips ISO3/year). Ports `_strip_source_prefix_cols`."
function strip_source_prefix(cols, source)
    pref = string(source, "_")
    out = String[]
    for c in string.(cols)
        (c == "ISO3" || c == "year") && continue
        if startswith(c, pref)
            push!(out, c[length(pref)+1:end])
        else
            push!(out, c)
        end
    end
    return out
end
