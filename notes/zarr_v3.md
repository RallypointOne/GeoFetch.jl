# Zarr v3: A Detailed Primer

Zarr is a format for storing chunked, compressed, N-dimensional typed arrays. Version 3 (ZEP 1, accepted 2023) is a ground-up rework of the v2 format with the explicit goals of language-agnostic interoperability, a disciplined extension mechanism, better behavior on high-latency object stores, and support for sharding. This document summarizes the pieces of the spec most relevant to building a reader, writer, or interop layer.

## 1. Why v3 exists

v2 grew out of a NumPy-centric Python implementation. As Zarr spread to C, C++, Java, Julia, JavaScript, and Rust, three problems became acute:

- **Spec leaned on NumPy.** Dtype strings like `<f8` and structured dtypes assumed a specific library's conventions, making cross-language parity fragile.
- **No extension story.** Every new feature (compressors, filters, layouts) had to land in the core, so the community could not experiment without forking.
- **Storage cost.** One object per chunk works fine on a local disk but is ruinous on cloud object stores when arrays have millions of chunks — both for cost-per-request and for listing performance.

v3 addresses all three by (a) keeping the core small and strictly typed, (b) defining named *extension points* with a uniform `{name, configuration}` schema, and (c) introducing *sharding* so one storage object can hold many logical chunks.

## 2. The data model

A Zarr dataset is a tree of **nodes**. Each node is either:

- a **group** — an internal node that may contain children, or
- an **array** — a leaf node holding a uniform-dtype N-dimensional hyperrectangle of data.

The root is named `/`. Node names must not be empty, must not contain `/`, must not be solely `.` or `..`, and must not start with the reserved prefix `__`. Recommended character set: `[A-Za-z0-9._-]`.

Arrays are divided into **chunks** by a **chunk grid**. Each chunk is the unit of compression, I/O, and (often) parallelism. Chunks that have never been written are logically filled with the array's **fill value**; they may or may not exist as storage objects.

## 3. The store abstraction

Zarr v3 defines an abstract **store** interface. Any key-value store that provides these operations (with string keys and byte-string values) can host a Zarr hierarchy. This is what makes Zarr portable across local disks, S3/GCS/Azure, HTTP, in-memory dicts, and ZIP files.

Capabilities, composed à la carte:

- **Readable:** `get(key)`, `get_partial_values(key_ranges)` — the second one is what makes sharding and partial chunk reads efficient.
- **Writeable:** `set(key, value)`, `set_partial_values(...)`, `erase(key)`, `erase_prefix(prefix)`.
- **Listable:** `list()`, `list_prefix(prefix)`, `list_dir(prefix)` — the last returns only immediate children, which cloud prefix-listing APIs support natively.

A store need not implement every capability. A read-only HTTP store, for instance, implements only the readable operations.

**Storage transformers** sit between the array layer and the physical store. They have the same interface as a store, can be chained, and are declared per-array in metadata. The canonical use case is sharding, but they are also the hook for future features like content-addressed chunks or versioning.

## 4. Metadata: `zarr.json`

v3 collapses v2's `.zarray` / `.zgroup` / `.zattrs` into a single file per node, named `zarr.json`. All metadata for a node (including attributes) lives there. Keys move from `/foo/bar/.zarray` to `/foo/bar/zarr.json`. Chunks of the array at `/foo/bar` live under the prefix `/foo/bar/c/…`, which cleanly separates metadata from data under one prefix — a win for cloud listing.

### 4.1 Group metadata

```json
{
  "zarr_format": 3,
  "node_type": "group",
  "attributes": { "description": "a container" }
}
```

`attributes` is optional and is free-form user JSON.

### 4.2 Array metadata

Required fields:

| Field | Meaning |
|---|---|
| `zarr_format` | integer `3` |
| `node_type` | string `"array"` |
| `shape` | array of non-negative integers (dimension lengths) |
| `data_type` | element type (extension point; see §5) |
| `chunk_grid` | how the array is split into chunks (extension point) |
| `chunk_key_encoding` | how chunk coordinates map to store keys |
| `fill_value` | value for uninitialized elements, JSON-encoded per dtype rules |
| `codecs` | ordered list of codecs (non-empty; must contain exactly one array→bytes codec) |

Optional fields: `attributes`, `dimension_names`, `storage_transformers`.

Canonical example:

