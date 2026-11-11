# Transports are the wire-protocol layer of Source — keyed on *how* bytes
# are obtained, not *which* dataset they describe. A user-facing preset
# (see `presets.jl`) constructs a transport source pre-configured for a
# specific dataset (URL pattern, schema, unit list).
#
# Each transport must implement:
#   `fetch!(::TransportSource, ::FetchUnit, ::SourceSchema) -> NamedTuple{vars, Tuple{Array,...}}`
# where the schema is the *narrowed* (post-Select) one. The result must
# contain only variables in that schema (restricted to the unit's `vars` if
# non-empty), each as a Julia array in the order declared by the schema's
# VarSpec.dims and shaped for the narrowed schema: along dims in the unit's
# `coords` the length of those coordinate values, along every other dim the
# length of the narrowed dim.
#
# Three transports defined here:
#   `HTTPFileSource`  — download a whole file over HTTP(S), then decode by
#                        format (currently :netcdf via NCDatasets).
#   `CDSAPISource`    — Copernicus CDS retrieve API (job-submit + poll +
#                        download). Currently a stub; will be filled in for
#                        ERA5.
#   `GRIBRangeSource` — read individual GRIB2 messages by byte range, located
#                        through `.idx` sidecars (HTTP(S) URL or local path).

#-----------------------------------------------------------------------------# HTTPFileSource
# Generic "download a file by URL, then decode" transport. Each FetchUnit's
# `payload` is the URL string. `format` selects the decoder; `headers` are
# passed to Downloads.jl (e.g. for API tokens).
struct HTTPFileSource <: Source
    schema::SourceSchema
    units::Vector{FetchUnit}
    format::Symbol
    headers::Dict{String, String}
end

function HTTPFileSource(; schema::SourceSchema,
                          units,
                          format::Symbol = :netcdf,
                          headers::AbstractDict = Dict{String,String}())
    HTTPFileSource(schema, collect(units), format,
                   Dict{String,String}(string(k) => string(v) for (k, v) in pairs(headers)))
end

Base.show(io::IO, s::HTTPFileSource) =
    print(io, "HTTPFileSource(", length(s.units), " units, format=:", s.format, ")")

# Download to a temp path, decode, clean up. The temp file is removed even
# if decoding throws — the `try`/`finally` makes that guarantee.
function fetch!(src::HTTPFileSource, u::FetchUnit, sch::SourceSchema)
    url = string(u.payload)
    path = tempname()
    Downloads.download(url, path; headers = collect(src.headers))
    try
        if src.format === :netcdf
            return _read_netcdf(path, u, src.schema, sch)
        else
            error("HTTPFileSource format :$(src.format) is not implemented yet")
        end
    finally
        isfile(path) && rm(path; force=true)
    end
end

# Index selecting the narrowed schema's values of dim `name` out of the full
# schema's: `Colon()` if nothing was dropped, else the positions of the
# narrowed values in the full dim.
function _dimindex(full::SourceSchema, sch::SourceSchema, name::Symbol)
    (a, b) = (dim(full, name).values, dim(sch, name).values)
    a == b && return Colon()
    convert(Vector{Int}, indexin(b, a))
end

# Names of the variables a unit delivers: those of the narrowed schema `sch`,
# restricted to the unit's `vars` if non-empty.
function _unitvars(u::FetchUnit, sch::SourceSchema)
    filter(n -> isempty(u.vars) || n ∈ u.vars, map(v -> v.name, sch.vars))
end

# NetCDF decoder. Reads the variables of the narrowed schema `sch`
# (restricted to the unit's named variables if `u.vars` is non-empty). The
# returned NamedTuple's keys are the variable names (Symbols); values are
# plain Julia Arrays in NCDatasets memory order (which is the *reverse* of
# the file's declared dim order — column- vs row-major). The schema's
# VarSpec.dims list must match this order.
#
# Dims not in `u.coords` are cropped from the full schema `full` to `sch`
# while reading, so only the subset is read from disk. Dims in `u.coords`
# are read whole — limitation: a whole-file unit must deliver exactly its
# `u.coords` values along those dims.
function _read_netcdf(path::AbstractString, u::FetchUnit, full::SourceSchema, sch::SourceSchema)
    NCDatasets.NCDataset(path, "r") do ds
        names = _unitvars(u, sch)
        pairs = Pair{Symbol, Any}[]
        for n in names
            v = var(sch, n)
            idx = map(d -> haskey(u.coords, d) ? Colon() : _dimindex(full, sch, d), v.dims)
            push!(pairs, n => _coerce_missing(ds[String(n)][idx...], v.dtype))
        end
        NamedTuple(pairs)
    end
