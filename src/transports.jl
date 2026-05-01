# Transports are the wire-protocol layer of Source — keyed on *how* bytes
# are obtained, not *which* dataset they describe. A user-facing preset
# (see `presets.jl`) constructs a transport source pre-configured for a
# specific dataset (URL pattern, schema, unit list).
#
# Each transport must implement:
#   `fetch!(::TransportSource, ::FetchUnit) -> NamedTuple{vars, Tuple{Array,...}}`
# returning each requested variable as a Julia array in the order declared
# by the schema's VarSpec.dims.
#
# Two transports defined here:
#   `HTTPFileSource` — download a whole file over HTTP(S), then decode by
#                       format (currently :netcdf via NCDatasets).
#   `CDSAPISource`   — Copernicus CDS retrieve API (job-submit + poll +
#                       download). Currently a stub; will be filled in for
#                       ERA5.

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
function fetch!(src::HTTPFileSource, u::FetchUnit)
    url = string(u.payload)
    path = tempname()
    Downloads.download(url, path; headers = collect(src.headers))
    try
        if src.format === :netcdf
            return _read_netcdf(path, u, src.schema)
        else
            error("HTTPFileSource format :$(src.format) is not implemented yet")
        end
    finally
        isfile(path) && rm(path; force=true)
    end
end

# NetCDF decoder. Reads either the unit's named variables or, if `u.vars`
# is empty, every variable in the schema. The returned NamedTuple's keys
# are the variable names (Symbols); values are plain Julia Arrays in
# NCDatasets memory order (which is the *reverse* of the file's declared
# dim order — column- vs row-major). The schema's VarSpec.dims list must
# match this order.
function _read_netcdf(path::AbstractString, u::FetchUnit, sch::SourceSchema)
    NCDatasets.NCDataset(path, "r") do ds
        names = isempty(u.vars) ? Symbol[v.name for v in sch.vars] : u.vars
        pairs = Pair{Symbol, Any}[]
        for n in names
            push!(pairs, n => _coerce_missing(Array(ds[String(n)]), var(sch, n).dtype))
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

fetch!(::CDSAPISource, ::FetchUnit) = error("CDSAPISource.fetch! not implemented yet")
