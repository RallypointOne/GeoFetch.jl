"""
    NOMADS

Access NOAA NOMADS (National Operational Model Archive and Distribution System) data
via the GRIB filter service.

Browse available datasets with `NOMADS.DATASETS` or `NOMADS.datasets(...)`.
Popular datasets are available as constants: `NOMADS.GFS_025`, `NOMADS.HRRR_CONUS`, etc.

### Examples

```julia
gfs = NOMADS.GFS_025
gfs.parameters = ["TMP", "UGRD"]
gfs.levels = ["2_m_above_ground"]
```
"""
module NOMADS

using ..GeoFetch
using Dates
using Downloads
using Extents: Extent

#------------------------------------------------------------------------------# Category
"""
    Category

Classification for NOMADS datasets: `Global`, `Regional`, `Climate`, `Ocean`,
`SpaceWeather`, or `External`.
"""
@enum Category Global Regional Climate Ocean SpaceWeather External

#------------------------------------------------------------------------------# Dataset
"""
    Dataset(; category, name, freq, grib_filter, https, parameters=All(), levels=All())

A NOMADS dataset accessed via the GRIB filter.

# Const Fields
- `category::Category` — dataset classification.
- `name::String` — human-readable name.
- `freq::String` — update frequency.
- `grib_filter::String` — GRIB filter ID (empty if not available).
- `https::String` — path on the NOMADS HTTPS server.

# Mutable Fields
- `parameters` — GRIB variable names to download, or `All()`.
- `levels` — GRIB level names to download, or `All()`.
"""
@kwdef mutable struct Dataset <: GeoFetch.Dataset
    const category::Category
    const name::String
    const freq::String
    const grib_filter::String
    const https::String
    parameters = All()
    levels = All()
end

GeoFetch.help(d::Dataset) = "https://nomads.ncep.noaa.gov"

#------------------------------------------------------------------------------# urls
const BASE_URL = "https://nomads.ncep.noaa.gov"

# GRIB filter CGI endpoint URL for a dataset
_filter_base(d::Dataset)::String = "$BASE_URL/cgi-bin/filter_$(d.grib_filter).pl"

# Direct HTTPS file server URL for a dataset
_https_url(d::Dataset)::String = "$BASE_URL/pub/data/nccf/com/$(d.https)"

# Download a URL and return the response body as a String
function _download_text(url::AbstractString)::String
    io = IOBuffer()
    Downloads.download(url, io)
    String(take!(io))
end

# Extract all first capture groups matching `pattern` from `html`, deduplicated
function _parse_matches(html::AbstractString, pattern::Regex)::Vector{String}
    matches = String[]
    for m in eachmatch(pattern, html)
        push!(matches, m.captures[1])
    end
    unique(matches)
end

# Build a GRIB filter download URL.  `extent` sets the subregion; `nothing` means global.
function _download_url(d::Dataset, server_dir::AbstractString, file::AbstractString, extent)::String
    encoded_dir = replace(server_dir, "/" => "%2F")
    params = ["file=$file", "dir=$encoded_dir"]
    if d.parameters isa All
        push!(params, "all_var=on")
    else
        for v in d.parameters
            push!(params, "var_$v=on")
        end
    end
    if d.levels isa All
        push!(params, "all_lev=on")
    else
        for l in d.levels
            push!(params, "lev_$l=on")
        end
    end
    if !isnothing(extent)
        append!(params, [
            "subregion=",
            "toplat=$(extent.Y[2])",
            "leftlon=$(extent.X[1])",
            "rightlon=$(extent.X[2])",
            "bottomlat=$(extent.Y[1])"
        ])
    end
    "$(_filter_base(d))?" * join(params, "&")
end

# Extract a Date from a NOMADS directory name like "/gfs.20260409/12/atmos" → 2026-04-09
function _dir_date(dir::AbstractString)::Union{Date, Nothing}
    m = match(r"(\d{4})(\d{2})(\d{2})", dir)
    isnothing(m) ? nothing : Date(parse(Int, m[1]), parse(Int, m[2]), parse(Int, m[3]))
