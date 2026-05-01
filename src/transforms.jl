# Transforms narrow or reshape the pipeline between Source and Sink.
# Currently two: `Select` (filter dims and variables) and `Rechunk` (override
# output chunk shape). Selectors are the small sentinels passed to Select
# to describe what to keep along a given dim.

#-----------------------------------------------------------------------------# selector sentinels
# `All()` means "keep everything" — used as a default or to make intent
# explicit (`vars=All()`).
struct All end

# `Between(lo, hi)` keeps any coordinate value in the closed interval
# [lo, hi]. Works for whatever type supports `<=` (Dates, numbers, …).
struct Between{T}
    lo::T
    hi::T
end

Base.show(io::IO, ::All) = print(io, "All()")
Base.show(io::IO, b::Between) = print(io, "Between(", b.lo, ", ", b.hi, ")")

# `matches(selector, value)` is the membership predicate that drives Select.
# Adding a new selector shape is just adding a method here.
matches(::All, _)                     = true
matches(b::Between, x)                = b.lo <= x <= b.hi
matches(r::AbstractRange, x)          = x in r            # e.g. Date(2025,1,1):Day(1):Date(2025,1,5)
matches(v::AbstractVector, x)         = x in v            # explicit list
matches(s::Symbol, x::Symbol)         = s == x

#-----------------------------------------------------------------------------# Select
# Filters dims and variables. Keyword names map to dim names (e.g.
# `time=Date(2025):Day(1):Date(2025,2)` filters the `:time` dim) plus the
# special key `vars=` for variable filtering. Anything not named in the
# selectors dict passes through unchanged.
struct Select <: Transform
    selectors::Dict{Symbol, Any}
end

Select(; kwargs...) = Select(Dict{Symbol,Any}(pairs(kwargs)))

function Base.show(io::IO, t::Select)
    parts = ["$k=$(_show_sel(v))" for (k, v) in t.selectors]
    print(io, "Select(", join(parts, ", "), ")")
end

_show_sel(v) = repr(v)
_show_sel(v::AbstractVector) = string(v)

#-----------------------------------------------------------------------------# Rechunk
# Overrides the output Zarr chunk size for one or more dims. Does NOT change
# what gets fetched — only how the resulting data is sliced on disk. The
# Source's native `DimSpec.chunk` is the default; Rechunk overrides it; a
# `Store(chunks=...)` argument overrides Rechunk in turn.
struct Rechunk <: Transform
    chunks::Dict{Symbol, Int}
end

Rechunk(; kwargs...) = Rechunk(Dict{Symbol,Int}(pairs(kwargs)))

function Base.show(io::IO, t::Rechunk)
    parts = ["$k=$v" for (k, v) in t.chunks]
    print(io, "Rechunk(", join(parts, ", "), ")")
end

#-----------------------------------------------------------------------------# applying Select
# Called by `execute` to compute the post-Select schema and unit list.
# Walks every dim and applies its selector (if any), then filters the var
# list, then drops/narrows units that no longer have anything to deliver.
function apply_select(t::Select, sch::SourceSchema, us::Vector{FetchUnit})
    new_dims = map(sch.dims) do d
        sel = get(t.selectors, d.name, nothing)
        sel === nothing && return d
        kept = filter(v -> matches(sel, v), d.values)
        DimSpec(d.name, kept; dtype=d.dtype, chunk=d.chunk, attrs=d.attrs)
    end
    var_sel = get(t.selectors, :vars, nothing)
    new_vars = if var_sel === nothing || var_sel isa All
        sch.vars
    else
        filter(v -> _var_match(var_sel, v.name), sch.vars)
    end
    new_sch = SourceSchema(new_dims, new_vars; attrs=sch.attrs)

    var_keep = Set(v.name for v in new_vars)
    new_us = FetchUnit[]
    for u in us
        n = _narrow_unit(u, new_sch, var_keep)
        n === nothing || push!(new_us, n)
    end
    new_sch, new_us
end

# Variable-selector matching: separate from `matches` so that `vars=:sst`
# (a single Symbol) reads as "this var name", whereas `time=:foo` would
# (correctly) be a strange thing to write.
_var_match(::All, _)                       = true
_var_match(s::Symbol, name)                = s == name
_var_match(v::AbstractVector{Symbol}, name) = name in v

# Drop a unit entirely if its coords no longer overlap the narrowed schema,
# or restrict its var list to those that survived. Returns `nothing` to
# signal "drop this unit".
function _narrow_unit(u::FetchUnit, sch::SourceSchema, var_keep::Set{Symbol})
    new_coords = Dict{Symbol, AbstractVector}()
    for d in sch.dims
        haskey(u.coords, d.name) || continue
        kept = filter(v -> v in d.values, u.coords[d.name])
        isempty(kept) && return nothing
        new_coords[d.name] = kept
    end
    if isempty(u.vars)
        # An empty u.vars means "all vars in source"; under narrowing it
        # still means "all vars in the narrowed schema" — no rewrite needed.
        return FetchUnit(new_coords, Symbol[], u.payload)
    end
    new_vars = filter(in(var_keep), u.vars)
    isempty(new_vars) && return nothing
    FetchUnit(new_coords, new_vars, u.payload)
end
