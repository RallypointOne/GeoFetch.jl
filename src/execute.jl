# Execution: turn a built Pipeline into an on-disk Zarr store.
#
# The flow has four phases:
#   1. Resolve effective schema and unit list. Walk the transforms, applying
#      each Select to narrow dims/vars/units. (Rechunk doesn't touch this
#      phase — it only affects output chunk shape.)
#   2. Resolve effective chunks. Start from each DimSpec.chunk, then layer
#      Rechunk overrides, then Store(chunks=...) overrides.
#   3. Create the Zarr group and arrays. One coordinate array per dim, one
#      data array per variable. Coordinate arrays are populated immediately;
#      data arrays are created empty.
#   4. For each FetchUnit, ask the source for the data and slot it into the
#      right region of each Zarr array.

#-----------------------------------------------------------------------------# execute — entry point
function execute(p::Pipeline)
    sch, us = _resolve_schema(p)
    chunks = _resolve_chunks(p, sch)
    snk = sink(p)
    snk isa Store || throw(ArgumentError("Pipeline sink must be a Store, got $(typeof(snk))"))
    g = _create_zarr_group(snk, sch)
    arrays = _create_zarr_arrays!(g, snk, sch, chunks)
    src = source(p)
    for u in us
        data = fetch!(src, u)
        _write_unit!(arrays, sch, u, data)
    end
    g
end

#-----------------------------------------------------------------------------# resolve schema + units
# Walk the transforms in order. Each Select applies its filter to both the
# schema and the unit list (so that downstream stages see consistent state).
# Rechunk is a no-op here.
function _resolve_schema(p::Pipeline)
    src = source(p)
    sch = schema(src)
    us = collect(units(src))
    for t in transforms_of(p)
        if t isa Select
            sch, us = apply_select(t, sch, us)
        elseif t isa Rechunk
            # Rechunk only affects output chunk shape — handled below.
        else
            throw(ArgumentError("Unknown transform stage: $(typeof(t))"))
        end
    end
    sch, us
end

#-----------------------------------------------------------------------------# resolve chunks
# Precedence (lowest to highest):
#   1. Source's native chunk hint per dim (DimSpec.chunk).
#   2. Each Rechunk transform in the pipeline, in order; later ones win.
#   3. The Store(chunks=…) override wins overall.
# Finally, clamp every chunk size to [1, dim_length] so we don't write
# oversized chunks to small dims.
function _resolve_chunks(p::Pipeline, sch::SourceSchema)
    out = Dict{Symbol, Int}(d.name => d.chunk for d in sch.dims)
    for t in transforms_of(p)
        t isa Rechunk || continue
        for (k, v) in t.chunks
            haskey(out, k) || throw(ArgumentError("Rechunk: unknown dim :$k"))
            out[k] = v
        end
    end
    snk = sink(p)::Store
    for (k, v) in snk.chunks
        haskey(out, k) || throw(ArgumentError("Store(chunks=...): unknown dim :$k"))
        out[k] = v
    end
    for d in sch.dims
        out[d.name] = min(out[d.name], length(d))
        out[d.name] = max(out[d.name], 1)
    end
    out
end

#-----------------------------------------------------------------------------# zarr group + arrays
# Create the on-disk root group. Honors `overwrite` and merges the source's
# attrs with any extra attrs supplied on the Store. Uses Zarr.jl's
# DirectoryStore directly because the string-path `zgroup(path; ...)`
# entry point doesn't support a positional zarr_format argument.
function _create_zarr_group(snk::Store, sch::SourceSchema)
    if isdir(snk.path) || isfile(snk.path)
        snk.overwrite || error("Zarr store already exists at $(snk.path); pass overwrite=true to replace")
        rm(snk.path; force = true, recursive = true)
    end
    mkpath(dirname(abspath(snk.path)))
    attrs = Dict{String,Any}(string(k) => v for (k, v) in sch.attrs)
    merge!(attrs, Dict{String,Any}(string(k) => v for (k, v) in snk.attrs))
    store = Zarr.DirectoryStore(snk.path)
    Zarr.zgroup(store, "", snk.zarr_version; attrs = attrs)
end

# Create one coordinate array per dim (1D, populated immediately) and one
# data array per variable (N-D, empty — to be filled by the per-unit writes).
# Returns a Dict{Symbol → ZArray} of just the data arrays, since coordinate
# arrays don't need further writing.
function _create_zarr_arrays!(g, snk::Store, sch::SourceSchema, chunks::Dict{Symbol,Int})
    arrays = Dict{Symbol, Any}()
    for d in sch.dims
        a = Zarr.zcreate(d.dtype, g, String(d.name), length(d);
                         chunks = (chunks[d.name],),
                         attrs = Dict{String,Any}(string(k) => v for (k, v) in d.attrs))
        a[:] = collect(d.values)
    end
    for v in sch.vars
        shape = Tuple(length(dim(sch, dn)) for dn in v.dims)
        ch    = Tuple(chunks[dn] for dn in v.dims)
        a = Zarr.zcreate(v.dtype, g, String(v.name), shape...;
                         chunks = ch,
                         attrs = Dict{String,Any}(string(k) => v for (k, v) in v.attrs))
        arrays[v.name] = a
    end
    arrays
end

#-----------------------------------------------------------------------------# write a fetched unit into the zarr arrays
# For each variable in the fetched data:
#   1. Look it up in the schema to get its dim list.
#   2. For each dim, decide what slice of the output array this data covers:
#      - dims listed in u.coords get a contiguous range matching the unit's
#        coordinate values' positions in the (narrowed) schema.
#      - dims not in u.coords get the full extent.
#   3. Skip if any dim resolves to an empty range (the unit's coord values
#      fell outside the narrowed schema — shouldn't happen post-Select,
#      but harmless to guard against).
#   4. Write the array slice into Zarr. Zarr handles chunk packing /
#      read-modify-write for partial chunk overlap.
function _write_unit!(arrays::Dict{Symbol,Any}, sch::SourceSchema, u::FetchUnit, data::NamedTuple)
    for (vname, varr) in pairs(data)
        haskey(arrays, vname) || continue
        v = var(sch, vname)
        ranges = ntuple(length(v.dims)) do i
            dn = v.dims[i]
            d  = dim(sch, dn)
            if haskey(u.coords, dn)
                pos = Int[]
                for c in u.coords[dn]
                    p = findfirst(==(c), d.values)
                    p === nothing || push!(pos, p)
                end
                isempty(pos) && return 1:0
                first(pos):last(pos)
            else
                1:length(d)
            end
        end
        any(isempty, ranges) && continue
        arrays[vname][ranges...] = varr
    end
end
