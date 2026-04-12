module GeoFetchLandfire

using GeoFetch, Landfire

import GeoFetch: Chunk, Dataset, EARTH, Project, Source, chunks, datasets, extension, fetch, help, prefix

"""LANDFIRE geospatial layers via Landfire.jl."""
struct LandfireSource <: Source end

"""A LANDFIRE dataset request scoped to a GeoFetch project extent."""
@kwdef struct LandfireDataset <: Dataset
    products::Vector{Landfire.Product} = Landfire.Product[]
    email::String = get(ENV, "LANDFIRE_EMAIL", "")
    output_projection::Union{Nothing, String} = nothing
    resample_resolution::Union{Nothing, Int} = nothing
    edit_rule::Union{Nothing, String} = nothing
    edit_mask::Union{Nothing, String} = nothing
    priority_code::Union{Nothing, String} = nothing
end

struct LandfireChunk <: Chunk
    dataset::Landfire.Dataset
    layers::Vector{String}
end

help(::LandfireSource) = "https://lfps.usgs.gov/"
help(::LandfireDataset) = "https://lfps.usgs.gov/"

function datasets(::LandfireSource; products=nothing, latest::Bool=true, refresh::Bool=false, kw...)
    prods = isnothing(products) ? Landfire.products(latest; refresh, kw...) : products
    [LandfireDataset(products=[prod]) for prod in prods]
end

function chunks(p::Project, d::LandfireDataset)::Vector{LandfireChunk}
    isempty(d.products) && error(
        "LandfireDataset requires at least one Landfire.Product. " *
        "Use `Landfire.products(...)` to browse available products."
    )
    isempty(d.email) && error(
        "LANDFIRE email not found. Set `LANDFIRE_EMAIL` or pass `email` to LandfireDataset."
    )
    p.extent == EARTH && error(
        "LANDFIRE requires a bounded extent (not global). Set geometry or extent on the Project."
    )

    data = Landfire.Dataset(d.products, p.extent;
        email=d.email,
        output_projection=d.output_projection,
        resample_resolution=d.resample_resolution,
        edit_rule=d.edit_rule,
        edit_mask=d.edit_mask,
        priority_code=d.priority_code,
    )

    [LandfireChunk(data, [prod.layer for prod in d.products])]
end

prefix(c::LandfireChunk)::Symbol = Symbol("landfire_", join(unique(c.layers), "_"))
extension(::LandfireChunk)::String = "tif"

function fetch(c::LandfireChunk, file::String)
    src = Base.get(c.dataset)
    cp(src, file; force=true)
    return file
end

end
