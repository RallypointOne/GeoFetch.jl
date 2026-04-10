"""
    GeoFetch

Fetch geospatial data from multiple sources (NOMADS, CDS, etc.) into a unified project directory.

The main workflow is:

1. Create a [`Project`](@ref) with a spatial extent, time range, and list of datasets.
2. Call `fetch(project)` to download all data, skipping files that already exist.

### Examples

```julia
using GeoFetch, Dates, Extents

gfs = NOMADS.GFS_025
gfs.parameters = ["TMP"]
gfs.levels = ["2_m_above_ground"]

p = Project(
    geometry = Extent(X=(-90.0, -80.0), Y=(30.0, 40.0)),
    datetimes = (DateTime(2026, 4, 1), DateTime(2026, 4, 1)),
    datasets = [gfs],
)

fetch(p)
```
"""
module GeoFetch

using Dates, Downloads, Extents
import GeoInterface as GI
import GeoFormatTypes as GFT

export Region, Project, AbstractDataSource, help, All, NOMADS, CDS

#------------------------------------------------------------------------------# Project
const EARTH = Extent(X=(-180.0, 180.0), Y=(-90.0, 90.0))

"""
    Project(; geometry=EARTH, extent, datetimes, crs, path, datasets)

A geospatial project that defines what data to fetch and where to store it.

# Fields
- `geometry` — Area of interest.  Defaults to `EARTH` (global).
- `extent` — Bounding box derived from `geometry`.
- `datetimes` — `(start, stop)` time range, or `nothing` for all available data.
- `crs` — Coordinate reference system.  Defaults to EPSG:4326.
- `path` — Output directory.  Defaults to a temporary directory.
- `datasets` — Vector of [`Dataset`](@ref) subtypes to fetch.

### Examples

```julia
using Dates, Extents
p = Project(
    geometry = Extent(X=(-90.0, -80.0), Y=(30.0, 40.0)),
    datetimes = (DateTime(2023, 1, 1), DateTime(2023, 1, 31)),
    datasets = [NOMADS.GFS_025],
)
```
"""
@kwdef struct Project{G, E, C}
    geometry::G = EARTH
    extent::E = GI.extent(geometry)
    datetimes::Union{Nothing, Tuple{DateTime, DateTime}} = nothing
    crs::C = isnothing(geometry) ? GFT.EPSG("EPSG:4326") : GI.crs(geometry)
    path::String = mktempdir()
    datasets::Vector = []
end

function Base.show(io::IO, p::Project)
    println(io, "Project: $(p.path)")
    println(io, "    - geometry:  ", summary(p.geometry))
    println(io, "    - extent     ", p.extent)
    println(io, "    - datetimes: ", p.datetimes)
    println(io, "    - crs:       ", p.crs)
    isempty(p.datasets) || println(io, "    - datasets: ")
    for ds in p.datasets
        println(io, "        - ", summary(ds))
    end
end

"""
    fetch(project::Project; verbose=true)

Download all data for the project's datasets, skipping files that already exist on disk.
Returns the path to the `data/` directory inside the project.
"""
function fetch(proj::Project; verbose=true)
    for ds in proj.datasets
        verbose && println(io, "Fetching dataset: ", summary(ds))
        for chunk in chunks(proj, ds)
            verbose && println(io, "    - ", summary(chunk))
            file = joinpath(proj.path, "data", filename(chunk))
            isfile(file) || fetch(chunk, file)
        end
    end
    return joinpath(proj.path, "data")
end

#------------------------------------------------------------------------------# Dataset
"""
    Dataset

Abstract type for all data sources.  Each subtype must implement:

- `help(ds::Dataset)::String` — return a documentation URL.
- `chunks(project::Project, ds::Dataset)::Vector{<:Chunk}` — return the list of downloadable items.
"""
abstract type Dataset end

"""
    help(ds::Dataset) -> String

Return the documentation URL for a dataset.
"""
function help end

"""
    chunks(project::Project, ds::Dataset) -> Vector{<:Chunk}

Return the list of [`Chunk`](@ref)s needed to cover the project's spatiotemporal extent.
"""
function chunks end

#------------------------------------------------------------------------------# Chunk
"""
    Chunk

Abstract type for a single downloadable item from a [`Dataset`](@ref).

Each subtype must implement:

- `prefix(chunk)::Symbol` — identifier used in the local filename.
- `extension(chunk)::String` — file extension (e.g. `"grib2"`, `"nc"`).
- `fetch(chunk, file::String)` — download the chunk to `file`.

The local filename is generated automatically as `"\$prefix-\$hash.\$ext"`.
"""
abstract type Chunk end

"""
    prefix(chunk::Chunk) -> Symbol

Return the prefix used in the auto-generated filename for this chunk.
"""
function prefix end

"""
    extension(chunk::Chunk) -> String

Return the file extension (without dot) for this chunk.
"""
function extension end

"""
    filename(chunk::Chunk) -> String

Return the auto-generated filename: `"\$prefix-\$hash.\$ext"`.
"""
filename(data::Chunk) = string(prefix(data), "-", hash(data), ".", extension(data))


#------------------------------------------------------------------------------# StaticURL
"""
    StaticURL(url::String)

A [`Dataset`](@ref) that downloads a single file from a fixed URL.
"""
struct StaticURL <: Dataset
    url::String
end
struct StaticChunk <: Chunk
    url::String
end
chunks(::Project, o::StaticURL) = StaticChunk(o.url)
prefix(::StaticChunk) = :static_url
extension(o::StaticChunk) = basename(o)
fetch(o::StaticChunk, file::String) = download(o.url, file)

"""
    All()

Sentinel value meaning "all available".  Used as the default for dataset parameters
and levels (e.g. `NOMADS.Dataset` uses `All()` for `parameters` and `levels`).
"""
struct All end

#------------------------------------------------------------------------------# includes
include("NOMADS.jl")    # NOAA NOMADS
include("CDS.jl")       # Copernicus Climate Data Store

end # module GeoFetch
