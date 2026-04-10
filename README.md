# GeoFetch

Fetch geospatial data from multiple sources into a unified project directory.

## Concepts 

- A `Project` defines:
  - a spatio-temporal region of interest.
  - a working directory.
- A `Dataset` is a lazy representation of a remote dataset.
- A `Chunk` is a lazy representation of a specific download from a `Dataset`.

## Usage

```julia
using GeoFetch 


proj = Project()  # Default to entire globe, no temporal component
```

## Built-In Datasets

- `NOMADS`: NOAA National Operational Model Archive and Distribution System
- `CDS`: Copernicus Climate Data Store
