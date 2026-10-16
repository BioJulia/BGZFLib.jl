const IndexBlock = @NamedTuple{compressed_offset::UInt64, decompressed_offset::UInt64}

"""
    GZIndex(blocks::Vector{@NamedTuple{compressed_offset::UInt64, decompressed_offset::UInt64}})

Construct a GZI index of a BGZF file. The vector `blocks` contains pairs of zero-based
offsets of a BGZF block in the compressed stream, and of its content in the decompressed
stream, respectively, in ascending order.

Like htslib's GZI indices, the first element is always `(0, 0)`, and the remaining elements
correspond to each non-empty block after the first non-empty block. Empty blocks are not
indexed. An offset in the decompressed stream therefore maps to the indexed block with the
largest decompressed offset not larger than it, see [`get_virtual_offset`](@ref).

Throw an `ArgumentError` if `blocks` is empty.
Throw a `BGZFError(nothing, BGZFErrors.invalid_index)` if the first element is not `(0, 0)`,
if either of the offsets are not sorted in ascending order, if a compressed offset is
≥ 2^48, or if two consecutive decompressed offsets differ by more than 2^16.

Usually constructed with [`index_bgzf`](@ref), or [`load_gzi`](@ref)
and serialized with `write(io, ::GZIndex)`.

This struct contains the public property `.blocks` which corresponds to the vector
as described above, no matter how `GZIndex` is constructed.

See also: [`index_bgzf`](@ref), [`load_gzi`](@ref), [`write_gzi`](@ref)
"""
struct GZIndex
    blocks::Vector{IndexBlock}

    function GZIndex(v::Vector{IndexBlock})
        isempty(v) && throw(ArgumentError("GZIndex must contain at least one block"))
        if !validate_blocks(ImmutableMemoryView(v))
            throw(BGZFError(nothing, BGZFErrors.invalid_index))
        end
        return new(v)
    end

    global function new_index_bgzf(v::Vector{IndexBlock})
        return new(v)
    end
end

Base.write(io::AbstractBufWriter, index::GZIndex) = write_gzi(io, index)
Base.write(io::IO, index::GZIndex) = write_gzi(io, index)

"""
    write_gzi(io::Union{AbstractBufWriter, IO}, index::GZIndex)::Int

Write a `GZIndex` to `io` in GZI format, and return the number of written bytes.

Like htslib, the first block at offsets `(0, 0)` is implicit and is not written to
the GZI file.

The resulting file can be loaded with [`load_gzi`](@ref) and obtain
an index equivalent to `index`.

See also: [`GZIndex`](@ref), [`index_bgzf`](@ref)    

# Examples
```jldoctest
julia> gzi = load_gzi(CursorReader(gzi_data))::GZIndex;

julia> io = VecWriter();

julia> write_gzi(io, gzi)
88

julia> gzi_2 = load_gzi(CursorReader(io.vec));

julia> gzi.blocks == gzi_2.blocks
true
```
"""
function write_gzi(io::Union{AbstractBufWriter, IO}, index::GZIndex)
    blocks = index.blocks
    # The first block is always at (0, 0) and is implicit in GZI files
    n_written = length(blocks) - 1
    write(io, htol(n_written % UInt64))
    if ENDIAN_BOM == 0x04030201
        # On little-endian CPUs, the memory layout of `blocks` is the GZI format
        if !iszero(n_written)
            GC.@preserve blocks begin
                p = Ptr{UInt8}(pointer(blocks, 2))
                unsafe_write(io, p, (16 * n_written) % UInt)
            end
        end
    else
        for i in 2:lastindex(blocks)
            (; compressed_offset, decompressed_offset) = blocks[i]
            write(io, htol(compressed_offset), htol(decompressed_offset))
        end
    end
    return 8 + 16 * n_written
end