end

# NCDatasets returns `Union{Missing, T}` whenever a variable has a
# `_FillValue` attribute. Zarr arrays are typed `T` (no missing), so we
# fold missings into NaN for floats. Non-float dtypes can't represent
# missing, so we error if any are present — declare a Union dtype upstream
# if you need missing-aware ints.
_coerce_missing(a::AbstractArray{T}, ::Type{T}) where {T} = a
function _coerce_missing(a::AbstractArray{Union{Missing,T}}, ::Type{T}) where {T<:AbstractFloat}
    convert(Array{T}, coalesce.(a, T(NaN)))
end
function _coerce_missing(a::AbstractArray{Union{Missing,T}}, ::Type{T}) where {T}
    any(ismissing, a) && error("Cannot fold missing values into non-float dtype $T")
    convert(Array{T}, a)
end

#-----------------------------------------------------------------------------# CDSAPISource (stub)
# Copernicus CDS retrieve API transport. Each FetchUnit's `payload` will be
# a Dict describing the request body; fetch! will submit the job, poll for
# completion, then download the result file. Used by the (not-yet-built)
# ERA5 preset.
struct CDSAPISource <: Source
    schema::SourceSchema
    units::Vector{FetchUnit}
    dataset::String
    api_key::Union{String, Nothing}
end

function CDSAPISource(; schema::SourceSchema, units, dataset::AbstractString,
                        api_key::Union{AbstractString, Nothing} = nothing)
    CDSAPISource(schema, collect(units), String(dataset),
                 api_key === nothing ? nothing : String(api_key))
end

Base.show(io::IO, s::CDSAPISource) =
    print(io, "CDSAPISource(\"$(s.dataset)\", $(length(s.units)) units)")

fetch!(::CDSAPISource, ::FetchUnit, ::SourceSchema) = error("CDSAPISource.fetch! not implemented yet")

#-----------------------------------------------------------------------------# GRIBRangeSource
# How to find the messages of one variable in a GRIB `.idx` sidecar.
struct GRIBField
    param::String                # idx field 4, e.g. "TMP"
    level::String                # idx field 5; "{}" is replaced by the :level coordinate
    forecast::Union{Regex, Nothing}  # constraint on idx field 6; nothing = instantaneous
end
GRIBField(param, level) = GRIBField(param, level, nothing)

# "Read single GRIB2 messages by byte range" transport. Each FetchUnit's
# `payload` is the location (URL or local path) of a GRIB file; its index is
# at `payload * ".idx"`. Only the messages of the requested variables and
# levels are read.
struct GRIBRangeSource <: Source
    schema::SourceSchema
    units::Vector{FetchUnit}
    fields::Dict{Symbol, GRIBField}   # variable name => how to find its messages
end

function GRIBRangeSource(; schema::SourceSchema, units, fields::AbstractDict)
    GRIBRangeSource(schema, collect(units), Dict{Symbol, GRIBField}(pairs(fields)))
end

Base.show(io::IO, s::GRIBRangeSource) =
    print(io, "GRIBRangeSource(", length(s.units), " units, ", length(s.fields), " fields)")

_ishttp(loc::AbstractString) = startswith(loc, "http://") || startswith(loc, "https://")

# Bytes `a` to `b` of `loc`, zero-based and inclusive; `b === nothing` reads
# to the end. With a known `b` the byte count is checked, which catches a
# server that ignores `Range` and a truncated file.
function _readbytes(loc::AbstractString, a::Int, b::Union{Int, Nothing})::Vector{UInt8}
    bytes = if _ishttp(loc)
        r = isnothing(b) ? "bytes=$a-" : "bytes=$a-$b"
        take!(Downloads.download(loc, IOBuffer(); headers=["Range" => r]))
    else
        open(loc, "r") do io
            seek(io, a)
            isnothing(b) ? read(io) : read(io, b - a + 1)
        end
    end
    if !isnothing(b) && length(bytes) ≠ b - a + 1
        error("expected $(b - a + 1) bytes for range $a-$b of $loc, got $(length(bytes))")
    end
    bytes
end

# Whole (small) text file, HTTP(S) or local.
function _readtext(loc::AbstractString)::String
    _ishttp(loc) ? String(take!(Downloads.download(loc, IOBuffer()))) : read(loc, String)
end

