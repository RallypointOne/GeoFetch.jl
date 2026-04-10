using GeoFetch
using GeoFetch: NOMADS, CDS
using Dates
using Extents: Extent

#--- NOMADS ---

# Browse available NOMADS datasets
NOMADS.DATASETS
NOMADS.datasets(name="GFS")

# A Dataset uses `All()` for parameters and levels by default (download everything).
gfs = NOMADS.GFS_025_HOURLY

# Get the documentation URL
help(gfs)

# Narrow the parameters and levels (Dataset is mutable for these fields)
gfs.parameters = ["TMP"]
gfs.levels = ["2_m_above_ground", "surface"]

# Create a Project with a spatial extent, time range, and datasets.
# The Project's extent becomes the GRIB filter subregion, and
# its datetimes determine which date directory to download from.
p = Project(
    geometry = Extent(X=(-90.0, -75.0), Y=(30.0, 42.0)),
    datetimes = (DateTime(2026, 4, 9), DateTime(2026, 4, 9)),
    datasets = [gfs],
)

# Preview what will be downloaded
chunks(p, gfs)

# `fetch` downloads all datasets, skipping files that already exist.
fetch(p)

# Running again is a no-op — existing files are skipped.
fetch(p)

#--- CDS ---

# Browse available CDS datasets
CDS.DATASETS
CDS.datasets(dataset_id="era5")

# Configure a CDS dataset
era5 = CDS.ERA5_SINGLE_LEVELS
era5.variables = ["2m_temperature", "10m_u_component_of_wind"]
era5.times = ["12:00"]

# Create a Project (CDS requires datetimes)
p2 = Project(
    geometry = Extent(X=(-10.0, 30.0), Y=(35.0, 70.0)),
    datetimes = (DateTime(2023, 1, 1), DateTime(2023, 1, 31)),
    datasets = [era5],
)

# Preview chunks (CDS splits by month)
chunks(p2, era5)

# Fetch (requires CDSAPI_KEY env var or ~/.cdsapirc)
# fetch(p2)
