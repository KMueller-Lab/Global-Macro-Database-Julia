# The gmd() dispatcher, its print modes, and the public helper functions.
# Ports gmd.py / gmd.m: parse arguments, then branch through the mutually
# exclusive modes in a fixed order.

function _first_member(candidates, cols)
    for c in candidates
        c in cols && return c
    end
    return nothing
end

"Keep rows within [start_year, end_year]. Ports `_apply_year_range`."
function apply_year_range(df::DataFrame, start_year, end_year)
    (start_year === nothing && end_year === nothing) && return df
    "year" in names(df) || return df
    years = df[!, :year]
    mask = trues(nrow(df))
    start_year !== nothing && (mask .&= map(y -> !ismissing(y) && y >= start_year, years))
    end_year !== nothing && (mask .&= map(y -> !ismissing(y) && y <= end_year, years))
    return df[mask, :]
end

function _drop_all_missing_columns(df::DataFrame)
    keep = [c for c in names(df) if !all(ismissing, df[!, c])]
    return df[:, keep]
end

# --- printing ----------------------------------------------------------------
function _print_var_table(t::DataFrame)
    cols = names(t)
    if !("variable" in cols) && "variables" in cols
        rename!(t, "variables" => "variable")
        cols = names(t)
    end
    all(c -> c in cols, ("variable", "definition", "units")) || fail_with_issue("variable list")

    vname = string.(coalesce.(t.variable, ""))
    vdef = string.(coalesce.(t.definition, ""))
    vunit = string.(coalesce.(t.units, ""))

    varlen = maximum(length.(vname)) + 2
    deflen = maximum(length.(vdef)) + varlen + 2

    emit("", "Available variables:", "")
    emit("-"^90)
    emit(string(rpad("Variable", varlen), rpad("Definition", deflen - varlen), "Units"))
    emit("-"^90)
    for i in eachindex(vname)
        left = rpad(vname[i], varlen)
        emit(string(left, rpad(vdef[i], max(deflen - length(left), 1)), vunit[i]))
    end
    emit("-"^90)
end

function _print_country_table(t::DataFrame)
    all(c -> c in names(t), ("countryname", "ISO3")) || fail_with_issue("country list")
    emit("", "Available countries:", "")
    emit("-"^90)
    emit("ISO3 code  Country name")
    emit("-"^90)
    iso = string.(coalesce.(t.ISO3, ""))
    nm = string.(coalesce.(t.countryname, ""))
    for i in eachindex(iso)
        emit(string(rpad(iso[i], 10), nm[i]))
    end
    emit("-"^90)
end

function _print_summary(df, anything, country, selected_version, version_opt, raw, sources, fast, saved_gmd)
    nvars = ncol(df)
    for c in ID_COLS
        c in names(df) && (nvars -= 1)
    end
    nvars <= 0 && fail(498, "The database has no data on $anything for $country")
    nrow(df) <= 0 && return nothing

    emit("Global Macro Database by Müller, Xu, Lehbib, and Chen (2025)")
    emit("Website: https://www.globalmacrodata.com")
    emit("")
    emit("When using these data, please cite:")
    emit("For BibTeX: gmd(cite=\"GMD\")  |  For APA: gmd(print_option=\"GMD\")")
    emit("")
    emit("When using the gmd command, please further cite:")
    emit("For BibTeX: gmd(cite=\"lehbib2025gmd\")  |  For APA: gmd(print_option=\"Stata\")")
    emit("")

    has_sources = !(sources === nothing) && !isempty(string(sources))
    if !fast && !saved_gmd && !raw
        emit("To save the data locally for faster reloading, use: " *
             "gmd(version=\"$selected_version\", fast=\"yes\")")
    end

    if raw || has_sources
        emit("Final dataset: $(nrow(df)) observations of $nvars variables")
    else
        noun = nvars > 1 ? "variables" : "variable"
        emit("Final dataset: $(nrow(df)) observations for $nvars $noun")
    end

    if version_opt !== nothing && !isempty(string(version_opt))
        emit("Version: $(string(version_opt))")
    else
        emit("Version: $selected_version")
    end
    return nothing
end

