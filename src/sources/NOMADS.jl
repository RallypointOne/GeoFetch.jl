#------------------------------------------------------------------------------# NOMADS
# NOMADS dataset categories matching https://nomads.ncep.noaa.gov sidebar sections
@enum Category Global Regional Climate Ocean SpaceWeather External

"""NOMADS forecast dataset identified by category, name, and GRIB filter URL."""
@kwdef mutable struct NomadsDataset <: Dataset
    const category::Category
    const name::String
    const freq::String
    const grib_filter::String
    const https::String
    parameters = All()
    levels = All()
end

help(::NOMADS) = "https://nomads.ncep.noaa.gov"
help(::NomadsDataset) = "https://nomads.ncep.noaa.gov"

struct GribChunk <: Chunk
    url::String
    remote_filename::String
    dataset_name::String
end

prefix(c::GribChunk)::Symbol = Symbol(c.dataset_name)
extension(::GribChunk)::String = "grib2"
fetch(c::GribChunk, file::String) = Downloads.download(c.url, file)
Base.filesize(c::GribChunk) = _head_content_length(c.url)

#------------------------------------------------------------------------------# URLs
const _NOMADS_BASE_URL = "https://nomads.ncep.noaa.gov"

_nomads_filter_base(d::NomadsDataset) = "$(_NOMADS_BASE_URL)/cgi-bin/filter_$(d.grib_filter).pl"
_nomads_https_url(d::NomadsDataset) = "$(_NOMADS_BASE_URL)/pub/data/nccf/com/$(d.https)"

function _nomads_download_text(url::AbstractString)::String
    io = IOBuffer()
    Downloads.download(url, io)
    String(take!(io))
end

function _nomads_parse_matches(html::AbstractString, pattern::Regex)::Vector{String}
    matches = String[]
    for m in eachmatch(pattern, html)
        push!(matches, m.captures[1])
    end
    unique(matches)
end

function _nomads_download_url(d::NomadsDataset, server_dir::AbstractString, file::AbstractString, extent)::String
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
    "$(_nomads_filter_base(d))?" * join(params, "&")
end

function _nomads_dir_date(dir::AbstractString)::Union{Date, Nothing}
    m = match(r"(\d{4})(\d{2})(\d{2})", dir)
    isnothing(m) ? nothing : Date(parse(Int, m[1]), parse(Int, m[2]), parse(Int, m[3]))
end

function _nomads_descend(base::AbstractString, start_dir::AbstractString)::Union{Nothing, Tuple{String, Vector{String}}}
    encoded = replace(start_dir, "/" => "%2F")
    html = try
        _nomads_download_text("$base?dir=$encoded")
    catch
        return nothing
    end
    files = _nomads_parse_matches(html, r"<option\s+value=\"([^\"]+)\"")
    isempty(files) || return (start_dir, files)
    subdirs = [replace(d, "%2F" => "/") for d in _nomads_parse_matches(html, r"dir=(%2F[^\"&]+)")]
    for subdir in reverse(sort(subdirs))
        result = _nomads_descend(base, subdir)
        !isnothing(result) && return result
    end
    nothing
end

function _nomads_discover(base::AbstractString, target_date::Union{Date, Nothing})::Tuple{String, Vector{String}}
    html = _nomads_download_text(base)
    dirs = [replace(d, "%2F" => "/") for d in _nomads_parse_matches(html, r"dir=(%2F[^\"&]+)")]
    isempty(dirs) && error("No data available at $base")
    if !isnothing(target_date)
        matching = filter(d -> _nomads_dir_date(d) == target_date, dirs)
        candidates = isempty(matching) ? dirs : matching
    else
        candidates = dirs
    end
    for dir in reverse(sort(candidates))
        result = _nomads_descend(base, dir)
        !isnothing(result) && return result
    end
    error("No files found at $base")
end

#------------------------------------------------------------------------------# chunks
function chunks(p::Project, d::NomadsDataset)::Vector{GribChunk}
    isempty(d.grib_filter) && error("Dataset \"$(d.name)\" does not have a GRIB filter available.")
    base = _nomads_filter_base(d)
    target_date = isnothing(p.datetimes) ? nothing : Date(first(p.datetimes))
    extent = p.extent == EARTH ? nothing : p.extent
    server_dir, files = _nomads_discover(base, target_date)
    [GribChunk(_nomads_download_url(d, server_dir, f, extent), f, d.grib_filter) for f in files]
