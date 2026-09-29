# Network layer + local cache + the test seam. Ports _fetch_from / the remote
# readers / the cache helpers from the Python package and the MATLAB port.

# Test seam: when a fixture root is set, fetches are served from disk instead of
# the network; when a cache override is set, the cache lives there. Production
# code never sets either, so behaviour is unchanged by default.
const _FIXTURE_ROOT = Ref("")
const _CACHE_OVERRIDE = Ref("")

"""
    use_fixtures(root, cache="")

Route every fetch to files under `root` (mirroring the release-bucket paths)
instead of the network, and optionally redirect the local cache to `cache` so
tests never touch the real `~/.global_macro_data`. Clears the memoized getters.
"""
function use_fixtures(root::AbstractString, cache::AbstractString="")
    isdir(root) || throw(GMDCommandError(498, "Fixture root does not exist: $root"))
    _FIXTURE_ROOT[] = String(root)
    isempty(cache) || (_CACHE_OVERRIDE[] = String(cache))
    empty!(_TABLE_CACHE)
    return nothing
end

"Undo [`use_fixtures`](@ref): fetch from the network again and clear the caches."
function reset_backend()
    _FIXTURE_ROOT[] = ""
    _CACHE_OVERRIDE[] = ""
    empty!(_TABLE_CACHE)
    return nothing
end

"Path to the local cache directory (`~/.global_macro_data`), honouring the test override."
function cache_dir()
    isempty(_CACHE_OVERRIDE[]) || return _CACHE_OVERRIDE[]
    home = homedir()
    return joinpath(home, ".global_macro_data")
end

function ensure_cache_dir()
    d = cache_dir()
    isdir(d) || mkpath(d)
    return d
end

"List versions cached locally as `GMD_<ver>.dta` (newest first). Ports `_cache_versions`."
function cache_versions()
    d = cache_dir()
    isdir(d) || return String[]
    found = String[]
    for f in readdir(d)
        m = match(r"^GMD_(\d{4}_\d{2})\.dta$", f)
        m === nothing || push!(found, m.captures[1])
    end
    return sort(unique(found); rev=true)
end

"""
    fetch_from(relpath, destfile; bases=DATA_BASES)

Download a file from the release bucket to `destfile`. Walks `bases` in order
(S3 primary, then the GitHub mirror), retrying with exponential backoff and
skipping retries on clear 4xx client errors. Throws on total failure. The
GitHub mirror only serves `helpers/*` tables. Ports `_fetch_from`.
"""
function fetch_from(relpath::AbstractString, destfile::AbstractString; bases=DATA_BASES)
    if !isempty(_FIXTURE_ROOT[])
        src = joinpath(_FIXTURE_ROOT[], split(relpath, "/")...)
        isfile(src) || fetch_error("Local test resource not found: $src")
        cp(src, destfile; force=true)
        return true
    end

    errors = String[]
    for base in bases
        url = "$base/$relpath"
        for attempt in 1:MAX_RETRIES
            try
                resp = HTTP.get(url; headers=["User-Agent" => USER_AGENT],
                                readtimeout=TIMEOUT, retry=false, status_exception=true)
                open(destfile, "w") do io
                    write(io, resp.body)
                end
                return true
            catch err
                status = err isa HTTP.StatusError ? err.status : 0
                push!(errors, "$url: $(sprint(showerror, err))")
                (400 <= status < 500) && break   # client error will not recover
                attempt < MAX_RETRIES && sleep(BACKOFF_BASE * 2.0^(attempt - 1))
            end
        end
    end
    fetch_error("Unable to load '$relpath'. " * join(errors, "; "))
end

"Download a CSV endpoint into a DataFrame, preserving column names. Ports `_read_csv_primary`."
function read_csv_remote(relpath::AbstractString; bases=DATA_BASES)
    tmp = tempname() * ".csv"
    try
        fetch_from(relpath, tmp; bases=bases)
        return CSV.read(tmp, DataFrame)
    finally
        isfile(tmp) && rm(tmp; force=true)
    end
end

"Download a .dta endpoint and read it into a DataFrame. Wraps `fetch_from` + the reader."
function read_dta_remote(relpath::AbstractString; bases=DATA_BASES)
    tmp = tempname() * ".dta"
    try
        fetch_from(relpath, tmp; bases=bases)
        return _read_dta(tmp)
    finally
        isfile(tmp) && rm(tmp; force=true)
    end
end