# Parse a GRIB `.idx` sidecar (`n:offset:date:param:level:forecast:` lines)
# into entries `(start, stop, param, level, forecast)`; `start`/`stop` are the
# zero-based inclusive byte range of the message, `stop === nothing` meaning
# "to the end of the file". A message runs to just before the next strictly
# larger offset (sub-messages share an offset). Blank lines and lines of any
# other shape are skipped.
function _parseidx(text::AbstractString)
    rows = NamedTuple{(:start, :param, :level, :forecast), Tuple{Int, String, String, String}}[]
    for l ∈ eachline(IOBuffer(text))
        p = split(l, ':')
        length(p) ≥ 6 || continue
        a = tryparse(Int, p[2])
        isnothing(a) && continue
        push!(rows, (start=a, param=String(p[4]), level=String(p[5]), forecast=String(p[6])))
    end
    s = sort!(unique(map(r -> r.start, rows)))
    map(rows) do r
        i = searchsortedfirst(s, r.start + 1)
        merge(r, (; stop=i > length(s) ? nothing : s[i] - 1))
    end
end

# First idx entry for field `f` at level coordinate `lev` (`nothing` for
# variables without a :level dim), or `nothing` if the file has no such
# message. With `f.forecast === nothing` only instantaneous fields match,
# i.e. forecast text without a range ("anl", "6 hour fcst").
function _findmsg(idx, f::GRIBField, lev)
    level = isnothing(lev) ? f.level : replace(f.level, "{}" => string(lev))
    i = findfirst(idx) do e
        e.param == f.param && e.level == level || return false
        isnothing(f.forecast) ? !occursin('-', e.forecast) : occursin(f.forecast, e.forecast)
    end
    isnothing(i) ? nothing : idx[i]
end

# Decode one in-memory GRIB message to its `(Ni, Nj)` grid, bitmap-masked
# points as NaN. The message shares memory with `bytes`, hence the preserve.
# The handle is released with `finalize`, not `GRIB.destroy`: `Message`
# registers `destroy` as its finalizer and `destroy` does not null the
# pointer, so an explicit call followed by GC would free the handle twice.
function _decodegrib(bytes::Vector{UInt8})::Matrix{Float64}
    GC.@preserve bytes begin
        m = GRIB.Message(bytes)
        try
            g = m["values"]
            if m["bitmapPresent"] == 1
                replace!(g, GRIB.missingvalue(m) => NaN)
            end
            g
        finally
            finalize(m)
        end
    end
end

# One unit is one GRIB file. Each variable's first two dims are the
# horizontal grid dims, in decode order; every further dim is either :level
# or a dim the unit pins to a single coordinate. Messages that the file does
# not have (a variable, or one of its levels) are left as NaN.
#
# Level coordinates are assumed to print the way the idx writes them
# (`string(500) * " mb"`), so level dims should hold `Int` hPa.
function fetch!(src::GRIBRangeSource, u::FetchUnit, sch::SourceSchema)
    loc = string(u.payload)
    idx = _parseidx(_readtext(loc * ".idx"))
    isempty(idx) && error("no GRIB index entries found in $(loc).idx")
    names = _unitvars(u, sch)
    arrs = map(n -> _fetchgribvar(src, u, sch, idx, loc, var(sch, n)), names)
    NamedTuple{Tuple(names)}(Tuple(arrs))
end

function _fetchgribvar(src::GRIBRangeSource, u::FetchUnit, sch::SourceSchema, idx, loc, v::VarSpec)
    T = v.dtype
    T <: AbstractFloat || error("GRIBRangeSource needs a float dtype, variable $(v.name) has $T")
    f = src.fields[v.name]
    (ix, iy) = (_dimindex(src.schema, sch, v.dims[1]), _dimindex(src.schema, sch, v.dims[2]))
    rest = v.dims[3:end]
    foreach(rest) do d
        d === :level && return
        haskey(u.coords, d) && length(u.coords[d]) == 1 && return
        error("variable $(v.name): dim $d must be pinned to one value by the fetch unit")
    end
    shape = map(d -> haskey(u.coords, d) ? length(u.coords[d]) : length(dim(sch, d).values), v.dims)
    A = fill(T(NaN), shape...)
    levs = if :level ∈ rest
        haskey(u.coords, :level) ? u.coords[:level] : dim(sch, :level).values
    else
        [nothing]
    end
    foreach(enumerate(levs)) do (k, lev)
        e = _findmsg(idx, f, lev)
        isnothing(e) && return
        g = _decodegrib(_readbytes(loc, e.start, e.stop))
        j = map(d -> d === :level ? k : 1, rest)
        A[:, :, j...] .= view(g, ix, iy)
    end
    A
end
