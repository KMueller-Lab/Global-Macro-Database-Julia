# Cached metadata getters + the versioned dataset loader. These mirror the
# @lru_cache getters in the Python package (_versions_df, _varlist_df, ...) and
# the MATLAB persistent-cached table functions. The cache is process-lifetime
# and is cleared by use_fixtures / reset_backend.

const _TABLE_CACHE = Dict{Symbol,Any}()

_cached(f, key::Symbol) = get!(f, _TABLE_CACHE, key)

"Sort a versions table newest first by the YYYY_MM string. Ports `_sort_versions_df`."
function sort_versions(df::DataFrame)
    v = string.(df.versions)
    keys = map(v) do s
        m = match(r"(\d{4})_(\d{2})", s)
        m === nothing ? (0, 0) : (parse(Int, m.captures[1]), parse(Int, m.captures[2]))
    end
    return df[sortperm(keys; rev=true), :]
end

function versions_df()
    _cached(:versions) do
        raw = read_csv_remote("helpers/versions.csv")
        "versions" in names(raw) || fetch_error("Malformed versions.csv")
        sort_versions(raw)
    end
end

varlist_df() = _cached(:varlist) do
    read_csv_remote("helpers/varlist.csv")
end

source_list_df() = _cached(:source_list) do
    read_csv_remote("helpers/source_list.csv")
end

country_df() = _cached(:country) do
    read_dta_remote("helpers/countrylist.dta")
end

bib_df() = _cached(:bib) do
    read_csv_remote("helpers/bib_dataframe.csv")
end

"""
    dataset_table(ver, fast)

Load the full dataset for a version, using the local cache. Reads the versioned
`.dta` release so values match the Stata/Python/R packages exactly. When `fast`
is true the download is persisted under the cache directory. Ports `datasetTable`.
"""
function dataset_table(ver::AbstractString, fast::Bool)
    d = ensure_cache_dir()
    localver = joinpath(d, "GMD_$(ver).dta")
    isfile(localver) && return _read_dta(localver)

    relpath = "distribute/GMD_$(ver).dta"
    if fast
        tmp = tempname() * ".dta"
        fetch_from(relpath, tmp)
        (isfile(tmp) && filesize(tmp) > 0) ||
            fetch_error("Refusing to cache empty file for $localver")
        mv(tmp, localver; force=true)
        cp(localver, joinpath(d, "GMD.dta"); force=true)
        emit("GMD dataset loaded and saved locally in $d.")
        return _read_dta(localver)
    else
        return read_dta_remote(relpath)
    end
end