end

#------------------------------------------------------------------------------# DATASETS
const _NOMADS_DATASETS = [
    # Global Models
    NomadsDataset(category=Global, name="AIGFS", freq="", grib_filter="", https="aigfs/prod"),
    NomadsDataset(category=Global, name="AIGEFS", freq="", grib_filter="", https="aigefs/prod"),
    NomadsDataset(category=Global, name="GDAS", freq="", grib_filter="fnl", https="gfs/prod"),
    NomadsDataset(category=Global, name="GDAS 0.25", freq="", grib_filter="gdas_0p25", https="gfs/prod"),
    NomadsDataset(category=Global, name="GFS 0.25 Degree", freq="", grib_filter="gfs_0p25", https="gfs/prod"),
    NomadsDataset(category=Global, name="GFS 0.25 Degree Hourly", freq="", grib_filter="gfs_0p25_1hr", https="gfs/prod"),
    NomadsDataset(category=Global, name="GFS 0.25 Degree (Secondary Parms)", freq="", grib_filter="gfs_0p25b", https="gfs/prod"),
    NomadsDataset(category=Global, name="GFS 0.50 Degree", freq="", grib_filter="gfs_0p50", https="gfs/prod"),
    NomadsDataset(category=Global, name="GFS 1.00 Degree", freq="", grib_filter="gfs_1p00", https="gfs/prod"),
    NomadsDataset(category=Global, name="GFS sflux", freq="", grib_filter="gfs_sflux", https="gfs/prod"),
    NomadsDataset(category=Global, name="GFS MOS", freq="", grib_filter="", https="gfs_mos/prod"),
    NomadsDataset(category=Global, name="GFS Ensemble 0.5 Degree", freq="", grib_filter="gefs_atmos_0p50a", https="gens/prod"),
    NomadsDataset(category=Global, name="GFS Ensemble 0.5 Degree (Secondary Params)", freq="", grib_filter="gefs_atmos_0p50b", https="gens/prod"),
    NomadsDataset(category=Global, name="GFS Ensemble 0.25 Degree", freq="", grib_filter="gefs_atmos_0p25s", https="gens/prod"),
    NomadsDataset(category=Global, name="GFS Ensemble Chem 0.5 Degree", freq="", grib_filter="gefs_chem_0p50", https="gens/prod"),
    NomadsDataset(category=Global, name="GFS Ensemble Chem 0.25 Degree", freq="", grib_filter="gefs_chem_0p25", https="gens/prod"),
    NomadsDataset(category=Global, name="GFS Ensemble 0.5 Degree Bias-Corrected", freq="", grib_filter="gensbc", https="naefs/prod"),
    NomadsDataset(category=Global, name="GFS Ensemble NDGD resolution Bias-Corrected", freq="", grib_filter="gensbc_ndgd", https="naefs/prod"),
    NomadsDataset(category=Global, name="HGEFS", freq="", grib_filter="", https="hgefs/prod"),
    NomadsDataset(category=Global, name="NAEFS high resolution Bias-Corrected", freq="", grib_filter="naefsbc", https="naefs/prod"),
    NomadsDataset(category=Global, name="NAEFS NDGD resolution Bias-Corrected", freq="", grib_filter="naefsbc_ndgd", https="naefs/prod"),
    NomadsDataset(category=Global, name="ObsProc (Observations Processing)", freq="", grib_filter="", https="obsproc/prod"),
    NomadsDataset(category=Global, name="UVI (Ultraviolet Index)", freq="", grib_filter="", https="uvi/prod"),
    # Regional Models
    NomadsDataset(category=Regional, name="AQM Daily Maximum", freq="", grib_filter="aqm_daily", https="aqm/prod"),
    NomadsDataset(category=Regional, name="AQM Hourly Surface Ozone", freq="", grib_filter="aqm_ozone_1hr", https="aqm/prod"),
    NomadsDataset(category=Regional, name="DAFS", freq="", grib_filter="", https="dafs/prod"),
    NomadsDataset(category=Regional, name="HIRESW Alaska", freq="", grib_filter="hiresak", https="hiresw/prod"),
    NomadsDataset(category=Regional, name="HIRESW CONUS", freq="", grib_filter="hiresconus", https="hiresw/prod"),
    NomadsDataset(category=Regional, name="HIRESW Guam", freq="", grib_filter="hiresguam", https="hiresw/prod"),
    NomadsDataset(category=Regional, name="HIRESW Hawaii", freq="", grib_filter="hireshi", https="hiresw/prod"),
    NomadsDataset(category=Regional, name="HIRESW Puerto Rico", freq="", grib_filter="hirespr", https="hiresw/prod"),
    NomadsDataset(category=Regional, name="HREF Alaska", freq="", grib_filter="hrefak", https="href/prod"),
    NomadsDataset(category=Regional, name="HREF CONUS", freq="", grib_filter="hrefconus", https="href/prod"),
    NomadsDataset(category=Regional, name="HREF Hawaii", freq="", grib_filter="hrefhi", https="href/prod"),
    NomadsDataset(category=Regional, name="HREF Puerto Rico", freq="", grib_filter="hrefpr", https="href/prod"),
    NomadsDataset(category=Regional, name="HRRR", freq="", grib_filter="hrrr_2d", https="hrrr/prod"),
    NomadsDataset(category=Regional, name="HRRR Sub Hourly", freq="", grib_filter="hrrr_sub", https="hrrr/prod"),
    NomadsDataset(category=Regional, name="HRRR AK", freq="", grib_filter="hrrrak_2d", https="hrrr/prod"),
    NomadsDataset(category=Regional, name="HRRR AK Sub Hourly", freq="", grib_filter="hrrrak_sub", https="hrrr/prod"),
    NomadsDataset(category=Regional, name="HWRF", freq="", grib_filter="", https="hwrf/prod"),
    NomadsDataset(category=Regional, name="HMON", freq="", grib_filter="", https="hmon/prod"),
    NomadsDataset(category=Regional, name="HAFS", freq="", grib_filter="", https="hafs/prod"),
    NomadsDataset(category=Regional, name="HYSPLIT", freq="", grib_filter="", https="hysplit/prod"),
    NomadsDataset(category=Regional, name="LAMP", freq="", grib_filter="", https="lmp/prod"),
    NomadsDataset(category=Regional, name="GLMP (Gridded Lamp)", freq="", grib_filter="", https="glmp/prod"),
    NomadsDataset(category=Regional, name="NAM Alaska Pressure Level Vars (11.25km)", freq="", grib_filter="nam_ak", https="nam/prod"),
    NomadsDataset(category=Regional, name="NAM Alaska Surface Vars (11.25km)", freq="", grib_filter="nam_ak_surf", https="nam/prod"),
    NomadsDataset(category=Regional, name="NAM CONUS (12km)", freq="", grib_filter="nam", https="nam/prod"),
    NomadsDataset(category=Regional, name="NAM North America (32km)", freq="", grib_filter="nam_na", https="nam/prod"),
    NomadsDataset(category=Regional, name="NAM Caribbean/Central America", freq="", grib_filter="nam_crb", https="nam/prod"),
    NomadsDataset(category=Regional, name="NAM Pacific", freq="", grib_filter="nam_pac", https="nam/prod"),
    NomadsDataset(category=Regional, name="NAM NEST Alaska", freq="", grib_filter="nam_alaskanest", https="nam/prod"),
    NomadsDataset(category=Regional, name="NAM NEST CONUS", freq="", grib_filter="nam_conusnest", https="nam/prod"),
    NomadsDataset(category=Regional, name="NAM NEST HAWAII", freq="", grib_filter="nam_hawaiinest", https="nam/prod"),
    NomadsDataset(category=Regional, name="NAM NEST Puerto Rico", freq="", grib_filter="nam_priconest", https="nam/prod"),
    NomadsDataset(category=Regional, name="NAM SmartInit", freq="", grib_filter="", https="smartinit/prod"),
    NomadsDataset(category=Regional, name="NAM MOS", freq="", grib_filter="", https="nam_mos/prod"),
    NomadsDataset(category=Regional, name="National Blend of Models", freq="", grib_filter="blend", https="blend/prod"),
    NomadsDataset(category=Regional, name="North American Land Data Assimilation System", freq="", grib_filter="", https="nldas/prod"),
    NomadsDataset(category=Regional, name="RTMA ALASKA", freq="", grib_filter="akrtma", https="rtma/prod"),
    NomadsDataset(category=Regional, name="RTMA2.5 CONUS", freq="", grib_filter="rtma2p5", https="rtma/prod"),
    NomadsDataset(category=Regional, name="RTMA CONUS Rapid Updates", freq="", grib_filter="rtma_ru", https="rtma/prod"),
    NomadsDataset(category=Regional, name="RTMA Guam", freq="", grib_filter="gurtma", https="rtma/prod"),
    NomadsDataset(category=Regional, name="RTMA Hawaii", freq="", grib_filter="hirtma", https="rtma/prod"),
    NomadsDataset(category=Regional, name="RTMA Puerto Rico", freq="", grib_filter="prrtma", https="rtma/prod"),
    NomadsDataset(category=Regional, name="RAP", freq="", grib_filter="rap", https="rap/prod"),
    NomadsDataset(category=Regional, name="RAP 32km North America", freq="", grib_filter="rap32", https="rap/prod"),
    NomadsDataset(category=Regional, name="RAP Alaska", freq="", grib_filter="rap242", https="rap/prod"),
    NomadsDataset(category=Regional, name="RAP Eastern North Pacific", freq="", grib_filter="rap243", https="rap/prod"),
    NomadsDataset(category=Regional, name="SPC-POST", freq="", grib_filter="spc_post", https="spc_post/prod"),
    NomadsDataset(category=Regional, name="SREF CONUS (40km)", freq="", grib_filter="sref", https="sref/prod"),
    NomadsDataset(category=Regional, name="SREF CONUS (40km) Bias-Corrected", freq="", grib_filter="srefbc", https="sref/prod"),
    NomadsDataset(category=Regional, name="SREF North America (32km)", freq="", grib_filter="sref_na", https="sref/prod"),
    NomadsDataset(category=Regional, name="SREF North America (16km)", freq="", grib_filter="sref_132", https="sref/prod"),
    NomadsDataset(category=Regional, name="URMA", freq="", grib_filter="", https="urma/prod"),
    # Climate Models
    NomadsDataset(category=Climate, name="Climate Forecast System Flux Products", freq="", grib_filter="cfs_flx", https="cfs/prod"),
    NomadsDataset(category=Climate, name="Climate Forecast System 3D Pressure Products", freq="", grib_filter="cfs_pgb", https="cfs/prod"),
    NomadsDataset(category=Climate, name="CORe", freq="", grib_filter="", https="core/prod"),
    NomadsDataset(category=Climate, name="Climatology Calibrated Precipitation Analysis", freq="", grib_filter="", https="ccpa/prod"),
    # Ocean/Lake/River Models
    NomadsDataset(category=Ocean, name="National Water Model", freq="", grib_filter="", https="nwm/prod"),
    NomadsDataset(category=Ocean, name="RTOFS Atlantic", freq="", grib_filter="", https="rtofs/prod"),
    NomadsDataset(category=Ocean, name="RTOFS Global", freq="", grib_filter="", https="rtofs/prod"),
    NomadsDataset(category=Ocean, name="Sea Ice Analysis", freq="", grib_filter="seaice", https="seaice_analysis/prod"),
    NomadsDataset(category=Ocean, name="Sea Ice Drift", freq="", grib_filter="", https="seaice_drift/prod"),
    NomadsDataset(category=Ocean, name="Great Lakes Wave Unstructured (GLWU)", freq="", grib_filter="glwu", https="glwu/prod"),
    NomadsDataset(category=Ocean, name="GFS Wave", freq="", grib_filter="gfswave", https="gfs/prod"),
    NomadsDataset(category=Ocean, name="GFS Ensemble Wave", freq="", grib_filter="gefs_wave_0p25", https="gens/prod"),
    NomadsDataset(category=Ocean, name="NCEP and FNMOC Combined Ensemble Wave", freq="", grib_filter="nfcens", https="wave_nfcens/prod"),
    NomadsDataset(category=Ocean, name="P-Surge", freq="", grib_filter="", https="psurge/prod"),
    NomadsDataset(category=Ocean, name="STOFS 2D Global", freq="", grib_filter="stofs_2d_glo", https="stofs/prod"),
    NomadsDataset(category=Ocean, name="STOFS 3D Atlantic", freq="", grib_filter="stofs_3d_atl", https="stofs/prod"),
    NomadsDataset(category=Ocean, name="ETSS (Extra-Tropical Storm Surge)", freq="", grib_filter="", https="petss/prod"),
    NomadsDataset(category=Ocean, name="P-ETSS (Probabilistic ETSS)", freq="", grib_filter="", https="petss/prod"),
    NomadsDataset(category=Ocean, name="National Operational Coastal Modeling Program", freq="", grib_filter="", https="nosofs/prod"),
    NomadsDataset(category=Ocean, name="NWPS Alaska Region", freq="", grib_filter="arnwps", https="nwps/prod"),
    NomadsDataset(category=Ocean, name="NWPS Eastern Region", freq="", grib_filter="ernwps", https="nwps/prod"),
    NomadsDataset(category=Ocean, name="NWPS Pacific Region", freq="", grib_filter="prnwps", https="nwps/prod"),
    NomadsDataset(category=Ocean, name="NWPS Southern Region", freq="", grib_filter="srnwps", https="nwps/prod"),
    NomadsDataset(category=Ocean, name="NWPS Western Region", freq="", grib_filter="wrnwps", https="nwps/prod"),
    NomadsDataset(category=Ocean, name="NSST (Near Sea Surface Temperatures)", freq="", grib_filter="", https="nsst/prod"),
    # Space Weather Models
    NomadsDataset(category=SpaceWeather, name="WSA-Enlil", freq="", grib_filter="", https="wsa_enlil/prod"),
    NomadsDataset(category=SpaceWeather, name="SWMF-Geospace", freq="", grib_filter="", https="swmf/prod"),
    NomadsDataset(category=SpaceWeather, name="WFS (WAM-IPE Forecast System)", freq="", grib_filter="", https="wfs/prod"),
    # External Models
    NomadsDataset(category=External, name="CMC Ensemble", freq="", grib_filter="cmcens", https="naefs/prod"),
    NomadsDataset(category=External, name="FNMOC Ensemble and Bias Corrected", freq="", grib_filter="fens", https="naefs/prod"),
    NomadsDataset(category=External, name="NAVGEM", freq="", grib_filter="", https="fnmoc/prod"),
    NomadsDataset(category=External, name="NCOM", freq="", grib_filter="", https="ncom/prod"),
    NomadsDataset(category=External, name="HYCOM", freq="", grib_filter="", https="navo/prod"),
    NomadsDataset(category=External, name="557ww Ensemble", freq="", grib_filter="557ww", https="557ww/prod"),
]