end

# Navigate a GRIB filter directory tree from `start_dir` to find downloadable files.
# Returns (server_dir, files) or nothing if no files found in any branch.
function _descend(base::AbstractString, start_dir::AbstractString)::Union{Nothing, Tuple{String, Vector{String}}}
    encoded = replace(start_dir, "/" => "%2F")
    html = try
        _download_text("$base?dir=$encoded")
    catch
        return nothing
    end
    files = _parse_matches(html, r"<option\s+value=\"([^\"]+)\"")
    isempty(files) || return (start_dir, files)
    subdirs = [replace(d, "%2F" => "/") for d in _parse_matches(html, r"dir=(%2F[^\"&]+)")]
    for subdir in reverse(sort(subdirs))
        result = _descend(base, subdir)
        !isnothing(result) && return result
    end
    nothing
end

# Discover available files on NOMADS, picking the directory matching `target_date`
# (or the latest available).  Falls back to older directories if the latest has no data.
# Returns (server_dir, files).
function _discover(base::AbstractString, target_date::Union{Date, Nothing})::Tuple{String, Vector{String}}
    html = _download_text(base)
    dirs = [replace(d, "%2F" => "/") for d in _parse_matches(html, r"dir=(%2F[^\"&]+)")]
    isempty(dirs) && error("No data available at $base")
    if !isnothing(target_date)
        matching = filter(d -> _dir_date(d) == target_date, dirs)
        candidates = isempty(matching) ? dirs : matching
    else
        candidates = dirs
    end
    for dir in reverse(sort(candidates))
        result = _descend(base, dir)
        !isnothing(result) && return result
    end
    error("No files found at $base")
end

#------------------------------------------------------------------------------# GribChunk
"""
    GribChunk

A single GRIB2 file to download from the NOMADS GRIB filter.
Implements the [`Chunk`](@ref GeoFetch.Chunk) interface.
"""
struct GribChunk <: GeoFetch.Chunk
    url::String
    remote_filename::String
    dataset_name::String
end

GeoFetch.prefix(c::GribChunk)::Symbol = Symbol(c.dataset_name)
GeoFetch.extension(c::GribChunk)::String = "grib2"
GeoFetch.fetch(c::GribChunk, file::String) = Downloads.download(c.url, file)

#------------------------------------------------------------------------------# chunks
function GeoFetch.chunks(p::GeoFetch.Project, d::Dataset)::Vector{GribChunk}
    isempty(d.grib_filter) && error("Dataset \"$(d.name)\" does not have a GRIB filter available.")
    base = _filter_base(d)
    target_date = isnothing(p.datetimes) ? nothing : Date(first(p.datetimes))
    extent = p.extent == GeoFetch.EARTH ? nothing : p.extent
    server_dir, files = _discover(base, target_date)
    [GribChunk(_download_url(d, server_dir, f, extent), f, d.grib_filter) for f in files]
end

