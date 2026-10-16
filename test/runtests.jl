using BGZFLib
using Test
using MemoryViews
using BufferIO: consume, fill_buffer, get_buffer, CursorReader, BufReader, IOError, VecWriter, BufWriter, shallow_flush

DIR = joinpath(dirname(dirname(pathof(BGZFLib))), "data")

# Test BGZF formatted files
gz1_data = open(read, joinpath(DIR, "1.gz"))
gzi_data = open(read, joinpath(DIR, "1.gzi"))

# Decompressed content of gz1, each block, in order
gz1_content = [
    b"Hello, world!",
    b"more data",
    b"",
    b"x",
    b"",
    b"then some more",
    b"more content here",
    b"this is another block",
] |> filter(!isempty)

import BufferIO

# Writer whose `flush` throws, used to test that closing a BGZF writer
# still closes the underlying IO when flushing fails.
mutable struct FailingFlushWriter <: BufferIO.AbstractBufWriter
    inner::VecWriter
    closed::Bool
end

FailingFlushWriter() = FailingFlushWriter(VecWriter(), false)
BufferIO.get_buffer(io::FailingFlushWriter) = get_buffer(io.inner)
BufferIO.grow_buffer(io::FailingFlushWriter) = BufferIO.grow_buffer(io.inner)
BufferIO.consume(io::FailingFlushWriter, n::Int) = consume(io.inner, n)
Base.flush(::FailingFlushWriter) = error("flush failed")
Base.close(io::FailingFlushWriter) = (io.closed = true; nothing)

# `make_reader(io; check_truncated)` constructs a BGZF reader
function test_virtual_position_eof(make_reader)
    eof_block = BGZFLib.EOF_BLOCK
    no_eof_block = gz1_data[1:(end - length(eof_block))]
    @assert gz1_data[(end - length(eof_block) + 1):end] == eof_block

    # (data, check_truncated, expected virtual position at EOF)
    cases = [
        (gz1_data, true, VirtualOffset(length(gz1_data) - length(eof_block), 0)),
        (vcat(gz1_data, eof_block), true, VirtualOffset(length(gz1_data), 0)),
        (no_eof_block, false, VirtualOffset(length(no_eof_block), 0)),
        (eof_block, true, VirtualOffset(0, 0)),
        (UInt8[], false, VirtualOffset(0, 0)),
    ]
    for (data, check_truncated, expected) in cases
        reader = make_reader(CursorReader(data); check_truncated)
        read(reader)
        @test virtual_position(reader) == expected
        @test eof(reader)
        @test virtual_position(reader) == expected

        seek(reader, expected)
        @test virtual_position(reader) == expected
        @test read(reader) == UInt8[]
        close(reader)
    end

    # Seek to the start of a block, then get the position before reading
    reader = make_reader(CursorReader(gz1_data); check_truncated = true)
    read(reader, 30)
    seek(reader, VirtualOffset(44, 0))
    @test virtual_position(reader) == VirtualOffset(44, 0)
    return close(reader)
end

# `make_reader(io)` constructs a BGZF reader
function test_seek_out_of_bounds(make_reader)
    reader = make_reader(CursorReader(gz1_data))
    err = try
        seek(reader, VirtualOffset(0, 100))
        nothing
    catch e
        e
    end
    @test err isa BGZFError
    @test err.type == BGZFErrors.block_offset_out_of_bounds
    @test isempty(get_buffer(reader))
    err = try
        read(reader)
        nothing
    catch e
        e
    end
    @test err isa BGZFError
    @test err.type == BGZFErrors.operation_on_error

    # Seeking resets the error state
    seek(reader, VirtualOffset(0, 7))
    @test read(reader, 6) == b"world!"

    # The block at offset 147 is empty, so like htslib, the block offset
    # applies to the next non-empty block at offset 178
    seek(reader, VirtualOffset(147, 5))
    @test virtual_position(reader) == VirtualOffset(178, 5)
    @test read(reader, 9) == b"some more"
    seek(reader, VirtualOffset(147, 0))
    @test read(reader, 14) == b"then some more"
    return close(reader)
end