function get_buffer_with_length(io::AbstractBufReader, len::Int)::Union{Nothing, ImmutableMemoryView{UInt8}}
    buffer = get_buffer(io)
    while length(buffer) < len
        filled = fill_buffer(io)
        if isnothing(filled) || iszero(filled)
            return nothing
        end
        buffer = get_buffer(io)
    end
    return buffer
end

function validate_blocks(blocks::ImmutableMemoryView{IndexBlock})
    isempty(blocks) && return false
    fst = @inbounds blocks[1]
    (co, dco) = (fst.compressed_offset, fst.decompressed_offset)
    # Offset of first blocks are always zero
    co == dco == 0 || return false
    # We don't return early because we want this function to SIMD,
    # and we expect that almost all GZIndices are sorted, so returning
    # early would inhibit SIMD for little gain.
    good = true
    for i in 2:lastindex(blocks)
        (; compressed_offset, decompressed_offset) = @inbounds blocks[i]
        good &= (co ≤ compressed_offset) & (dco ≤ decompressed_offset)
        good &= compressed_offset < UInt64(2^48)
        good &= (decompressed_offset - dco) ≤ MAX_BLOCK_SIZE
        co = compressed_offset
        dco = decompressed_offset
    end
    return good
end

"""
    load_gzi(io::Union{IO, AbstractBufReader})::GZIndex

Load a `GZIndex` from a GZI file.

GZI files, as written by htslib, do not store the first block at offsets `(0, 0)`.
This block is added to the resulting `GZIndex`. For compatibility with GZI files
written by older versions of BGZFLib, which did store it, it is not added again if
the first block in the file is `(0, 0)`.

Throw an `IOError(IOErrorKinds.EOF)` if `io` does not contain enough bytes for a valid
GZI file. Throw a `BGZFError(nothing, BGZFErrors.invalid_index)` if the offsets are not
sorted in ascending order.
Currently does not throw an error if the file contains extra appended bytes, but this may
change in the future.

See also: [`index_bgzf`](@ref), [`GZIndex`](@ref), [`write_gzi`](@ref)

# Examples
```jldoctest
julia> gzi = open(load_gzi, path_to_gzi);

julia> gzi isa GZIndex
true

julia> (; compressed_offset) = gzi.blocks[5]
(compressed_offset = 0x00000000000000df, decompressed_offset = 0x0000000000000025)

julia> reader = SyncBGZFReader(CursorReader(bgzf_data));

julia> seek(reader, VirtualOffset(compressed_offset, 0));

julia> read(reader, 15) |> String
"more content he"

julia> close(reader)
```
"""
load_gzi(io::IO) = load_gzi(BufReader(io))

function load_gzi(io::AbstractBufReader)
    # Load the length as a UInt64
    buffer = get_buffer_with_length(io, 8)
    buffer === nothing && throw(IOError(IOErrorKinds.EOF))
    len = unsafe_bitload(UInt64, buffer, 1)
    @inbounds consume(io, 8)
    # No way the file is 1 PiB in size, so this is reasonable
    len > 2^48 && throw(IOError(IOErrorKinds.EOF))
    len = len % Int
    # The first block at (0, 0) is implicit in GZI files
    blocks = Vector{IndexBlock}(undef, len + 1)
    blocks[1] = (; compressed_offset = UInt64(0), decompressed_offset = UInt64(0))
    total_bytes = 16 * len
    # Julia guarantees the memory layout of bitstypes so this will work.
    GC.@preserve blocks begin
        n_read = unsafe_read(io, Ptr{UInt8}(pointer(blocks, 2)), total_bytes % UInt)
    end
    n_read == total_bytes || throw(IOError(IOErrorKinds.EOF))
    for i in 2:lastindex(blocks)
        (; compressed_offset, decompressed_offset) = blocks[i]
        blocks[i] = (; compressed_offset = ltoh(compressed_offset), decompressed_offset = ltoh(decompressed_offset))
    end
    if len > 0 && blocks[2] == blocks[1]
        popfirst!(blocks)
    end
    return GZIndex(blocks)
end

