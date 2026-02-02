const IndexBlock = @NamedTuple{compressed_offset::UInt64, decompressed_offset::UInt64}

# must be sorted, else BGZF error. EOFerror. must be little endian
"""
    GZIndex(blocks::Vector{@NamedTuple{compressed_offset::UInt64, decompressed_offset::UInt64}})

Construct a GZI index of a BGZF file. The vector `blocks` contains one pair of integers for
each block in the BGZF file, in order, containing the zero-based offset of the compressed
data and the corresponding decompressed data, respectively.

Throw a `BGZFError(nothing, BGZFErrors.unsorted_index)` if either of the offsets are not
sorted in ascending order.

Usually constructed with [`index_bgzf`](@ref), or [`load_gzi`](@ref)
and serialized with `write(io, ::GZIndex)`.

This struct contains the public property `.blocks` which corresponds to the vector
as described above, no matter how `GZIndex` is constructed.

See also: [`index_bgzf`](@ref), [`load_gzi`](@ref), [`write_gzi`](@ref)
"""
struct GZIndex
    blocks::Vector{IndexBlock}

    function GZIndex(v::Vector{IndexBlock})
        if !validate_blocks(ImmutableMemoryView(v))
            throw(BGZFError(nothing, BGZFErrors.unsorted_index))
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
Currently, this function only works on little-endian CPUs, and will
throw an `ErrorException` on big-endian platforms.

The resulting file can be loaded with [`load_gzi`](@ref) and obtain
an index equivalent to `index`.

See also: [`GZIndex`](@ref), [`index_bgzf`](@ref)    

# Examples
```jldoctest
julia> gzi = load_gzi(CursorReader(gzi_data))::GZIndex;

julia> io = VecWriter();

julia> write_gzi(io, gzi)
152

julia> gzi_2 = load_gzi(CursorReader(io.vec));

julia> gzi.blocks == gzi_2.blocks
true
```
"""
function write_gzi(io::Union{AbstractBufWriter, IO}, index::GZIndex)
    blocks = index.blocks
    write(io, htol(length(blocks) % UInt64))
    if htol(0x0102) != 0x0102
        error("This function assumes little-endian CPUs.")
    end
    GC.@preserve blocks begin
        p = Ptr{UInt8}(pointer(blocks))
        unsafe_write(io, p, sizeof(blocks) % UInt)
    end
    return 8 + 16 * length(blocks)
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
    isempty(blocks) && return true
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
        good &= (compressed_offset - co) ≤ MAX_BLOCK_SIZE
        good &= (decompressed_offset - dco) ≤ MAX_BLOCK_SIZE
        co = compressed_offset
        dco = decompressed_offset
    end
    return good
end

"""
    load_gzi(io::Union{IO, AbstractBufReader})::GZIndex

Load a `GZIndex` from a GZI file.

Throw an `IOError(IOErrorKinds.EOF)` if `io` does not contain enough bytes for a valid
GZI file. Throw a `BGZFError(nothing, BGZFErrors.unsorted_index)` if the offsets are not
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
(compressed_offset = 0x0000000000000093, decompressed_offset = 0x0000000000000017)

julia> reader = SyncBGZFReader(CursorReader(bgzf_data));

julia> seek(reader, Int(compressed_offset));

julia> read(reader, 15) |> String
"then some morem"

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
    blocks = Vector{IndexBlock}(undef, len)
    total_bytes = 16 * len
    # Julia guarantees the memory layout of bitstypes so this will work.
    GC.@preserve blocks begin
        n_read = unsafe_read(io, Ptr{UInt8}(pointer(blocks)), total_bytes % UInt)
    end
    n_read == total_bytes || throw(IOError(IOErrorKinds.EOF))
    return GZIndex(blocks)
end

"""
    index_bgzf(io::Union{IO, AbstractBufReader})::GZIndex

Compute a `GZIndex` from a BGZF file.

Throw a `BGZFError` if the BGZF file is invalid,
or a `BGZFError` with `BGZFErrors.insufficient_reader_space` if
an entire block cannot be buffered by `io`, (only happens if `io::AbstractBufReader`).

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
    blocks = IndexBlock[]
    gzip_fields = GzipExtraField[]
    while true
        buffer = get_reader_source_room(io)
        # Empty file is a valid BGZF file
        isnothing(buffer) && return new_index_bgzf(blocks)
        parsed = parse_bgzf_block!(gzip_fields, buffer)
        if parsed isa Union{BGZFErrorType, LibDeflateError}
            throw(BGZFError(compressed_offset, parsed))
        end
        (; block_size, decompressed_len) = parsed
        push!(blocks, (; compressed_offset, decompressed_offset))
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

julia> reader = virtual_seek(SyncBGZFReader(CursorReader(bgzf_data)), vo);

julia> read(reader) |> String
"tent herethis is another block"

julia> bad_vo = get_virtual_offset(gzi, 500)
VirtualOffset(323, 425)

julia> virtual_seek(reader, bad_vo);
ERROR: BGZFError: Error in block at offset 323: Seek to block offset larger than block size
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
    block_offset > 2^16 && return nothing
    return VirtualOffset(block.compressed_offset, block_offset)
end
