# Minimal Stata .dta reader. Ports the built-in reader from the MATLAB package
# so the versioned releases and the .dta helper tables read without a Stata or
# ReadStat dependency. Supports the old binary formats 114/115 and the modern
# tagged formats 117/118/119. Value labels are ignored (data read unlabeled,
# like the Python package's convert_categoricals=False), strL long strings are
# not supported, and numeric Stata missing values become `missing`.

const _UINT_OF = Dict(1 => UInt8, 2 => UInt16, 4 => UInt32, 8 => UInt64)

# Read one scalar of type T from `bytes` (length == sizeof(T)) honouring endianness.
function _rd(::Type{T}, bytes::AbstractVector{UInt8}, big::Bool) where {T}
    u = only(reinterpret(_UINT_OF[sizeof(T)], collect(bytes)))
    big && (u = bswap(u))
    return reinterpret(T, u)
end

_read_dta(path::AbstractString) = read_dta_bytes(read(path))

function read_dta_bytes(raw::Vector{UInt8})
    if length(raw) >= 11 && String(raw[1:11]) == "<stata_dta>"
        return _parse_tagged(raw)
    elseif raw[1] == 0x72 || raw[1] == 0x73   # 114 or 115
        return _parse_old(raw)
    else
        throw(GMDCommandError(501, "Unrecognized .dta format (first byte $(Int(raw[1])))."))
    end
end

# --- type helpers (handle both the 114 and 117/118 code schemes) -------------
function _is_string_code(code::Integer)
    return 1 <= code <= 2045 && !(code in (251, 252, 253, 254, 255))
end

function _type_size(code::Integer)
    code in (251, 65530) && return 1   # byte
    code in (252, 65529) && return 2   # int
    code in (253, 65528) && return 4   # long
    code in (254, 65527) && return 4   # float
    code in (255, 65526) && return 8   # double
    code == 32768 && throw(GMDCommandError(501, "strL (long string) columns are not supported."))
    1 <= code <= 2045 && return Int(code)  # str<code>
    throw(GMDCommandError(501, "Unsupported .dta variable type code $code"))
end

# (julia type, max valid, min valid) for the numeric Stata codes.
function _numeric_spec(code::Integer)
    code in (251, 65530) && return (Int8, 100.0, -127.0)
    code in (252, 65529) && return (Int16, 32740.0, -32767.0)
    code in (253, 65528) && return (Int32, 2.147483620e9, -2.147483647e9)
    code in (254, 65527) && return (Float32, 1.701e38, -Inf)
    return (Float64, 8.988e307, -Inf)   # 255 / 65526
end

function _read_fixed_string(raw, start::Int, fieldlen::Int)
    seg = raw[start:start + fieldlen - 1]
    nul = findfirst(==(0x00), seg)
    nul !== nothing && (seg = seg[1:nul-1])
    return strip(String(seg))
end

# --- modern tagged format (117/118/119) --------------------------------------
function _parse_tagged(raw::Vector{UInt8})
    scan_end = min(length(raw), 4096)
    hdr_str = String(raw[1:scan_end])
    he = findfirst("</header>", hdr_str)
    hdr_end = he === nothing ? scan_end : first(he) - 1
    hdr = hdr_str[1:hdr_end]

    release = parse(Int, match(r"<release>(\d+)</release>", hdr).captures[1])
    big = match(r"<byteorder>(LSF|MSF)</byteorder>", hdr).captures[1] == "MSF"

    iK = first(findfirst("<K>", hdr)) + 3
    nvar = Int(_rd(UInt16, raw[iK:iK+1], big))

    iN = first(findfirst("<N>", hdr)) + 3
    nobs = release >= 118 ? Int(_rd(UInt64, raw[iN:iN+7], big)) :
                            Int(_rd(UInt32, raw[iN:iN+3], big))

    map_scan = String(raw[1:min(length(raw), hdr_end + 64)])
    imap = first(findfirst("<map>", map_scan)) + length("<map>") - 1
    mapvals = [Int(_rd(UInt64, raw[imap + (k-1)*8 + 1 : imap + k*8], big)) for k in 1:14]
    types_off = mapvals[3] + length("<variable_types>")
    names_off = mapvals[4] + length("<varnames>")
    data_off  = mapvals[10] + length("<data>")

    typlist = [Int(_rd(UInt16, raw[types_off + (i-1)*2 + 1 : types_off + i*2], big)) for i in 1:nvar]

    fieldlen = release >= 118 ? 129 : 33
    varnames = [_read_fixed_string(raw, names_off + 1 + (i-1)*fieldlen, fieldlen) for i in 1:nvar]

    return _read_data(raw, data_off + 1, typlist, varnames, nvar, nobs, big)
end

# --- old binary format (114/115) ---------------------------------------------
function _parse_old(raw::Vector{UInt8})
    big = raw[2] == 1   # 1 = HILO (big), 2 = LOHI (little)
    nvar = Int(_rd(Int16, raw[5:6], big))
    nobs = Int(_rd(Int32, raw[7:10], big))

    pos = 110                       # header is 109 bytes
    typlist = [Int(raw[pos + i - 1]) for i in 1:nvar]; pos += nvar
    varnames = [_read_fixed_string(raw, pos + (i-1)*33, 33) for i in 1:nvar]; pos += 33 * nvar
    pos += 2 * (nvar + 1)           # srtlist
    pos += 49 * nvar                # fmtlist
    pos += 33 * nvar                # value-label names
    pos += 81 * nvar                # variable labels
    while true                      # expansion fields
        dtype = raw[pos]; pos += 1
        pos += 4
        dtype == 0 && break
        pos += Int(_rd(Int32, raw[pos-4:pos-1], big))
    end
    return _read_data(raw, pos, typlist, varnames, nvar, nobs, big)
end

# --- shared data-block decoder -----------------------------------------------
function _read_data(raw, data_start::Int, typlist, varnames, nvar::Int, nobs::Int, big::Bool)
    sizes = [_type_size(c) for c in typlist]
    offsets = cumsum([0; sizes[1:end-1]])
    rowsize = sum(sizes)

    cols = Vector{Any}(undef, nvar)
    for i in 1:nvar
        code = typlist[i]
        s = sizes[i]
        off = offsets[i]
        if _is_string_code(code)
            col = Vector{String}(undef, nobs)
            for r in 0:nobs-1
                start = data_start + r * rowsize + off
                seg = raw[start:start + s - 1]
                nul = findfirst(==(0x00), seg)
                nul !== nothing && (seg = seg[1:nul-1])
                col[r+1] = strip(String(seg))
            end
            cols[i] = col
        else
            T, maxv, minv = _numeric_spec(code)
            col = Vector{Union{Float64,Missing}}(undef, nobs)
            for r in 0:nobs-1
                start = data_start + r * rowsize + off
                v = Float64(_rd(T, raw[start:start + s - 1], big))
                col[r+1] = (v > maxv || v < minv) ? missing : v
            end
            cols[i] = col
        end
    end
    return DataFrame(cols, Symbol.(varnames); makeunique=false)
end
