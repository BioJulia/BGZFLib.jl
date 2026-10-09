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