# `make_reader(io)` constructs a BGZF reader
function test_seek_api(make_reader)
    reader = make_reader(CursorReader(gz1_data))
    @test_throws MethodError seek(reader, 44)

    read(reader, 3)
    seekstart(reader)
    @test virtual_position(reader) == VirtualOffset(0, 0)
    @test read(reader, 5) == b"Hello"

    # If seeking the underlying IO fails, the reader is unchanged
    @test_throws IOError seek(reader, VirtualOffset(length(gz1_data) + 1, 0))
    @test virtual_position(reader) == VirtualOffset(0, 5)
    @test read(reader, 8) == b", world!"

    # Seek to a position that is not the start of a block
    @test_throws BGZFError seek(reader, VirtualOffset(45, 0))
    @test_throws BGZFError read(reader)
    return close(reader)
end

# Data that is not BGZF, or a BGZF block that is cut short, and the expected error type.
# The SAM-like text was previously reported as truncated if shorter than the extra
# field length read from bytes 11-12, and as having bad magic bytes otherwise.
const SAM_TEXT = b"@HD\tVN:1.6\tSO:coordinate\n"
const NON_BGZF_CASES = [
    (b"x", BGZFLib.LibDeflateErrors.gzip_bad_magic_bytes),
    (b"\x1fx", BGZFLib.LibDeflateErrors.gzip_bad_magic_bytes),
    (SAM_TEXT, BGZFLib.LibDeflateErrors.gzip_bad_magic_bytes),
    (repeat(SAM_TEXT, 1000), BGZFLib.LibDeflateErrors.gzip_bad_magic_bytes),
    (UInt8[0x1f, 0x8b, 0x07, 0x04, 0x00], BGZFLib.LibDeflateErrors.not_deflate),
    # Plain gzip header: FEXTRA flag is not set
    (vcat(UInt8[0x1f, 0x8b, 0x08, 0x00], zeros(UInt8, 30)), BGZFErrors.missing_bc_field),
    (gz1_data[1:3], BGZFErrors.truncated_file),
    (gz1_data[1:20], BGZFErrors.truncated_file),
]

# `make_reader(f, io)` constructs a BGZF reader and calls `f` on it
function test_non_bgzf_data(make_reader)
    for (data, expected) in NON_BGZF_CASES
        err = try
            make_reader(CursorReader(data)) do reader
                read(reader)
            end
            nothing
        catch e
            e
        end
        @test err isa BGZFError
        @test err.type === expected
        @test err.file_offset == 0
    end
    return nothing
end

# `make_writer(f, io)` constructs a BGZF writer and calls `f` on it
function test_no_eof_block_on_exception(make_writer)
    io = VecWriter()
    @test_throws ErrorException make_writer(io) do writer
        write(writer, "abc")
        error("failure")
    end
    @test io.vec[(end - 27):end] != BGZFLib.EOF_BLOCK
    @test SyncBGZFReader(read, CursorReader(io.vec); check_truncated = false) == b"abc"
    @test_throws BGZFError SyncBGZFReader(read, CursorReader(io.vec); check_truncated = true)

    io = VecWriter()
    make_writer(writer -> write(writer, "abc"), io)
    @test io.vec[(end - 27):end] == BGZFLib.EOF_BLOCK
    return nothing
end

# Incompressible bytes from a linear congruential generator, using its high bits
function pseudorandom_bytes(n::Int, seed::Integer)
    state = UInt64(seed)
    v = Vector{UInt8}(undef, n)
    for i in 1:n
        state = state * 0x5851f42d4c957f2d + 0x14057b7ef767814f
        v[i] = (state >> 56) % UInt8
    end
    return v
end

# Make a BGZF file with one block per element in `blocks`, followed by an EOF block.
# Return the data, and the zero-based file offset of each block.
function make_bgzf(blocks)
    compressor = BGZFLib.Compressor(UInt8(1))
    dst = Memory{UInt8}(undef, BGZFLib.MAX_BLOCK_SIZE)
    data = UInt8[]
    offsets = Int[]
    for block in blocks
        push!(offsets, length(data))
        n = BGZFLib.compress_block!(MemoryView(dst), ImmutableMemoryView(block), compressor)
        append!(data, view(dst, 1:n))
    end
    append!(data, BGZFLib.EOF_BLOCK)
    return (data, offsets)
end

