module GeoFetch

using Dates, Downloads, Extents, JSON
import GeoInterface as GI
import GeoFormatTypes as GFT

export Project, Source, Dataset, Chunk, All, Latest
export NOMADS, CDS, FIRMS, ETOPO, SRTM, GOES, HRRRArchive, NASAPower, USGSWater, NCEI, OISST, Landfire, NDBC, Nominatim
export NomadsDataset, CDSDataset, FIRMSDataset, ETOPODataset, SRTMDataset, GOESDataset, HRRRArchiveDataset, NASAPowerDataset, USGSWaterDataset, NCEIDataset, OISSTDataset, LandfireDataset, NDBCDataset, NominatimDataset
export datasets, help, metadata

#------------------------------------------------------------------------------# utils
function get_json(url::AbstractString; headers=Pair{String,String}[])
    io = IOBuffer()
    Downloads.download(url, io; headers)
    JSON.parse(String(take!(io)))
end

function post_json(url::AbstractString, body::AbstractString; headers=Pair{String,String}[])
    all_headers = [headers; "Content-Type" => "application/json"]
    io = IOBuffer()
    Downloads.request(url; method="POST", headers=all_headers, input=IOBuffer(body), output=io)
    JSON.parse(String(take!(io)))
end

#------------------------------------------------------------------------------# Project
const EARTH = Extent(X=(-180.0, 180.0), Y=(-90.0, 90.0))

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

function Base.fetch(proj::Project; verbose=true)
    for ds in proj.datasets
        verbose && println("Fetching dataset: ", summary(ds))
        for chunk in chunks(proj, ds)
            verbose && println("    - ", summary(chunk))
            dir = joinpath(proj.path, "data")
            mkpath(dir)
            file = joinpath(dir, filename(chunk))
            isfile(file) || fetch(chunk, file)
        end
    end
    return joinpath(proj.path, "data")
end

#------------------------------------------------------------------------------# Source
abstract type Source end
function datasets end
function help end

#------------------------------------------------------------------------------# Dataset
abstract type Dataset end
function chunks end
function metadata end
metadata(::Dataset) = Dict{Symbol,Any}()
GI.crs(::Dataset) = GFT.EPSG(4326)

#------------------------------------------------------------------------------# Chunk
abstract type Chunk end
function prefix end
function extension end
filename(data::Chunk) = string(prefix(data), "-", hash(data), ".", extension(data))
Base.filesize(::Chunk) = nothing

function _head_content_length(url::AbstractString; headers=Pair{String,String}[])::Union{Nothing, Int}
    resp_headers = Ref{Vector{Pair{String,String}}}()
    try
        Downloads.request(url; method="HEAD", headers, output=devnull, response_headers=resp_headers)
    catch
        return nothing
    end
    for (k, v) in resp_headers[]
        lowercase(k) == "content-length" && return parse(Int, v)
    end
    nothing
end

#------------------------------------------------------------------------------# All
struct All end

#------------------------------------------------------------------------------# Latest
"""Sentinel type for versioned datasets — resolves to the most recent available version."""
struct Latest end

#------------------------------------------------------------------------------# Sources
"""NOAA Operational Model Archive and Distribution System — real-time weather model output."""
struct NOMADS <: Source end

"""Copernicus Climate Data Store — ERA5 reanalysis and other climate datasets."""
struct CDS <: Source end

"""NASA Fire Information for Resource Management System — active fire/hotspot data."""
struct FIRMS <: Source end

"""NOAA ETOPO Global Relief Model — combined topography and bathymetry."""
struct ETOPO <: Source end

"""NASA Shuttle Radar Topography Mission — global elevation data at 1\" and 3\" resolution."""
struct SRTM <: Source end

"""NOAA Geostationary Operational Environmental Satellites — real-time imagery and products."""
struct GOES <: Source end

"""NOAA High-Resolution Rapid Refresh archive — hourly 3km weather forecasts (S3)."""
struct HRRRArchive <: Source end

"""NASA Prediction of Worldwide Energy Resources — global daily meteorological and solar data."""
struct NASAPower <: Source end

"""USGS Water Data — streamflow, gage height, water quality, and other hydrological observations."""
struct USGSWater <: Source end

"""NOAA National Centers for Environmental Information — historical weather and climate observations."""
struct NCEI <: Source end

"""NOAA Optimum Interpolation SST — daily global sea surface temperature on a 0.25° grid."""
struct OISST <: Source end

"""USGS LANDFIRE — wildland fire, vegetation, and fuel geospatial data via WCS."""
struct Landfire <: Source end

"""NOAA National Data Buoy Center — ocean and meteorological observations from moored and drifting buoys."""
struct NDBC <: Source end

"""OpenStreetMap Nominatim — geocoding, reverse geocoding, and OSM object lookup."""
struct Nominatim <: Source end

#------------------------------------------------------------------------------# includes
include("sources/NOMADS.jl")
include("sources/CDS.jl")
include("sources/FIRMS.jl")
include("sources/ETOPO.jl")
include("sources/SRTM.jl")
include("sources/GOES.jl")
include("sources/HRRRArchive.jl")
include("sources/Landfire.jl")
include("sources/NASAPower.jl")
include("sources/USGSWater.jl")
include("sources/NCEI.jl")
include("sources/OISST.jl")
include("sources/NDBC.jl")
include("sources/Nominatim.jl")

#------------------------------------------------------------------------------# Project methods (after types are defined)
chunks(proj::Project) = reduce(vcat, (chunks(proj, ds) for ds in proj.datasets); init=Chunk[])

function Base.filesize(p::Project, d::Dataset)
    m = metadata(d)
    get(m, :data_type, nothing) == "gridded" || return nothing
    res = get(m, :resolution, nothing)
    isnothing(res) && return nothing
    ext = p.extent
    n_lon = max(1, ceil(Int, (ext.X[2] - ext.X[1]) / res))
    n_lat = max(1, ceil(Int, (ext.Y[2] - ext.Y[1]) / res))
    n_vars = get(m, :n_variables, 1)
    n_levels = get(m, :n_levels, 1)
    bpv = get(m, :bytes_per_value, 4)
    tpd = get(m, :times_per_day, 0.0)
    if tpd > 0 && !isnothing(p.datetimes)
        n_days = Dates.value(Date(last(p.datetimes)) - Date(first(p.datetimes))) + 1
        n_times = max(1, ceil(Int, n_days * tpd))
    else
        n_times = 1
    end
    n_lon * n_lat * n_times * n_vars * n_levels * bpv
end

function Base.filesize(proj::Project)
    total = 0
    for ds in proj.datasets
        s = filesize(proj, ds)
        if !isnothing(s)
            total += s
        else
            for chunk in chunks(proj, ds)
                s = filesize(chunk)
                isnothing(s) || (total += s)
            end
        end
    end
    total
end

end # module GeoFetch