#------------------------------------------------------------------------------# DATASETS
const DATASETS = [
    # Global Models
    Dataset(category=Global, name="AIGFS", freq="", grib_filter="", https="aigfs/prod"),
    Dataset(category=Global, name="AIGEFS", freq="", grib_filter="", https="aigefs/prod"),
    Dataset(category=Global, name="GDAS", freq="", grib_filter="fnl", https="gfs/prod"),
    Dataset(category=Global, name="GDAS 0.25", freq="", grib_filter="gdas_0p25", https="gfs/prod"),
    Dataset(category=Global, name="GFS 0.25 Degree", freq="", grib_filter="gfs_0p25", https="gfs/prod"),
    Dataset(category=Global, name="GFS 0.25 Degree Hourly", freq="", grib_filter="gfs_0p25_1hr", https="gfs/prod"),
    Dataset(category=Global, name="GFS 0.25 Degree (Secondary Parms)", freq="", grib_filter="gfs_0p25b", https="gfs/prod"),
    Dataset(category=Global, name="GFS 0.50 Degree", freq="", grib_filter="gfs_0p50", https="gfs/prod"),
    Dataset(category=Global, name="GFS 1.00 Degree", freq="", grib_filter="gfs_1p00", https="gfs/prod"),
    Dataset(category=Global, name="GFS sflux", freq="", grib_filter="gfs_sflux", https="gfs/prod"),
    Dataset(category=Global, name="GFS MOS", freq="", grib_filter="", https="gfs_mos/prod"),
    Dataset(category=Global, name="GFS Ensemble 0.5 Degree", freq="", grib_filter="gefs_atmos_0p50a", https="gens/prod"),
    Dataset(category=Global, name="GFS Ensemble 0.5 Degree (Secondary Params)", freq="", grib_filter="gefs_atmos_0p50b", https="gens/prod"),
    Dataset(category=Global, name="GFS Ensemble 0.25 Degree", freq="", grib_filter="gefs_atmos_0p25s", https="gens/prod"),
    Dataset(category=Global, name="GFS Ensemble Chem 0.5 Degree", freq="", grib_filter="gefs_chem_0p50", https="gens/prod"),
    Dataset(category=Global, name="GFS Ensemble Chem 0.25 Degree", freq="", grib_filter="gefs_chem_0p25", https="gens/prod"),
    Dataset(category=Global, name="GFS Ensemble 0.5 Degree Bias-Corrected", freq="", grib_filter="gensbc", https="naefs/prod"),
    Dataset(category=Global, name="GFS Ensemble NDGD resolution Bias-Corrected", freq="", grib_filter="gensbc_ndgd", https="naefs/prod"),
    Dataset(category=Global, name="HGEFS", freq="", grib_filter="", https="hgefs/prod"),
    Dataset(category=Global, name="NAEFS high resolution Bias-Corrected", freq="", grib_filter="naefsbc", https="naefs/prod"),
    Dataset(category=Global, name="NAEFS NDGD resolution Bias-Corrected", freq="", grib_filter="naefsbc_ndgd", https="naefs/prod"),
    Dataset(category=Global, name="ObsProc (Observations Processing)", freq="", grib_filter="", https="obsproc/prod"),
    Dataset(category=Global, name="UVI (Ultraviolet Index)", freq="", grib_filter="", https="uvi/prod"),
    # Regional Models
    Dataset(category=Regional, name="AQM Daily Maximum", freq="", grib_filter="aqm_daily", https="aqm/prod"),
    Dataset(category=Regional, name="AQM Hourly Surface Ozone", freq="", grib_filter="aqm_ozone_1hr", https="aqm/prod"),
    Dataset(category=Regional, name="DAFS", freq="", grib_filter="", https="dafs/prod"),
    Dataset(category=Regional, name="HIRESW Alaska", freq="", grib_filter="hiresak", https="hiresw/prod"),
    Dataset(category=Regional, name="HIRESW CONUS", freq="", grib_filter="hiresconus", https="hiresw/prod"),
    Dataset(category=Regional, name="HIRESW Guam", freq="", grib_filter="hiresguam", https="hiresw/prod"),
    Dataset(category=Regional, name="HIRESW Hawaii", freq="", grib_filter="hireshi", https="hiresw/prod"),
    Dataset(category=Regional, name="HIRESW Puerto Rico", freq="", grib_filter="hirespr", https="hiresw/prod"),
    Dataset(category=Regional, name="HREF Alaska", freq="", grib_filter="hrefak", https="href/prod"),
    Dataset(category=Regional, name="HREF CONUS", freq="", grib_filter="hrefconus", https="href/prod"),
    Dataset(category=Regional, name="HREF Hawaii", freq="", grib_filter="hrefhi", https="href/prod"),
    Dataset(category=Regional, name="HREF Puerto Rico", freq="", grib_filter="hrefpr", https="href/prod"),
    Dataset(category=Regional, name="HRRR", freq="", grib_filter="hrrr_2d", https="hrrr/prod"),
    Dataset(category=Regional, name="HRRR Sub Hourly", freq="", grib_filter="hrrr_sub", https="hrrr/prod"),
    Dataset(category=Regional, name="HRRR AK", freq="", grib_filter="hrrrak_2d", https="hrrr/prod"),
    Dataset(category=Regional, name="HRRR AK Sub Hourly", freq="", grib_filter="hrrrak_sub", https="hrrr/prod"),
    Dataset(category=Regional, name="HWRF", freq="", grib_filter="", https="hwrf/prod"),
    Dataset(category=Regional, name="HMON", freq="", grib_filter="", https="hmon/prod"),
    Dataset(category=Regional, name="HAFS", freq="", grib_filter="", https="hafs/prod"),
    Dataset(category=Regional, name="HYSPLIT", freq="", grib_filter="", https="hysplit/prod"),
    Dataset(category=Regional, name="LAMP", freq="", grib_filter="", https="lmp/prod"),
    Dataset(category=Regional, name="GLMP (Gridded Lamp)", freq="", grib_filter="", https="glmp/prod"),
    Dataset(category=Regional, name="NAM Alaska Pressure Level Vars (11.25km)", freq="", grib_filter="nam_ak", https="nam/prod"),
    Dataset(category=Regional, name="NAM Alaska Surface Vars (11.25km)", freq="", grib_filter="nam_ak_surf", https="nam/prod"),
    Dataset(category=Regional, name="NAM CONUS (12km)", freq="", grib_filter="nam", https="nam/prod"),
    Dataset(category=Regional, name="NAM North America (32km)", freq="", grib_filter="nam_na", https="nam/prod"),
    Dataset(category=Regional, name="NAM Caribbean/Central America", freq="", grib_filter="nam_crb", https="nam/prod"),
    Dataset(category=Regional, name="NAM Pacific", freq="", grib_filter="nam_pac", https="nam/prod"),
    Dataset(category=Regional, name="NAM NEST Alaska", freq="", grib_filter="nam_alaskanest", https="nam/prod"),
    Dataset(category=Regional, name="NAM NEST CONUS", freq="", grib_filter="nam_conusnest", https="nam/prod"),
    Dataset(category=Regional, name="NAM NEST HAWAII", freq="", grib_filter="nam_hawaiinest", https="nam/prod"),
    Dataset(category=Regional, name="NAM NEST Puerto Rico", freq="", grib_filter="nam_priconest", https="nam/prod"),
    Dataset(category=Regional, name="NAM SmartInit", freq="", grib_filter="", https="smartinit/prod"),
    Dataset(category=Regional, name="NAM MOS", freq="", grib_filter="", https="nam_mos/prod"),
    Dataset(category=Regional, name="National Blend of Models", freq="", grib_filter="blend", https="blend/prod"),
    Dataset(category=Regional, name="North American Land Data Assimilation System", freq="", grib_filter="", https="nldas/prod"),
    Dataset(category=Regional, name="RTMA ALASKA", freq="", grib_filter="akrtma", https="rtma/prod"),
    Dataset(category=Regional, name="RTMA2.5 CONUS", freq="", grib_filter="rtma2p5", https="rtma/prod"),
    Dataset(category=Regional, name="RTMA CONUS Rapid Updates", freq="", grib_filter="rtma_ru", https="rtma/prod"),
    Dataset(category=Regional, name="RTMA Guam", freq="", grib_filter="gurtma", https="rtma/prod"),
    Dataset(category=Regional, name="RTMA Hawaii", freq="", grib_filter="hirtma", https="rtma/prod"),
    Dataset(category=Regional, name="RTMA Puerto Rico", freq="", grib_filter="prrtma", https="rtma/prod"),
    Dataset(category=Regional, name="RAP", freq="", grib_filter="rap", https="rap/prod"),
    Dataset(category=Regional, name="RAP 32km North America", freq="", grib_filter="rap32", https="rap/prod"),
    Dataset(category=Regional, name="RAP Alaska", freq="", grib_filter="rap242", https="rap/prod"),
    Dataset(category=Regional, name="RAP Eastern North Pacific", freq="", grib_filter="rap243", https="rap/prod"),
    Dataset(category=Regional, name="SPC-POST", freq="", grib_filter="spc_post", https="spc_post/prod"),
    Dataset(category=Regional, name="SREF CONUS (40km)", freq="", grib_filter="sref", https="sref/prod"),
    Dataset(category=Regional, name="SREF CONUS (40km) Bias-Corrected", freq="", grib_filter="srefbc", https="sref/prod"),
    Dataset(category=Regional, name="SREF North America (32km)", freq="", grib_filter="sref_na", https="sref/prod"),
    Dataset(category=Regional, name="SREF North America (16km)", freq="", grib_filter="sref_132", https="sref/prod"),
    Dataset(category=Regional, name="URMA", freq="", grib_filter="", https="urma/prod"),
    # Climate Models
    Dataset(category=Climate, name="Climate Forecast System Flux Products", freq="", grib_filter="cfs_flx", https="cfs/prod"),
    Dataset(category=Climate, name="Climate Forecast System 3D Pressure Products", freq="", grib_filter="cfs_pgb", https="cfs/prod"),
    Dataset(category=Climate, name="CORe", freq="", grib_filter="", https="core/prod"),
    Dataset(category=Climate, name="Climatology Calibrated Precipitation Analysis", freq="", grib_filter="", https="ccpa/prod"),
    # Ocean/Lake/River Models
    Dataset(category=Ocean, name="National Water Model", freq="", grib_filter="", https="nwm/prod"),
    Dataset(category=Ocean, name="RTOFS Atlantic", freq="", grib_filter="", https="rtofs/prod"),
    Dataset(category=Ocean, name="RTOFS Global", freq="", grib_filter="", https="rtofs/prod"),
    Dataset(category=Ocean, name="Sea Ice Analysis", freq="", grib_filter="seaice", https="seaice_analysis/prod"),
    Dataset(category=Ocean, name="Sea Ice Drift", freq="", grib_filter="", https="seaice_drift/prod"),
    Dataset(category=Ocean, name="Great Lakes Wave Unstructured (GLWU)", freq="", grib_filter="glwu", https="glwu/prod"),
    Dataset(category=Ocean, name="GFS Wave", freq="", grib_filter="gfswave", https="gfs/prod"),
    Dataset(category=Ocean, name="GFS Ensemble Wave", freq="", grib_filter="gefs_wave_0p25", https="gens/prod"),
    Dataset(category=Ocean, name="NCEP and FNMOC Combined Ensemble Wave", freq="", grib_filter="nfcens", https="wave_nfcens/prod"),
    Dataset(category=Ocean, name="P-Surge", freq="", grib_filter="", https="psurge/prod"),
    Dataset(category=Ocean, name="STOFS 2D Global", freq="", grib_filter="stofs_2d_glo", https="stofs/prod"),
    Dataset(category=Ocean, name="STOFS 3D Atlantic", freq="", grib_filter="stofs_3d_atl", https="stofs/prod"),
    Dataset(category=Ocean, name="ETSS (Extra-Tropical Storm Surge)", freq="", grib_filter="", https="petss/prod"),
    Dataset(category=Ocean, name="P-ETSS (Probabilistic ETSS)", freq="", grib_filter="", https="petss/prod"),
    Dataset(category=Ocean, name="National Operational Coastal Modeling Program", freq="", grib_filter="", https="nosofs/prod"),
    Dataset(category=Ocean, name="NWPS Alaska Region", freq="", grib_filter="arnwps", https="nwps/prod"),
    Dataset(category=Ocean, name="NWPS Eastern Region", freq="", grib_filter="ernwps", https="nwps/prod"),
    Dataset(category=Ocean, name="NWPS Pacific Region", freq="", grib_filter="prnwps", https="nwps/prod"),
    Dataset(category=Ocean, name="NWPS Southern Region", freq="", grib_filter="srnwps", https="nwps/prod"),
    Dataset(category=Ocean, name="NWPS Western Region", freq="", grib_filter="wrnwps", https="nwps/prod"),
    Dataset(category=Ocean, name="NSST (Near Sea Surface Temperatures)", freq="", grib_filter="", https="nsst/prod"),
    # Space Weather Models
    Dataset(category=SpaceWeather, name="WSA-Enlil", freq="", grib_filter="", https="wsa_enlil/prod"),
    Dataset(category=SpaceWeather, name="SWMF-Geospace", freq="", grib_filter="", https="swmf/prod"),
    Dataset(category=SpaceWeather, name="WFS (WAM-IPE Forecast System)", freq="", grib_filter="", https="wfs/prod"),
    # External Models
    Dataset(category=External, name="CMC Ensemble", freq="", grib_filter="cmcens", https="naefs/prod"),
    Dataset(category=External, name="FNMOC Ensemble and Bias Corrected", freq="", grib_filter="fens", https="naefs/prod"),
    Dataset(category=External, name="NAVGEM", freq="", grib_filter="", https="fnmoc/prod"),
    Dataset(category=External, name="NCOM", freq="", grib_filter="", https="ncom/prod"),
    Dataset(category=External, name="HYCOM", freq="", grib_filter="", https="navo/prod"),
    Dataset(category=External, name="557ww Ensemble", freq="", grib_filter="557ww", https="557ww/prod"),
]

