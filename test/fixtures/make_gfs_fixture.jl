# Regenerates the GFS test fixture: a few real GRIB2 messages per file, cut out of the
# public NOAA bucket by byte range, with `.idx` sidecars rewritten for the cut-down files.
#
#     julia --startup-file=no test/fixtures/make_gfs_fixture.jl [outdir]
#
# Needs network access.  Uses only stdlibs.

using Dates
using Downloads

# step (hours) => idx "PARAM:level" keys to keep (every matching line is kept, so both
# `APCP:surface` lines of f006 are included)
selection() = [
    0 => ["TMP:2 m above ground", "TMP:500 mb"],
    6 => ["TMP:2 m above ground", "TMP:500 mb", "TMP:850 mb", "APCP:surface"],
]

# path of a GFS file relative to the bucket root, always with `/` separators
function gfspath(t::DateTime, res::AbstractString, h::Integer)
    ymd = Dates.format(t, dateformat"yyyymmdd")
    hh = Dates.format(t, dateformat"HH")
    "gfs.$ymd/$hh/atmos/gfs.t$(hh)z.pgrb2.$res.f$(lpad(h, 3, '0'))"
end

# `range` is the value of an HTTP Range header without the `bytes=` prefix
function fetchbytes(url::AbstractString; range=nothing)
    io = IOBuffer()
    hdrs = isnothing(range) ? Pair{String, String}[] : ["Range" => "bytes=$range"]
    Downloads.download(url, io; headers=hdrs)
    take!(io)
end

# idx lines are "n:offset:d=YYYYMMDDHH:PARAM:level:forecast:"; `rest` is the text after
# "n:offset:" and `key` is "PARAM:level"
function idxlines(text::AbstractString)
    ls = filter(!isempty, map(strip, split(text, '\n')))
    map(ls) do l
        f = split(l, ':')
        rest = join(f[3:end], ':')
        (; offset=parse(Int, f[2]), key=f[4] * ":" * f[5], rest)
    end
end

# zero-based inclusive byte range of the message starting at offset `a`: it runs to the
# next strictly larger offset - 1, or to the end of the file
function byterange(ls, a::Integer)
    nxt = filter(>(a), map(l -> l.offset, ls))
    isempty(nxt) ? "$a-" : "$a-$(minimum(nxt) - 1)"
end

function makefile(outdir::AbstractString, url::AbstractString, rel::AbstractString, keys)
    ls = idxlines(String(fetchbytes(url * ".idx")))
    keep = filter(l -> l.key ∈ keys, ls)
    isempty(keep) && error("no idx lines matched in $url.idx")
    msgs = map(l -> fetchbytes(url; range=byterange(ls, l.offset)), keep)
    offs = cumsum(vcat(0, map(length, msgs)))
    path = joinpath(outdir, split(rel, '/')...)
    mkpath(dirname(path))
    write(path, reduce(vcat, msgs))
    open(path * ".idx", "w") do io
        foreach(n -> println(io, n, ":", offs[n], ":", keep[n].rest), eachindex(keep))
    end
    @info "wrote $path" messages=length(keep) bytes=filesize(path)
    path
end

function parseargs(args)
    length(args) ≤ 1 || error("usage: make_gfs_fixture.jl [outdir]")
    (; outdir=isempty(args) ? joinpath(@__DIR__, "gfs") : only(args))
end

function (@main)(args)
    o = parseargs(args)
    base = "https://noaa-gfs-bdp-pds.s3.amazonaws.com"
    t = DateTime(2026, 11, 8, 0)
    foreach(selection()) do (h, keys)
        rel = gfspath(t, "1p00", h)
        makefile(o.outdir, "$base/$rel", rel, keys)
    end
    0
end