```json
{
  "zarr_format": 3,
  "node_type": "array",
  "shape": [10000, 1000],
  "dimension_names": ["rows", "columns"],
  "data_type": "float64",
  "chunk_grid": {
    "name": "regular",
    "configuration": { "chunk_shape": [1000, 100] }
  },
  "chunk_key_encoding": {
    "name": "default",
    "configuration": { "separator": "/" }
  },
  "codecs": [
    { "name": "bytes", "configuration": { "endian": "little" } }
  ],
  "fill_value": "NaN",
  "attributes": { "foo": 42 }
}
```

## 5. Data types

The v3 *core* keeps the dtype set small and precisely specified, because this is where cross-language v2 fell apart.

Core dtypes:

- `bool` — 1 byte, 0/1
- signed ints: `int8`, `int16`, `int32`, `int64`
- unsigned ints: `uint8`, `uint16`, `uint32`, `uint64`
- floats: `float16`, `float32`, `float64`
- complex: `complex64`, `complex128` (pairs of IEEE floats)
- raw/opaque: `r<N>` where `N` is a multiple of 8 (e.g. `r8`, `r16`, `r128`) — fixed-size byte blobs with no further semantics

Strings, datetimes, variable-length types, and structured records are intentionally *not* in the core and are delivered by extensions.

### Fill-value encoding in JSON

JSON cannot represent all numeric values faithfully, so the spec dictates representations:

- booleans: JSON `true` / `false`
- integers: JSON numbers, within the dtype's range
- floats: JSON numbers, or the strings `"NaN"`, `"Infinity"`, `"-Infinity"`; hex-float strings (`"0x1.8p+1"`) are also permitted for exact bit patterns
- complex: two-element array `[real, imag]`, each encoded as a float above
- raw `r<N>`: an array of byte values (integers 0–255) of the correct length

## 6. Chunk grid and chunk-key encoding

### 6.1 Chunk grid

The only core grid is `regular`:

```json
"chunk_grid": { "name": "regular", "configuration": { "chunk_shape": [1000, 100] } }
```

`chunk_shape` must have one entry per dimension; each entry must be positive. The last chunk along a dimension may be smaller than `chunk_shape` if `shape` isn't an exact multiple.

### 6.2 Chunk-key encoding

Maps a chunk's integer coordinate tuple to the suffix used in the store key. Two core encodings:

- `default`: keys look like `c/0/1/2` (coordinates joined by `separator`, default `/`). A zero-dimensional array's sole chunk is keyed `c`.
- `v2`: keys look like `0.1.2` (v2-style, for easy interop with v2 readers that only differ in metadata).

Both accept `"configuration": { "separator": "/" }` or `"separator": "."`.

So the full store key for chunk `(1, 0)` of array `/foo/bar` under the default encoding is `foo/bar/c/1/0`.

## 7. Codec pipelines

A chunk is encoded through a pipeline with a strict structure:

1. zero or more **array→array** codecs (transform the logical array, e.g. transpose)
2. exactly one **array→bytes** codec (serialize to a byte string)
3. zero or more **bytes→bytes** codecs (e.g. compression, checksum)

Each codec is `{ "name": ..., "configuration": {...} }`. Core codecs Zarr implementations are expected to support:

- **`bytes`** (array→bytes) — plain buffer layout with an `endian` configuration (`"little"` or `"big"`). This is the default way to serialize fixed-size numeric arrays.
- **`transpose`** (array→array) — permute axes; config: `{"order": [...]}`.
- **`gzip`** (bytes→bytes) — config: `{"level": 0–9}`.
- **`blosc`** (bytes→bytes) — Blosc meta-compressor; config: `cname` (e.g. `zstd`, `lz4`), `clevel`, `shuffle`, `typesize`, `blocksize`.
- **`crc32c`** (bytes→bytes) — trailing checksum.
- **`zstd`** (bytes→bytes) — standalone Zstandard compression.
- **`sharding_indexed`** (array→bytes) — see §8.

Every codec advertises `encode`/`decode` and optionally `partial_decode` (enables reading a sub-region of a chunk without materializing the whole thing — particularly interesting when combined with sharding and `get_partial_values`).

## 8. Sharding

Sharding is the flagship v3 feature for cloud storage. The `sharding_indexed` codec packs many logical **inner chunks** into one physical storage object (a **shard**), with a small index appended to locate each inner chunk.

