# The Store sink is the only Sink type for now. It carries the configuration
# for the on-disk Zarr group; the actual creation work happens in `execute.jl`.

#-----------------------------------------------------------------------------# Store
# Fields:
#   `path`         — local directory where the Zarr store will be created.
#   `chunks`       — per-dim chunk size overrides; takes precedence over
#                    Rechunk and over the source's native chunk hints.
#   `zarr_version` — 2 or 3.
#   `overwrite`    — if true, an existing store at `path` is removed before
#                    writing. If false, an existing store causes `execute`
#                    to error.
#   `attrs`        — extra group-level attributes to attach to the root
#                    group, merged on top of the source schema's attrs.
"""
    Store(path; chunks=Dict(), zarr_version=3, overwrite=false, attrs=Dict())

Sink that writes a Zarr store to the local directory `path`. Each dimension
becomes a coordinate array of the same name and each variable a data array.
`Date` and `DateTime` coordinates are stored as integers with CF `units` and
`calendar` attributes.

# Keyword arguments
- `chunks`: chunk size per dimension, such as `Dict(:time => 30)`. Takes
  precedence over `Rechunk` and over the source's native chunks.
- `zarr_version`: `2` or `3`.
- `overwrite`: replace an existing store at `path`. When `false`, an existing
  store makes `execute` throw.
- `attrs`: extra attributes for the root group, merged over the source's.
"""
struct Store <: Sink
    path::String
    chunks::Dict{Symbol, Int}
    zarr_version::Int
    overwrite::Bool
    attrs::Dict{Symbol, Any}
end

function Store(path::AbstractString;
               chunks::AbstractDict = Dict{Symbol,Int}(),
               zarr_version::Int = 3,
               overwrite::Bool = false,
               attrs::AbstractDict = Dict{Symbol,Any}())
    zarr_version in (2, 3) || throw(ArgumentError("zarr_version must be 2 or 3"))
    Store(String(path),
          Dict{Symbol,Int}(Symbol(k) => Int(v) for (k, v) in pairs(chunks)),
          zarr_version,
          overwrite,
          Dict{Symbol,Any}(pairs(attrs)))
end

function Base.show(io::IO, s::Store)
    print(io, "Store(\"$(s.path)\", v$(s.zarr_version)")
    isempty(s.chunks) || print(io, ", chunks=", s.chunks)
    s.overwrite && print(io, ", overwrite=true")
    print(io, ")")
end
