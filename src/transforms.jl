# Transforms narrow or reshape the pipeline between Source and Sink.
# Currently two: `Select` (filter dims and variables) and `Rechunk` (override
# output chunk shape). Selectors are the small sentinels passed to Select
# to describe what to keep along a given dim.

#-----------------------------------------------------------------------------# selector sentinels
# `All()` means "keep everything" — used as a default or to make intent
# explicit (`vars=All()`).
"""
    All()

Selector that keeps everything along a dimension, or every variable, in a
`Select`. Equivalent to not naming that dimension at all; useful for
making intent explicit, as in `Select(vars=All())`.
"""
struct All end

# `Between(lo, hi)` keeps any coordinate value in the closed interval
# [lo, hi]. Works for whatever type supports `<=` (Dates, numbers, …).
"""
    Between(lo, hi)

Selector for `Select` that keeps the coordinate values in the closed
interval `[lo, hi]`. Works for anything ordered: numbers, `Date`s, `DateTime`s.
`lo` and `hi` must have the same type, so write `Between(0.0, 20.5)` rather than
`Between(0, 20.5)`.
"""
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
"""
    Select(; vars=..., dim=selector, ...)

Transform that narrows a pipeline to part of the source. Each keyword names a
dimension of the source (for example `lon`, `lat`, `time`, `level`), and `vars`
picks variables. Anything not named is kept whole.

A dimension selector is one of
- `Between(lo, hi)`: values in a closed interval,
- a range, such as `Date(2025, 1, 1):Day(1):Date(2025, 1, 5)`: values in the range,
- a vector, such as `[850, 500]`: exactly those values,
- `All()`: everything.

`vars` takes a `Symbol`, a vector of `Symbol`s, or `All()`.

On a projected grid (such as `HRRR`, with dimensions `x` and `y`), `lon` and
`lat` are two-dimensional auxiliary coordinates. They are selected the same way,
and keep the smallest `x`/`y` rectangle that contains every grid point matching
all of them, so some points just outside the requested box are kept as well.

Kept values stay in the source's order. The selection is applied before anything
is downloaded: files, variables and levels that are not selected are never
fetched.

# Example
```julia
Select(vars=[:t2m, :t], level=[850, 500], lon=Between(0, 30), lat=Between(35, 60))
```
"""
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
"""
    Rechunk(; dim=n, ...)

Transform that sets the chunk size of the output store along the named
dimensions, for example `Rechunk(time=30)`. It changes only how the data is laid
out on disk, not what is fetched. Dimensions that are not named keep the source's
native chunk size, and `Store(path; chunks=...)` takes precedence over `Rechunk`.
"""
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
    t = _coordselect(t, sch)
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
    narrowed = SourceSchema(new_dims, new_vars; attrs=sch.attrs)
    new_coords = map(c -> _narrowcoord(c, sch, narrowed), sch.coords)
    new_sch = SourceSchema(new_dims, new_vars; attrs=sch.attrs, coords=new_coords)

    var_keep = Set(v.name for v in new_vars)
    new_us = FetchUnit[]
    for u in us
        n = _narrow_unit(u, new_sch, var_keep)
        n === nothing || push!(new_us, n)
    end
    new_sch, new_us
end

# Rewrite the selectors of `t` that name auxiliary coordinates of `sch` (such
# as the 2D `lon`/`lat` of a projected grid) into selectors on the dims those
# coordinates span. Coordinates that share their dims are selected jointly:
# the grid points matching all of their selectors are found, and each dim
# keeps the contiguous run of values from the first to the last one that has
# a matching point, i.e. the bounding box of the matches in index space. A
# selector the dim already has is applied on top.
function _coordselect(t::Select, sch::SourceSchema)
    cs = filter(c -> haskey(t.selectors, c.name), sch.coords)
    isempty(cs) && return t
    sel = filter(((k, _),) -> all(c -> c.name ≠ k, cs), t.selectors)
    foreach(unique(map(c -> c.dims, cs))) do ds
        g = filter(c -> c.dims == ds, cs)
        mask = mapreduce(c -> map(x -> matches(t.selectors[c.name], x), c.values), (a, b) -> a .& b, g)
        any(mask) ||
            throw(ArgumentError("Select: no grid point matches the selection on $(join(map(c -> c.name, g), ", "))"))
        foreach(enumerate(ds)) do (k, n)
            hit = vec(any(mask; dims=Tuple(setdiff(1:ndims(mask), k))))
            vals = dim(sch, n).values[findfirst(hit):findlast(hit)]
            s = get(sel, n, All())
            sel[n] = filter(x -> matches(s, x), vals)
        end
    end
    Select(sel)
end

# Crop an auxiliary coordinate of the schema `full` to the dims of the
# narrowed schema `sch`.
function _narrowcoord(c::CoordSpec, full::SourceSchema, sch::SourceSchema)
    idx = map(n -> _dimindex(full, sch, n), c.dims)
    CoordSpec(c.name, c.dims, c.values[idx...]; attrs=c.attrs)
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