# --- source-level loader -----------------------------------------------------
function _load_source_data(src_name, anything, country_arg)
    cs_prefix = ""
    name = strip(string(src_name))
    if length(name) == 7 && startswith(name, "CS")
        cs_prefix = split(name, "_")[1]
        name = normalize_source_name(name)
    end
    src_tokens = tokens(name)
    length(src_tokens) > 1 && fail(498, "Warning: Please specify exactly one source.")
    name = src_tokens[1]

    srcdf = try
        read_dta_remote("clean/combined/$(name).dta")
    catch
        srclist = try
            source_list_df()
        catch
            fail_with_issue("source list")
        end
        m = lowercase.(string.(srclist.source_name)) .== lowercase(name)
        any(m) || fail(498, "Invalid source name", "To load the list of sources: gmd(sources=\"load\")")
        name = string(srclist.source_name[findfirst(m)])
        try
            read_dta_remote("clean/combined/$(name).dta")
        catch
            fail(498, "Unable to load data for source '$name'.",
                 "Please check your internet connection or report this issue.")
        end
    end

    prefix = isempty(cs_prefix) ? name : cs_prefix

    if !isempty(anything)
        srccol = "$(prefix)_$(anything)"
        if srccol in names(srcdf)
            keep = String[]
            for c in ("ISO3", "year", srccol)
                c in names(srcdf) && push!(keep, c)
            end
            "countryname" in names(srcdf) && push!(keep, "countryname")
            "id" in names(srcdf) && push!(keep, "id")
            out = srcdf[:, keep]
            if !isempty(country_arg)
                target = uppercase(country_arg)
                out = out[uppercase.(string.(out.ISO3)) .== target, :]
            end
            return out
        end
        avail = strip_source_prefix(names(srcdf), prefix)
        fail(498, "This source doesn't have data on $anything. It has data on $(join(avail, ' ')).")
    end

    return srcdf
end

