# Schema types describe the *shape* of the data a source provides.
#
# A `SourceSchema` declares:
#   - which dimensions exist (their names, coordinate values, dtypes, native
#     chunk hints) — modeled by `DimSpec`,
#   - which variables exist (their names, the dims they span, dtypes) —
#     modeled by `VarSpec`,
#   - any free-form attributes (e.g. dataset provenance).
#
# A `FetchUnit` is the smallest atomically-fetchable slice of the source —
# typically one HTTP request, one CDS job, etc. Units carry coordinate
# values (not integer indices) so that selection and Zarr placement are
# robust to schema narrowing (Select can drop dim values without renumbering
# anything).

#-----------------------------------------------------------------------------# DimSpec
# Describes one dimension of a source. `values` is the canonical coordinate
# array (e.g. dates for `:time`, longitudes for `:lon`). `chunk` is the
# source's *native* chunk size along this dim — used as the default Zarr
# chunk size unless overridden by a Rechunk or Store(chunks=) override.
struct DimSpec
    name::Symbol
    values::AbstractVector
    dtype::Type
    chunk::Int
    attrs::Dict{Symbol, Any}
end

function DimSpec(name, values; dtype = eltype(values), chunk::Int = 1,
                 attrs::AbstractDict = Dict{Symbol,Any}())
    DimSpec(Symbol(name), collect(values), dtype, chunk, Dict{Symbol,Any}(pairs(attrs)))
end

Base.length(d::DimSpec) = length(d.values)

Base.show(io::IO, d::DimSpec) = print(io, "DimSpec(:", d.name, ", $(d.dtype), n=$(length(d)), chunk=$(d.chunk))")

#-----------------------------------------------------------------------------# VarSpec
# Describes one variable in the source. `dims` is the ordered list of
# dimension names the variable spans — the order matches the in-memory
# layout returned by the transport's decoder (for NetCDF via NCDatasets,
# that is the *reverse* of the file's declared dim order, which is column-
# vs row-major).
struct VarSpec
    name::Symbol
    dims::Vector{Symbol}
    dtype::Type
    attrs::Dict{Symbol, Any}
end

function VarSpec(name, dims, dtype; attrs::AbstractDict = Dict{Symbol,Any}())
    VarSpec(Symbol(name), Symbol[Symbol(d) for d in dims], dtype, Dict{Symbol,Any}(pairs(attrs)))
end

Base.show(io::IO, v::VarSpec) = print(io, "VarSpec(:", v.name, ", $(v.dtype), dims=$(v.dims))")

#-----------------------------------------------------------------------------# SourceSchema
# The full description of what a Source can provide. Schemas flow through
# the pipeline: each Transform produces a (possibly narrowed) schema, and
# the final schema is what `execute` materializes into Zarr arrays.
struct SourceSchema
    dims::Vector{DimSpec}
    vars::Vector{VarSpec}
    attrs::Dict{Symbol, Any}
end

function SourceSchema(dims, vars; attrs::AbstractDict = Dict{Symbol,Any}())
    SourceSchema(collect(dims), collect(vars), Dict{Symbol,Any}(pairs(attrs)))
end

# Convenience lookups. `dim`/`var` throw on missing names; `hasdim`/`hasvar`
# return Bool.
dim(s::SourceSchema, name::Symbol) = s.dims[findfirst(d -> d.name == name, s.dims)]
hasdim(s::SourceSchema, name::Symbol) = any(d -> d.name == name, s.dims)
var(s::SourceSchema, name::Symbol) = s.vars[findfirst(v -> v.name == name, s.vars)]
hasvar(s::SourceSchema, name::Symbol) = any(v -> v.name == name, s.vars)

function Base.show(io::IO, ::MIME"text/plain", s::SourceSchema)
    println(io, "SourceSchema")
    println(io, "  dims:")
    for d in s.dims; println(io, "    ", d); end
    println(io, "  vars:")
    for v in s.vars; println(io, "    ", v); end
    isempty(s.attrs) || println(io, "  attrs: ", s.attrs)
end

Base.show(io::IO, s::SourceSchema) =
    print(io, "SourceSchema($(length(s.dims)) dims, $(length(s.vars)) vars)")

#-----------------------------------------------------------------------------# FetchUnit
# Smallest atomically-fetchable slice from a Source.
#
# Fields:
#   `coords`  — for each dim the unit covers, the *coordinate values* (not
#               integer positions) that this unit will deliver. A dim that
#               doesn't appear in `coords` means "the whole dim". For OISST
#               this is `Dict(:time => [date])` because each daily file
#               provides one timestep but the full lon/lat grid.
#   `vars`    — restricts which variables the unit provides. An empty list
#               means "all variables in the schema". Used by `Select(vars=)`
#               to skip reading unwanted variables on disk.
#   `payload` — transport-specific blob. For HTTPFileSource it's the URL
#               string. For CDSAPISource it would be the request dict.
#
# Why coord-based and not integer-based? Because Select narrows dim values,
# and we never want unit indices to shift under us. Looking up a unit's
# integer position in the *narrowed* schema is done at write time in
# `_write_unit!`.
struct FetchUnit
    coords::Dict{Symbol, AbstractVector}
    vars::Vector{Symbol}
    payload::Any
end

function FetchUnit(; coords = Dict{Symbol,AbstractVector}(),
                     vars::AbstractVector{Symbol} = Symbol[],
                     payload = nothing)
    FetchUnit(Dict{Symbol,AbstractVector}(pairs(coords)), collect(vars), payload)
end

Base.show(io::IO, u::FetchUnit) =
    print(io, "FetchUnit(coords=", u.coords,
              isempty(u.vars) ? "" : ", vars=$(u.vars)",
              ")")
