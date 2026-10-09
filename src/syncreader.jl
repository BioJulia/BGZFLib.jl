"""
    SyncBGZFReader(io::T <: IO; check_truncated::Bool=true)::SyncBGZFReader{BufReader{T}}
    SyncBGZFReader(io::T <: AbstractBufReader; check_truncated::Bool=true)::SyncBGZFReader{T}

Create a `SyncBGZFReader <: AbstractBufReader` that decompresses BGZF files.

When constructing from an `io::AbstractBufReader`, `io` must have a buffer size of at least
$(MAX_BLOCK_SIZE), or be able to grow its buffer to this size.

If `check_truncated`, the last BGZF block in the file must be empty, otherwise the reader
throws an error. This can be used to detect the file was truncated.

Unlike `BGZFReader`, the decompression happens serially in the main task.
This is slower and does not enable parallelism, but may be preferable in situations
where task scheduling or contention is an issue.

If the reader encounters an error, it goes into an error state and throws an exception.
The reader can be reset by using `seek` or `seekstart`. A closed reader cannot be reset.
"""
mutable struct SyncBGZFReader{T <: AbstractBufReader} <: AbstractBufReader
    const io::T
    const gzip_extra_fields::Vector{GzipExtraField}
    const buffer::Memory{UInt8}
    decompressor::Union{Nothing, Decompressor} # nothing when closed
    start::Int
    stop::Int
    n_bytes_read::Int
    current_block_offset::Int
    const check_truncated::Bool
    last_was_empty::Bool
    state::UInt8
end

function SyncBGZFReader(io::AbstractBufReader; check_truncated::Bool = true)
    # Ensure reader can buffer a full block
    get_reader_source_room(io)
    return SyncBGZFReader{typeof(io)}(
        io,
        GzipExtraField[],
        Memory{UInt8}(undef, MAX_BLOCK_SIZE),
        Decompressor(),
        1,
        0,
        0,
        0,
        check_truncated,
        false,
        STATE_OPEN,
    )
end

function SyncBGZFReader(io::IO; check_truncated::Bool = true)
    bufio = BufReader(io, BUFREADER_BUFFER_SIZE)
    return SyncBGZFReader(bufio; check_truncated)
end

function SyncBGZFReader(f, io::Union{AbstractBufReader, IO}; kwargs...)
    reader = SyncBGZFReader(io; kwargs...)
    return try
        f(reader)
    finally
        close(reader)
    end
end

function Base.show(io::IO, reader::SyncBGZFReader)
    summary(io, reader)
    print(io, '(')
    show(io, reader.io)
    return print(io, ')')
end

BufferIO.get_buffer(io::SyncBGZFReader) = @inbounds ImmutableMemoryView(io.buffer)[io.start:io.stop]

function BufferIO.consume(io::SyncBGZFReader, n::Int)
    @boundscheck if (n % UInt) > (io.stop - io.start + 1) % UInt
        throw(IOError(IOErrorKinds.ConsumeBufferError))
    end
    io.start += n
    return nothing
end

Base.isopen(io::SyncBGZFReader) = io.state != STATE_CLOSED

function throw_error(io::SyncBGZFReader, err::BGZFError)
    io.start = 1
    io.stop = 0
    io.state = STATE_ERROR
    throw(err)
end

function Base.close(io::SyncBGZFReader)
    io.state == STATE_CLOSED && return nothing
    io.start = 1
    io.stop = 0
    empty!(io.gzip_extra_fields)
    io.decompressor = nothing
    close(io.io)
    io.state = STATE_CLOSED
    return nothing
end

"""
    virtual_position(io::Union{SyncBGZFReader, BGZFReader})::VirtualOffset

Get the `VirtualOffset` of the current BGZF reader. The virtual offset is a
position in the decompressed stream. Seek to the position using `seek`.

See also: [`VirtualOffset`](@ref), [`seek`](@ref Base.seek(::SyncBGZFReader, ::VirtualOffset))

# Examples
```jldoctest
julia> reader = SyncBGZFReader(CursorReader(bgzf_data));

julia> virtual_position(reader)
VirtualOffset(0, 0)

julia> read(reader, 18);

julia> virtual_position(reader)
VirtualOffset(44, 5)

julia> close(reader)
```
"""
function virtual_position(io::SyncBGZFReader)
    return VirtualOffset(io.current_block_offset, io.start - 1)
end