# --- main entry point --------------------------------------------------------
"""
    gmd(; variables=nothing, country=nothing, version=nothing, raw=nothing,
          iso=nothing, vars=nothing, sources=nothing, cite=nothing,
          print_option=nothing, network=nothing, fast=nothing,
          start_year=nothing, end_year=nothing) -> DataFrame

Fetch macroeconomic data from the Global Macro Database. With no arguments,
downloads the latest full dataset. Keyword arguments narrow the data down or
switch into one of the metadata / helper modes. Returns a `DataFrame` (or the
metadata table for the `load` modes, or `nothing` for the print-only modes).
See the README for usage. This is the Julia port of the Python, R and MATLAB
packages.
"""
function gmd(; variables=nothing, country=nothing, version=nothing, raw=nothing,
             iso=nothing, vars=nothing, sources=nothing, cite=nothing,
             print_option=nothing, network=nothing, fast=nothing,
             start_year=nothing, end_year=nothing)

    df = nothing

    raw_flag = coerce_flag(raw, "raw")
    iso_flag = coerce_flag(iso, "iso")
    fast_flag = coerce_flag(fast, "fast")

    start_yr = coerce_year(start_year, "start_year")
    end_yr = coerce_year(end_year, "end_year")
    if start_yr !== nothing && end_yr !== nothing && start_yr > end_yr
        fail(498, "start_year ($start_yr) cannot be greater than end_year ($end_yr)")
    end

    country_val = iso_flag ? "list" : country

    vers = version
    vers isa AbstractString && (vers = strip(vers))
    vers = kw(vers, ["list", "current"])
    sources_v = kw(sources, ["load", "list"])
    cite_v = kw(cite, ["load"])
    vars_v = kw(vars, ["load", "list"])

    anything_tokens = tokens(variables)
    anything = join(anything_tokens, " ")
    word_count = length(anything_tokens)

    country_arg = if country_val isa AbstractString
        String(country_val)
    elseif country_val === nothing
        ""
    else
        join(tokens(country_val), " ")
    end

    # --- print_option mode ---------------------------------------------------
    if print_option !== nothing
        option = lowercase(strip(string(print_option)))
        option == "gmd" && (emit(APA_GMD); return nothing)
        option == "stata" && (emit(APA_PACKAGE); return nothing)
        fail(198, "Invalid option for print(). valid arguments are 'GMD' or 'Stata'.")
    end

    # --- version resolution (with offline fallback) --------------------------
    selected_version = ""
    available_versions = String[]
    has_internet = true
    gmd_local_path = ""
    saved_gmd = false

    try
        vt = versions_df()
        selected_version = string(vt.versions[1])
        available_versions = sort(unique(string.(vt.versions)))

        if vers isa AbstractString && vers == "list"
            for v in available_versions
                emit(v)
            end
            return nothing
        end

        if vers !== nothing && !isempty(string(vers))
            req = string(vers)
            length(tokens(req)) != 1 &&
                (emit("Version must either be one specific version ($selected_version) or current."); return nothing)
            if req in available_versions
                selected_version = req
            elseif req == "current"
                emit("Current version: $selected_version")
            else
                fail(498, "Error: Version $req does not exist",
                     "Available versions: $(join(available_versions, " "))")
            end
        end
    catch err
        err isa GMDCommandError && rethrow(err)
        has_internet = network !== nothing && !isempty(string(network))
        emit("Error: Unable to access version information. Check internet connection.")
        emit("Loading local version")
        local_default = joinpath(cache_dir(), "GMD.dta")
        isfile(local_default) || fail(498, "Local version not found")
        gmd_local_path = local_default
        saved_gmd = true
        selected_version = ""
    end

    # --- internet guards for modes that must fetch ---------------------------
    if !has_internet
        if sources_v in ("load", "list")
            fail_needs_internet("fetch the sources list")
        elseif sources_v !== nothing && !isempty(string(sources_v))
            fail_needs_internet("fetch the $(string(sources_v)) data")
        end
        raw_flag && fail_needs_internet("fetch the raw data")
        if cite_v == "load"
            fail_needs_internet("load the sources to cite")
        elseif cite_v !== nothing && !isempty(string(cite_v))
            fail_needs_internet("cite $(string(cite_v))")
        end
    end

    # --- cite mode -----------------------------------------------------------
    if cite_v == "load"
        return try
            bib_df()
        catch
            fail_with_issue("the list of sources to cite")
        end
    end
    if cite_v !== nothing && !isempty(string(cite_v))
        cite_tokens = tokens(cite_v)
        length(cite_tokens) != 1 && fail(498, "Only one citation can be retrieved at a time")
        key = cite_tokens[1]
        bib = bib_df()
        keycol = _first_member(("source_name", "source"), names(bib))
        keycol === nothing && fail(111, "source_name not found")
        "citation" in names(bib) || fail(111, "citation not found")
        mask = lowercase.(string.(bib[!, keycol])) .== lowercase(key)
        any(mask) || fail(498, "Source '$key' does not exist.",
                          "To load the list of sources to cite: gmd(cite=\"load\")")
        emit(format_bibtex(string(bib.citation[findfirst(mask)])))
        return nothing
    end

    # --- sources mode --------------------------------------------------------
    has_sources = sources_v !== nothing && !isempty(string(sources_v))
    if has_sources && raw_flag
        emit("Note: raw option is specified, but this is implicit when using the sources option.")
    end
    if sources_v in ("load", "list")
        srclist = try
            source_list_df()
        catch
            fail_with_issue("source list")
        end
        if sources_v == "load"
            emit("Imported the list of sources.")
            return srclist
        end
        for s in sort(unique(string.(srclist.source_name)))
            emit(s)
        end
        return nothing
    end
    if has_sources
        return _load_source_data(string(sources_v), anything, country_arg)
    end

    # --- vars mode -----------------------------------------------------------
    if vars_v == "load"
        return try
            varlist_df()
        catch
            fail_with_issue("variable list")
        end
    end
    if vars_v == "list"
        vt2 = try
            varlist_df()
        catch
            fail_with_issue("variable list")
        end
        _print_var_table(vt2)
        return nothing
    end

    # --- raw single-variable mode --------------------------------------------
    if raw_flag
        word_count != 1 && fail(498, "Warning: Please specify exactly one variable.")
        df = try
            read_csv_remote("distribute/$(anything)_$(selected_version).csv")
        catch
            is_valid = false
            try
                vl = varlist_df()
                vcol = _first_member(("variable", "variables"), names(vl))
                is_valid = vcol !== nothing && any(string.(vl[!, vcol]) .== anything)
            catch
            end
            is_valid || fail(498, "Specified variable is not valid.")
            fail(498, "Variable does not have raw data.")
        end
        emit("Loaded raw data on $anything")
    end

    # --- country list/load mode ----------------------------------------------
    if country_val isa AbstractString && lowercase(country_val) in ("load", "list")
        mode = lowercase(country_val)
        ct = try
            country_df()
        catch
            fail_with_issue("country list")
        end
        if mode == "load"
            return ct
        else
            _print_country_table(ct)
            return nothing
        end
    end

    # --- reject identifier variables -----------------------------------------
    if lowercase(anything) in lowercase.(ID_COLS)
        fail(498, "$anything is an identifying variable loaded in the dataset, specify common variables",
             VARS_HINTS...)
    end

    # --- default dataset load ------------------------------------------------
    if !raw_flag
        df = isempty(gmd_local_path) ? dataset_table(selected_version, fast_flag) :
                                       _read_dta(gmd_local_path)
    end
    df === nothing && fail(498, "No data loaded")

    # --- variable selection (case-insensitive, canonical casing) -------------
    if !isempty(anything) && !raw_flag
        colnames = names(df)
        lower_to_actual = Dict{String,String}()
        for c in colnames
            lower_to_actual[lowercase(c)] = c
        end
        canonical = String[]
        invalid = String[]
        for tok in anything_tokens
            k = lowercase(tok)
            if haskey(lower_to_actual, k)
                push!(canonical, lower_to_actual[k])
            else
                push!(invalid, tok)
            end
        end
        if !isempty(invalid)
            if length(invalid) == 1
                emit("$(invalid[1]) is not a valid variable code")
            else
                emit("$(join(invalid, " ")) are not valid variable codes")
            end
            fail(498, VARS_HINTS...)
        end
        anything_tokens = canonical

        keep = String[]
        for c in vcat(ID_COLS, canonical)
            (c in names(df) && !(c in keep)) && push!(keep, c)
        end
        df = df[:, keep]

        if all(c -> c in names(df), ("ISO3", "year"))
            sel = df[:, canonical]
            valid_count = [count(!ismissing, collect(row)) for row in eachrow(sel)]
            order = sortperm(collect(zip(string.(df.ISO3), df.year)))
            df = df[order, :]
            vc = valid_count[order]
            mask = falses(nrow(df))
            iso = string.(df.ISO3)
            i = 1
            n = nrow(df)
            while i <= n
                j = i
                while j <= n && iso[j] == iso[i]
                    j += 1
                end
                c = 0
                for r in i:j-1
                    c += vc[r]
                    mask[r] = c > 0
                end
                i = j
            end
            df = df[mask, :]
        end
    end

    # --- country filtering ---------------------------------------------------
    if !isempty(country_arg)
        ctokens = tokens(uppercase(country_arg))
        "ISO3" in names(df) ||
            fail(498, "Country code is invalid or no data for this country in source.", COUNTRY_HINTS...)
        iso_series = uppercase.(string.(df.ISO3))
        if length(ctokens) == 1
            code = ctokens[1]
            any(iso_series .== code) ||
                fail(498, "Country code is invalid or no data for this country in source.", COUNTRY_HINTS...)
            df = df[iso_series .== code, :]
        elseif length(ctokens) > 1
            keepmask = falses(nrow(df))
            invalid = String[]
            for code in ctokens
                one = iso_series .== code
                if any(one)
                    keepmask .|= one
                else
                    push!(invalid, code)
                end
            end
            if !isempty(invalid)
                inv = join(invalid, " ")
                emit(length(invalid) == 1 ? "$inv is not a valid ISO3 code" : "$inv are not valid ISO3 codes")
                emit(COUNTRY_HINTS...)
                fail(498, "Invalid ISO3 code")
            end
            df = df[keepmask, :]
        end
    end

    # --- year range and cleanup ----------------------------------------------
    df = apply_year_range(df, start_yr, end_yr)
    df = _drop_all_missing_columns(df)

    _print_summary(df, anything, country_arg, selected_version, version,
                   raw_flag, sources_v, fast_flag, saved_gmd)
    return df
end

# --- public helpers ----------------------------------------------------------
"""
    get_available_versions() -> Vector{String}

List all data vintages (newest first). Falls back to locally cached versions
when the network is unavailable.
"""
function get_available_versions()
    try
        vt = versions_df()
        return string.(vt.versions)
    catch err
        err isa GMDCommandError && rethrow(err)
        cached = cache_versions()
        isempty(cached) || return cached
        isfile(joinpath(cache_dir(), "GMD.dta")) && return ["local"]
        fail(498, "Unable to load version information. Check your internet connection " *
                  "or report this issue at $ISSUES_URL")
    end
end

"Get the latest version string."
get_current_version() = get_available_versions()[1]

"Print the variable table. Thin wrapper over `gmd(vars=\"list\")`."
list_variables() = (gmd(vars="list"); nothing)

"Print the country table. Thin wrapper over `gmd(country=\"list\")`."
list_countries() = (gmd(country="list"); nothing)