Configuration:

```json
{
  "name": "sharding_indexed",
  "configuration": {
    "chunk_shape": [128, 128],
    "codecs": [
      { "name": "bytes", "configuration": { "endian": "little" } },
      { "name": "zstd",  "configuration": { "level": 3 } }
    ],
    "index_codecs": [
      { "name": "bytes",  "configuration": { "endian": "little" } },
      { "name": "crc32c" }
    ],
    "index_location": "end"
  }
}
```

- `chunk_shape` is the inner-chunk shape within a shard. It must evenly divide the outer (array-level) chunk shape.
- `codecs` is the pipeline used for each inner chunk; must contain exactly one array→bytes codec.
- `index_codecs` is the pipeline for the shard index itself; also must contain exactly one array→bytes codec. `crc32c` is strongly recommended here.
- `index_location` is `"end"` (default) or `"start"`.

The shard index is a fixed-shape array of `(offset, nbytes)` pairs — one per inner-chunk slot — so a reader can do a single range read to fetch the index and then targeted range reads to pull only the inner chunks it needs. Empty inner-chunk slots are encoded with `offset = nbytes = 2^64 − 1`.

Sharding is why `get_partial_values` exists in the store interface: without it, sharding would be no better than monolithic chunks on object storage.

## 9. Extension mechanism

Every extension point uses the same shape:

```json
{ "name": "<lowercase-identifier>", "configuration": { ... }, "must_understand": false }
```

or the shorthand `"<name>"` when no configuration is needed.

- `name` matches `^[a-z][a-z0-9-_.]+$`. Dotted names (e.g. `numcodecs.adler32`) namespace community extensions.
- `must_understand` controls forward compatibility. When `true`, a reader that does not recognize the extension MUST fail loudly rather than silently skip it — this prevents silent data corruption. When `false` (the default for attributes-like extensions), an unknown extension can be ignored.

This rule is what lets the core stay small without the ecosystem forking: new dtypes, codecs, chunk grids, and storage transformers can all be defined as extensions and advertised in `zarr.json`.

## 10. Consolidated metadata (optional)

Listing every `zarr.json` in a large hierarchy on S3 is expensive. Some implementations write a single consolidated-metadata file at the root describing all nodes, so a reader can open the whole tree with one `GET`. This is a convention carried over from v2; it is not formally part of the core v3 spec but is widely used by xarray / zarr-python on the cloud.

## 11. Migration notes vs v2

- Metadata file name: `.zarray`/`.zgroup`/`.zattrs` → single `zarr.json`.
- `zarr_format`: `2` → `3`.
- Dtypes: v2 NumPy dtype strings → v3 explicit names (`"<f8"` → `"float64"`). No structured dtypes in v3 core.
- Chunk keys: `0.1.2` or `0/1/2` with config → explicit `chunk_key_encoding` extension with either `default` (prefixed under `c/`) or `v2` (no `c/` prefix, v2-compatible layout).
- Compressor + filters → unified `codecs` list with typed pipeline stages.
- Sharding: not available in v2; first-class in v3.
- Extensibility: ad hoc in v2 → uniform extension-point schema in v3.

## 12. Relevance to GeoFetch

For coupled atmosphere/ocean input data:

- Many upstream sources are already migrating to Zarr v3 on S3 (ERA5 analysis-ready stores, CMIP7 staging).
- Sharding matters when chunk counts run into the millions — typical for multi-decade 0.25° global reanalysis — because per-object request cost dominates otherwise.
- Partial reads (`get_partial_values` + `partial_decode`) are the mechanism that lets a downstream tool pull a single lat/lon/time window without materializing whole shards.
- The `bytes`/`zstd`/`sharding_indexed` codec combination is the de facto modern default; supporting that set covers most real-world v3 archives.

## Sources

- [ZEP 1 — Zarr v3 specification](https://zarr.dev/zeps/accepted/ZEP0001.html)
- [Zarr v3 core specification (zarr-specs repo)](https://github.com/zarr-developers/zarr-specs/blob/main/docs/v3/core/index.rst)
- [Sharding codec spec](https://zarr-specs.readthedocs.io/en/latest/v3/codecs/sharding-indexed/index.html)
- [Zarr-Python 3 release notes](https://zarr.dev/blog/zarr-python-3-release/)