#------------------------------------------------------------------------------# Popular Datasets
const GFS_025 = DATASETS[findfirst(d -> d.grib_filter == "gfs_0p25", DATASETS)]
const GFS_025_HOURLY = DATASETS[findfirst(d -> d.grib_filter == "gfs_0p25_1hr", DATASETS)]
const GFS_050 = DATASETS[findfirst(d -> d.grib_filter == "gfs_0p50", DATASETS)]
const GFS_100 = DATASETS[findfirst(d -> d.grib_filter == "gfs_1p00", DATASETS)]
const HRRR_CONUS = DATASETS[findfirst(d -> d.grib_filter == "hrrr_2d", DATASETS)]
const HRRR_CONUS_SUB = DATASETS[findfirst(d -> d.grib_filter == "hrrr_sub", DATASETS)]
const HRRR_AK = DATASETS[findfirst(d -> d.grib_filter == "hrrrak_2d", DATASETS)]
const NAM_CONUS = DATASETS[findfirst(d -> d.grib_filter == "nam", DATASETS)]
const RAP = DATASETS[findfirst(d -> d.grib_filter == "rap", DATASETS)]

#------------------------------------------------------------------------------# Dataset querying
"""
    datasets(; category=nothing, name=nothing, freq=nothing) -> Dict{String, Dataset}

Filter `DATASETS` by keyword.  All filters use substring matching except `category`,
which requires an exact `Category` match.

### Examples

```julia
NOMADS.datasets(name="GFS")
NOMADS.datasets(category=NOMADS.Regional, name="HRRR")
```
"""
function datasets(; category=nothing, name=nothing, freq=nothing)
    out = filter(d -> (category === nothing || d.category == category) &&
                 (name === nothing || occursin(name, d.name)) &&
                 (freq === nothing || occursin(freq, d.freq)), DATASETS)
    Dict(x.name => x for x in out)
end


end  # module NOMADS
