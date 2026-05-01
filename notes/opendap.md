# OPeNDAP and NetCDF

Notes on how NetCDF files are laid out and how OPeNDAP lets you read arbitrary
slices of them over HTTP without downloading the whole file.

## NetCDF in one paragraph

A NetCDF file is a self-describing binary container for N-dimensional arrays
("variables") plus their coordinate axes ("dimensions") and metadata
("attributes"). The on-disk format comes in a few flavors:

- **NetCDF-3 "classic"** — a single flat binary file. Variables are stored
  either contiguously (fixed-size dims) or as record-major stripes (one
  unlimited dim). No compression, no chunking.
- **NetCDF-4** — HDF5 under the hood. Variables can be **chunked** (stored as
  a grid of rectangular blocks) and each chunk can be independently compressed
  (zlib, szip, zstd, etc.).
- **NetCDF Classic via netCDF-4** — classic data model, HDF5 container.

The key practical difference: NetCDF-3 is linear on disk, so reading "just a
corner" still requires a lot of seeks and can't be done efficiently over plain
HTTP range requests (the bytes for a lat/lon box are scattered across the
file). NetCDF-4 chunking helps, but HTTP range reads still require the client
to know the HDF5 b-tree layout. Neither format is friendly to "give me this
bounding box" over a naive HTTP GET.

This is why THREDDS ships OPeNDAP.

## OPeNDAP in one paragraph

OPeNDAP (Open-source Project for a Network Data Access Protocol) is a
server-side protocol that speaks the NetCDF data model over HTTP. The server
reads the file, the client asks for a subset using a URL query string, and
only the requested bytes are sent back — already unpacked from chunks,
decompressed, and laid out as a simple binary blob the client can splat
straight into an array.

The client doesn't need to know anything about how the file is stored on the
server. Chunked HDF5, classic NetCDF-3, aggregated multi-file datasets — the
protocol hides all of it.

## Anatomy of an OPeNDAP URL

THREDDS exposes the same dataset under several services. The service name is
the second path segment:

```
https://host/thredds/fileServer/path/to/file.nc    # whole-file HTTP download
https://host/thredds/dodsC/path/to/file.nc         # OPeNDAP
https://host/thredds/wcs/path/to/file.nc           # Web Coverage Service
https://host/thredds/wms/path/to/file.nc           # Web Map Service
```

`dodsC` is the OPeNDAP endpoint (the "C" is for "constrained"). Appending
suffixes to that base URL retrieves protocol documents:

| Suffix  | Returns                                                     |
| ------- | ----------------------------------------------------------- |
| `.dds`  | Dataset Descriptor Structure — variable names, types, shape |
| `.das`  | Dataset Attribute Structure — all attributes                |
| `.dmr`  | DAP4 metadata (newer, XML)                                  |
| `.dods` | Binary data response (DAP2)                                 |
| `.dap`  | Binary data response (DAP4)                                 |
| `.html` | Human-readable data request form                            |
| `.info` | Combined DDS + DAS in HTML                                  |

Visiting the `.html` form in a browser is the fastest way to sanity-check a
variable's name, shape, and dimension order before coding against it.

## Hyperslab syntax

The request itself is a **constraint expression** appended after `?`. The
syntax mirrors Fortran/C array slicing:

```
<var>[start:stride:stop]
```

All indices are **inclusive** and **zero-based**. Multiple variables are
comma-separated. Examples against an ETOPO-like `(lat, lon)` elevation grid:

```
.../file.nc.dods?z                           # whole variable
.../file.nc.dods?z[0:1:99][0:1:199]          # top-left 100x200 block
.../file.nc.dods?z[100:1:200][0:10:3600]     # middle rows, every 10th col
.../file.nc.dods?lat,lon                     # just the coordinate axes
.../file.nc.dods?z[0:99][0:199],lat[0:99],lon[0:199]  # slab + its coords
```

You ask in **index space, not coordinate space.** To request a lat/lon bbox
you first fetch `lat` and `lon` (they're small), find the index range that
covers your extent, then request `z` with those indices. That two-step — read
coords, compute indices, read slab — is the fundamental OPeNDAP access
pattern.

## What the client actually does

Julia's `NCDatasets.jl` (and Python's `netCDF4`, `xarray`, etc.) are built on
**netCDF-C**, which has a DAP client compiled in. When you open a `dodsC` URL:

```julia
ds = NCDataset("https://host/thredds/dodsC/.../file.nc")
z  = ds["z"][1000:2000, 500:1500]   # Julia 1-based, inclusive
```

the library:

1. Fetches `.dds` + `.das` once, on open, and builds an in-memory schema that
   looks exactly like a local NetCDF file.
2. On `getindex`, translates the Julia slice into a DAP2/DAP4 constraint
   expression and issues a single HTTP GET for `.dods` / `.dap`.
3. Parses the returned binary payload straight into the output array.

There is no temp file, no second format boundary, and no "download then open"
step. From the caller's perspective it *is* a NetCDF file; the network is
invisible until you look at wall-clock time.

Caveats worth knowing:

- **No random-access caching by default.** Every new slice is a new HTTP
  request. Reading in a tight loop over small windows is slow; reading one
  big slab is fast. Size your requests accordingly.
- **Server-side subset limits.** Many THREDDS deployments cap a single
  response at ~500 MB. Split very large requests into tiles and concatenate
  client-side.
- **DAP2 can't represent all NetCDF-4 types.** Groups, compound types, and
  strings-of-strings may fall back to DAP4 (`.dmr` / `.dap`) or fail. For
  ordinary gridded float/int arrays this never matters.
- **Axis order matches the file.** If the file stores `(time, lat, lon)`,
  your Julia slice is `ds["z"][t_idx, lat_idx, lon_idx]` — NCDatasets does
  not reorder axes for you.
- **Auth and cookies.** OPeNDAP URLs can be behind Earthdata Login or similar.
  netCDF-C honors `~/.netrc` and `~/.dodsrc` for credentials; set those up
  once rather than munging URLs.

## When to reach for OPeNDAP vs alternatives

- **Whole file, no subsetting needed** — use `fileServer` (plain HTTP).
  Simpler, cacheable by CDNs, no server CPU cost.
- **Bounding-box slice of a gridded variable** — OPeNDAP. Lowest overhead,
  transparent through NCDatasets.
- **Reprojection or format conversion as part of the fetch** — WCS. You pay
  for server-side GDAL machinery but get back a ready-to-use GeoTIFF.
- **Cloud-native object stores (S3/GCS)** — Zarr or COG, not OPeNDAP. THREDDS
  is a stateful server; cloud datasets are served as range-readable blobs
  with no server in the loop.

## Further reading

- OPeNDAP DAP2 spec: https://www.opendap.org/pdf/ESE-RFC-004v1.2.pdf
- DAP4 spec: https://docs.opendap.org/index.php/DAP4:_Specification_Volume_1
- THREDDS services reference: https://docs.unidata.ucar.edu/tds/current/userguide/services_ref.html
- NCDatasets.jl: https://alexander-barth.github.io/NCDatasets.jl/stable/