# Blocks near the maximal size, so the compressed blocks are also large
const BIG_BLOCKS = [pseudorandom_bytes(BGZFLib.SAFE_DECOMPRESSED_SIZE, i) for i in 1:40]
# Many small blocks, some of them empty
const SMALL_BLOCKS = [i % 7 == 0 ? UInt8[] : Vector{UInt8}(string(i)^(i % 13)) for i in 1:30000]
const MIXED_BLOCKS = [isodd(i) ? BIG_BLOCKS[cld(i, 2)] : SMALL_BLOCKS[i] for i in 1:79]

# A reader that gets at most 1000 more bytes each time its buffer is filled, like a slow pipe.
# This makes the BGZFReader read its input in small pieces.
mutable struct TrickleReader <: BufferIO.AbstractBufReader
    data::Vector{UInt8}
    n_consumed::Int
    n_buffered::Int
end

TrickleReader(data::Vector{UInt8}) = TrickleReader(data, 0, 0)
Base.close(::TrickleReader) = nothing

function BufferIO.get_buffer(io::TrickleReader)
    return ImmutableMemoryView(io.data)[(io.n_consumed + 1):(io.n_consumed + io.n_buffered)]
end

function BufferIO.fill_buffer(io::TrickleReader)
    n = min(1000, length(io.data) - io.n_consumed - io.n_buffered)
    io.n_buffered += n
    return n
end

function BufferIO.consume(io::TrickleReader, n::Int)
    n > io.n_buffered && throw(IOError(BufferIO.IOErrorKinds.ConsumeBufferError))
    io.n_consumed += n
    io.n_buffered -= n
    return nothing
end

function Base.seek(io::TrickleReader, offset::Int)
    offset in 0:length(io.data) || throw(IOError(BufferIO.IOErrorKinds.BadSeek))
    io.n_consumed = offset
    io.n_buffered = 0
    return io
end

function file_source(data::Vector{UInt8})::IOStream
    path = tempname()
    write(path, data)
    return open(path)
end

# Functions that make the input of a BGZF reader from BGZF data, covering different kinds
# of underlying IO
const READER_SOURCES = [CursorReader, IOBuffer, TrickleReader, file_source]

# Read `reader` one buffer at a time. Return the virtual position and content of each buffer,
# the virtual position at EOF, and the type and offset of the error that stopped reading.
function read_buffers(reader)
    buffers = Tuple{VirtualOffset, Vector{UInt8}}[]
    err = try
        while true
            # The buffer may already be filled, e.g. after seeking
            isempty(get_buffer(reader)) && iszero(fill_buffer(reader)) && break
            buffer = get_buffer(reader)
            push!(buffers, (virtual_position(reader), collect(buffer)))
            consume(reader, length(buffer))
        end
        nothing
    catch e
        e isa BGZFError || rethrow()
        (e.type, e.file_offset)
    end
    eof_position = err === nothing ? virtual_position(reader) : nothing
    close(reader)
    return (buffers, eof_position, err)
end

@testset "SyncReader" begin
    include("syncreader.jl")
end

@testset "SyncBGZFWriter" begin
    include("syncwriter.jl")
end

@testset "BGZFReader" begin
    include("reader.jl")
end

@testset "BGZFWriter" begin
    include("writer.jl")
end

@testset "GZIndex" begin
    include("index.jl")
end

@testset "is_data_error" begin
    E = BGZFErrors
    for type in instances(E.BGZFErrorType)
        expected = type in (E.truncated_file, E.missing_bc_field, E.invalid_index)
        @test is_data_error(BGZFError(nothing, type)) == expected
    end
    @test is_data_error(BGZFError(0, BGZFLib.LibDeflateErrors.gzip_bad_crc32))

    # Errors thrown when reading malformed data
    for (data, _) in NON_BGZF_CASES
        err = try
            BGZFReader(read, CursorReader(data))
            nothing
        catch e
            e
        end
        @test is_data_error(err)
    end

    # Seeking out of bounds is misuse, not malformed data
    reader = SyncBGZFReader(CursorReader(gz1_data))
    err = try
        seek(reader, VirtualOffset(0, 100))
        nothing
    catch e
        e
    end
    @test !is_data_error(err)
    close(reader)
end