"""
    index_bgzf(io::Union{IO, AbstractBufReader})::GZIndex

Compute a `GZIndex` from a BGZF file.

Throw a `BGZFError` if the BGZF file is invalid,
or a `BGZFError` with `BGZFErrors.insufficient_reader_space` if
an entire block cannot be buffered by `io`, (only happens if `io::AbstractBufReader`).

The resulting index is identical to the one created by htslib's `bgzip --reindex`.

Indexing the file does not attempt to decompress it, and therefore does not
validate that the compressed data is valid (i.e. is a valid DEFLATE payload, or
that the crc32 checksum matches).

See also: [`load_gzi`](@ref), [`GZIndex`](@ref), [`write_gzi`](@ref)

# Examples
```
julia> idx1 = open(index_bgzf, path_to_bgzf);

julia> idx2 = open(load_gzi, path_to_gzi);

julia> idx1.blocks == idx2.blocks
true
```
"""
index_bgzf(io::IO) = index_bgzf(BufReader(io))

function index_bgzf(io::AbstractBufReader)
    decompressed_offset = compressed_offset = UInt64(0)
    # Like htslib, the first block is always (0, 0), even if the file begins with
    # empty blocks, and empty blocks are not indexed.
    blocks = [(; compressed_offset, decompressed_offset)]
    seen_nonempty = false
    gzip_fields = GzipExtraField[]
    while true
        buffer = get_reader_source_room(io)
        isnothing(buffer) && return new_index_bgzf(blocks)
        parsed = parse_bgzf_block!(gzip_fields, buffer)
        if parsed isa Union{BGZFErrorType, LibDeflateError}
            throw(BGZFError(compressed_offset, parsed))
        end
        (; block_size, decompressed_len) = parsed
        if !iszero(decompressed_len)
            seen_nonempty && push!(blocks, (; compressed_offset, decompressed_offset))
            seen_nonempty = true
        end
        compressed_offset += block_size
        decompressed_offset += decompressed_len
        @inbounds consume(io, block_size % Int)
    end
    return
end

"""
    get_virtual_offset(gzi::GZIndex, offset::Int)::Union{Nothing, VirtualOffset}

Get the `VirtualOffset` that corresponds to the zero-based offset `offset` in the
decompressed BGZF stream indexed by `gzi`.

Return `nothing` if `offset` is smaller than zero, or points more than 2^16 bytes
beyond the start of the final block.

Note that, because gzi files (and thus `GZIndex`) do not store the length of the
final block, the resulting `VirtualOffset` may be invalid.
Specifically, if the resulting `VirtualOffset` points `bo ≤`2^16` bytes into the final
block, but the final block is less than `bo` bytes, this function will return
a `VirtualOffset`, but using that offset to seek in the corresponding BGZF stream will error.

# Examples
```jldoctest
julia> gzi = load_gzi(CursorReader(gzi_data));

julia> get_virtual_offset(gzi, 100_000) === nothing
true

julia> vo = get_virtual_offset(gzi, 45)
VirtualOffset(223, 8)

julia> reader = seek(SyncBGZFReader(CursorReader(bgzf_data)), vo);

julia> read(reader) |> String
"tent herethis is another block"

julia> bad_vo = get_virtual_offset(gzi, 500)
VirtualOffset(271, 446)

julia> seek(reader, bad_vo);
ERROR: BGZFError: Error in block at offset 271: Seek to block offset larger than block size
[...]

julia> close(reader)
```
"""
function get_virtual_offset(gzi::GZIndex, offset::Int)::Union{Nothing, VirtualOffset}
    offset < 0 && return nothing
    target_block = (; compressed_offset = 0, decompressed_offset = offset)
    idx = searchsortedlast(gzi.blocks, target_block, by = i -> i.decompressed_offset)
    idx < 1 && return nothing
    block = gzi.blocks[idx]
    block_offset = offset - block.decompressed_offset
    block_offset >= 2^16 && return nothing
    return VirtualOffset(block.compressed_offset, block_offset)
end