#------------------------------------------------------------------------------# Popular Datasets
const GFS_025 = _NOMADS_DATASETS[findfirst(d -> d.grib_filter == "gfs_0p25", _NOMADS_DATASETS)]
const GFS_025_HOURLY = _NOMADS_DATASETS[findfirst(d -> d.grib_filter == "gfs_0p25_1hr", _NOMADS_DATASETS)]
const GFS_050 = _NOMADS_DATASETS[findfirst(d -> d.grib_filter == "gfs_0p50", _NOMADS_DATASETS)]
const GFS_100 = _NOMADS_DATASETS[findfirst(d -> d.grib_filter == "gfs_1p00", _NOMADS_DATASETS)]
const HRRR_CONUS = _NOMADS_DATASETS[findfirst(d -> d.grib_filter == "hrrr_2d", _NOMADS_DATASETS)]
const HRRR_CONUS_SUB = _NOMADS_DATASETS[findfirst(d -> d.grib_filter == "hrrr_sub", _NOMADS_DATASETS)]
const HRRR_AK = _NOMADS_DATASETS[findfirst(d -> d.grib_filter == "hrrrak_2d", _NOMADS_DATASETS)]
const NAM_CONUS = _NOMADS_DATASETS[findfirst(d -> d.grib_filter == "nam", _NOMADS_DATASETS)]
const RAP = _NOMADS_DATASETS[findfirst(d -> d.grib_filter == "rap", _NOMADS_DATASETS)]

#------------------------------------------------------------------------------# datasets
function datasets(::NOMADS; category=nothing, name=nothing, freq=nothing)
    filter(d -> (category === nothing || d.category == category) &&
           (name === nothing || occursin(name, d.name)) &&
           (freq === nothing || occursin(freq, d.freq)), _NOMADS_DATASETS)
end