"""
    seek(io::Union{SyncBGZFReader, BGZFReader}, vo::VirtualOffset) -> io

Seek to the virtual offset `vo`, i.e. `vo.block_offset` bytes into the decompressed
content of the BGZF block that starts at `vo.file_offset` in the compressed stream.
The virtual offset is usually obtained with [`virtual_position`](@ref)
or [`get_virtual_offset`](@ref).

Seeking reads and decompresses the block at `vo.file_offset`. If that fails, e.g. because
`vo.file_offset` is not the start of a BGZF block, the reader enters an error state and
throws a `BGZFError`. As an optimization, a `SyncBGZFReader` does not reread the block if
it is the block currently loaded.
If `vo.block_offset` is larger than the decompressed size of the block, the reader enters
an error state and throws a `BGZFError` with `BGZFErrors.block_offset_out_of_bounds`.
Seeking resets a reader in an error state.

The underlying IO must support `seek`. If seeking the underlying IO throws, the reader
is left unchanged.

`seekstart(io)` is equivalent to `seek(io, VirtualOffset(0, 0))`.

# Edge cases
* If the block at `vo.file_offset` is empty, the reader skips to the next non-empty
  block, and `vo.block_offset` applies to that block, like in htslib.
  This can happen with offsets obtained from a `GZIndex`, since GZI files do not index
  empty blocks. After seeking, `virtual_position` reports the position in the non-empty
  block, not `vo`.
* If the reader checks for truncation, seeking to the end of the compressed stream
  throws a `BGZFError` with `BGZFErrors.truncated_file`, since the reader cannot know
  whether the stream ends with an empty block. Instead, seek to the start of the final
  empty block. This is the position returned by `virtual_position` at EOF.

See also: [`VirtualOffset`](@ref), [`virtual_position`](@ref)

# Examples
```jldoctest
julia> reader = SyncBGZFReader(CursorReader(bgzf_data));

julia> seek(reader, VirtualOffset(178, 14));

julia> String(read(reader))
"more content herethis is another block"

julia> seek(reader, VirtualOffset(0, 0));

julia> String(read(reader, 13))
"Hello, world!"

julia> seek(reader, VirtualOffset(45, 0)); # NB: Not start of BGZF block
ERROR: BGZFError: Error in block at offset 45: BGZF file ends without EOF marker block, or block is malformed by being too short
[...]

julia> close(reader)
```
"""
function Base.seek(io::SyncBGZFReader, vo::VirtualOffset)
    file_offset = vo.file_offset % Int
    # If the target block is the one currently loaded, there is no need to read and
    # decompress it again. A loaded block is never empty, since empty blocks are skipped,
    # so `io.stop > 0` means a block is loaded.
    is_loaded = io.state == STATE_OPEN && io.stop > 0 && io.current_block_offset == file_offset
    if !is_loaded
        seek_block(io, file_offset)
        # If the block at `file_offset` is empty, this skips to the next non-empty block,
        # and the block offset applies to that block, like in htslib.
        fill_buffer(io)
    end
    if io.stop < vo.block_offset
        throw_error(io, BGZFError(file_offset, BGZFErrors.block_offset_out_of_bounds))
    end
    io.start = vo.block_offset + 1
    return io
end

Base.seekstart(io::SyncBGZFReader) = seek(io, VirtualOffset(0, 0))

# Seek to the start of the block at zero-based offset `offset` in the compressed stream
function seek_block(io::SyncBGZFReader, offset::Int)
    io.state == STATE_CLOSED && throw(IOError(IOErrorKinds.ClosedIO))
    seek(io.io, offset)
    io.stop = 0
    io.start = 1
    io.last_was_empty = false
    io.n_bytes_read = offset
    io.current_block_offset = offset
    io.state = STATE_OPEN
    return io
end

function BufferIO.fill_buffer(io::SyncBGZFReader)
    io.state == STATE_CLOSED && return 0
    io.state == STATE_ERROR && throw(BGZFError(nothing, BGZFErrors.operation_on_error))

    io.stop >= io.start && return nothing
    io.start = 1
    io.stop = 0
    last_was_empty = io.check_truncated ? io.last_was_empty : nothing
    (; consumed, last_empty_offset, result) = get_reader_block_work(io.io, io.gzip_extra_fields, last_was_empty, io.n_bytes_read)
    io.n_bytes_read += consumed
    if result === nothing
        io.current_block_offset = eof_offset(io.current_block_offset, io.last_was_empty, io.n_bytes_read, last_empty_offset)
        io.last_was_empty = true
        return 0
    elseif result isa BGZFError
        throw_error(io, result)
    else
        io.last_was_empty = false
        (; payload, block_size, decompressed_len, expected_crc32) = result
        io.current_block_offset = io.n_bytes_read
        destination = io.buffer
        GC.@preserve payload destination begin
            libdeflate_return = unsafe_decompress!(
                something(io.decompressor),
                WriteableMemory(destination),
                ReadableMemory(pointer(payload), length(payload)),
                UInt(decompressed_len),
            )
        end
        if libdeflate_return isa LibDeflateError
            throw_error(io, BGZFError(io.n_bytes_read, libdeflate_return))
        else
            GC.@preserve destination begin
                crc32 = unsafe_crc32(ReadableMemory(pointer(destination), decompressed_len))
            end
            if crc32 != expected_crc32
                throw_error(io, BGZFError(io.n_bytes_read, LibDeflateErrors.gzip_bad_crc32))
            end
        end
        io.stop = decompressed_len
        consume(io.io, Int(block_size))
        io.n_bytes_read += block_size
        return decompressed_len % Int
    end
end
