function bgzfread(v::VecWriter)
    return SyncBGZFReader(read, CursorReader(v.vec))
end

import BufferIO

@testset "Close twice" begin
    io = VecWriter()
    writer = BGZFWriter(io)
    write(writer, "abc")
    close(writer)
    n_bytes = length(io.vec)
    close(writer)
    @test length(io.vec) == n_bytes
    @test bgzfread(io) == b"abc"
end

@testset "No EOF block when function argument throws" begin
    for n_workers in [1, 4]
        test_no_eof_block_on_exception((f, io) -> BGZFWriter(f, io; n_workers))
    end
end

@testset "Write after close throws" begin
    writer = BGZFWriter(VecWriter())
    write(writer, "abc")
    close(writer)
    @test isempty(get_buffer(writer))
    @test_throws IOError write(writer, "hello")
    @test_throws IOError write(writer, 0x01)
end

@testset "Close with failing flush closes underlying" begin
    underlying = FailingFlushWriter()
    writer = BGZFWriter(underlying)
    write(writer, "abc")
    @test_throws ErrorException close(writer)
    @test !isopen(writer)
    @test underlying.closed
end

@testset "shallow_flush returns number of uncompressed bytes" begin
    for n_workers in [1, 4]
        io = VecWriter()
        writer = BGZFWriter(io; n_workers)
        write(writer, "a"^1000)
        @test shallow_flush(writer) == 1000
        @test shallow_flush(writer) == 0
        # More than fits in the writer's buffer, so some is shipped by `grow_buffer`
        # before the call to `shallow_flush`
        data = rand(UInt8, 300_000)
        write(writer, data)
        @test shallow_flush(writer) == 300_000 - 4 * BGZFLib.SAFE_DECOMPRESSED_SIZE
        close(writer)
        @test bgzfread(io) == vcat(codeunits("a"^1000), data)
    end
end

mutable struct TinyWriter <: BufferIO.AbstractBufWriter
    buffer::Memory{UInt8}
end

BufferIO.get_buffer(io::TinyWriter) = MemoryView(io.buffer)
BufferIO.grow_buffer(io::TinyWriter) = 0
Base.isopen(::TinyWriter) = true

@testset "Failing underlying write sets error state" begin
    underlying = LimitedWriter(100_000)
    writer = BGZFWriter(underlying; n_workers = 2)
    # Incompressible, so the compressed data does not fit in the underlying writer
    write(writer, rand(UInt8, 300_000))
    @test_throws IOError shallow_flush(writer)

    err = try
        shallow_flush(writer)
        nothing
    catch e
        e
    end
    @test err isa BGZFError
    @test err.type == BGZFErrors.operation_on_error
    @test_throws BGZFError write_empty_block(writer)
    @test isempty(get_buffer(writer))
    @test_throws BGZFError write(writer, 0x01)

    # Closing in the error state does not throw, and does not write more data
    n_bytes = length(underlying.inner.vec)
    close(writer)
    @test !isopen(writer)
    @test underlying.closed
    @test length(underlying.inner.vec) == n_bytes
end

@testset "Failing underlying write in function argument constructor" begin
    underlying = LimitedWriter(100_000)
    @test_throws IOError BGZFWriter(underlying; n_workers = 2) do writer
        write(writer, rand(UInt8, 300_000))
    end
    @test underlying.closed
end

@testset "From AbstractBufWriter" begin
    io = VecWriter()
    writer = BGZFWriter(io; n_workers = 2)
    @test writer isa BGZFWriter{VecWriter}
    @test write(writer, b"test data") == 9
    close(writer)

    @test String(bgzfread(io)) == "test data"
end

@testset "Fixed-size writer errors in constructor" begin
    io = TinyWriter(Memory{UInt8}(undef, 8))
    err = try
        BGZFWriter(io; n_workers = 1)
        nothing
    catch e
        e
    end
    @test err isa BGZFError
    @test err.type === BGZFLib.BGZFErrors.insufficient_writer_space
end

@testset "From IO" begin
    io = IOBuffer()
    writer = BGZFWriter(io; n_workers = 2)
    @test writer isa BGZFWriter{BufWriter{IOBuffer}}
    @test write(writer, b"test data") == 9
    flush(writer)
    seekstart(io)
    data = read(io)
    append!(data, BGZFLib.EOF_BLOCK)
    close(writer)

    reader = SyncBGZFReader(CursorReader(data))
    @test read(reader) == b"test data"
    close(reader)
end

@testset "Write and read back" begin
    @testset "Multiple writes" begin
        io = VecWriter()
        writer = BGZFWriter(io; n_workers = 2)
        write(writer, b"Hello, ")
        write(writer, b"world!")
        write(writer, b" More data.")
        close(writer)

        @test String(bgzfread(io)) == "Hello, world! More data."
    end

    @testset "Empty write" begin
        io = VecWriter()
        writer = BGZFWriter(io; n_workers = 2)
        close(writer)

        @test io.vec == BGZFLib.EOF_BLOCK
        @test String(bgzfread(io)) == ""
    end

    @testset "Large write" begin
        io = VecWriter()
        writer = BGZFWriter(io; n_workers = 4)
        data = repeat(b"0123456789", 10000)
        write(writer, data)
        close(writer)

        @test bgzfread(io) == data
    end
end

@testset "BGZFWriter - isopen and close" begin
    io = VecWriter()
    writer = BGZFWriter(io; n_workers = 2)

    @test isopen(writer)
    close(writer)
    @test !isopen(writer)
end

@testset "Single worker" begin
    io = VecWriter()
    writer = BGZFWriter(io; n_workers = 1)
    write(writer, b"single worker test")
    close(writer)

    @test String(bgzfread(io)) == "single worker test"
end

@testset "With append_empty=false" begin
    io = VecWriter()
    writer = BGZFWriter(io; n_workers = 2, append_empty = false)
    write(writer, b"test")
    close(writer)

    # Should error with check_truncated=true
    reader = SyncBGZFReader(CursorReader(io.vec); check_truncated = true)
    @test_throws BGZFError read(reader)
    close(reader)

    # Should work with check_truncated=false
    reader = SyncBGZFReader(CursorReader(io.vec); check_truncated = false)
    @test read(reader) == b"test"
    close(reader)
end

@testset "BGZFWriter - flush" begin
    @testset "Explicit flush" begin
        io = VecWriter()
        writer = BGZFWriter(io; n_workers = 2)

        write(writer, b"first part")
        flush(writer)
        write(writer, b" second part")
        close(writer)

        @test String(bgzfread(io)) == "first part second part"
    end

    @testset "Multiple flushes" begin
        io = VecWriter()
        writer = BGZFWriter(io; n_workers = 2)

        write(writer, b"one")
        flush(writer)
        write(writer, b"two")
        flush(writer)
        write(writer, b"three")
        close(writer)

        @test String(bgzfread(io)) == "onetwothree"
    end
end

@testset "BGZFWriter - write_empty_block" begin
    io = VecWriter()
    writer = BGZFWriter(io; n_workers = 2, append_empty = false)
    write(writer, b"before empty")
    write_empty_block(writer)
    close(writer)

    # The file should have an empty block and be readable with check_truncated=true
    reader = SyncBGZFReader(CursorReader(io.vec); check_truncated = true)
    @test read(reader) == b"before empty"
    close(reader)
end

@testset "BGZFWriter - function form" begin
    io = VecWriter()

    result = BGZFWriter(io; n_workers = 2) do writer
        write(writer, b"function form test")
    end

    @test result == 18
    @test String(bgzfread(io)) == "function form test"
end

@testset "Large write spanning multiple blocks" begin
    @testset "Single large write" begin
        io = VecWriter()
        writer = BGZFWriter(io; n_workers = 4)

        # Create data larger than SAFE_DECOMPRESSED_SIZE to span multiple blocks
        # SAFE_DECOMPRESSED_SIZE is 2^16 - 256 = 65280 bytes
        data = repeat(b"0123456789", 10000)  # 100000 bytes
        @test length(data) > 65280

        @test write(writer, data) == length(data)
        close(writer)

        reader = SyncBGZFReader(CursorReader(io.vec))
        @test read(reader) == data
        close(reader)
    end

    @testset "Multiple writes accumulating to large data" begin
        io = VecWriter()
        writer = BGZFWriter(io; n_workers = 2)

        chunk = repeat(b"abcdefghij", 1000)  # 10000 bytes per chunk
        total_written = 0

        for i in 1:10
            total_written += write(writer, chunk)
        end

        @test total_written == 100000
        close(writer)

        expected_data = repeat(chunk, 10)
        reader = SyncBGZFReader(CursorReader(io.vec))
        @test read(reader) == expected_data
        close(reader)
    end
end

@testset "take_inner" begin
    io = VecWriter()
    writer = BGZFWriter(io; n_workers = 2)
    write(writer, "Hello")
    @test take_inner(writer) === io
    @test !isopen(writer)
    @test isopen(io)
    @test_throws IOError write(writer, 0x01)

    # Includes the EOF block, so the output is not truncated
    @test SyncBGZFReader(r -> read(r, String), CursorReader(io.vec)) == "Hello"

    n_bytes = length(io.vec)
    close(writer)
    @test isopen(io)
    @test length(io.vec) == n_bytes

    @test_throws IOError take_inner(writer)
end

@testset "take_inner writes data larger than one buffer" begin
    io = VecWriter()
    writer = BGZFWriter(io; n_workers = 2)
    data = rand(UInt8, 1_000_000)
    write(writer, data)
    take_inner(writer)
    @test SyncBGZFReader(read, CursorReader(io.vec)) == data
end

@testset "take_inner respects append_empty" begin
    io = VecWriter()
    writer = BGZFWriter(io; n_workers = 2, append_empty = false)
    write(writer, "Hello")
    take_inner(writer)
    @test SyncBGZFReader(r -> read(r, String), CursorReader(io.vec); check_truncated = false) == "Hello"
    @test_throws BGZFError SyncBGZFReader(read, CursorReader(io.vec))
end

@testset "take_inner does not flush the inner IO" begin
    underlying = FailingFlushWriter()
    writer = BGZFWriter(underlying; n_workers = 2)
    @test take_inner(writer) === underlying
    @test !underlying.closed
end

@testset "take_inner preserves an IOBuffer" begin
    buffer = IOBuffer()
    writer = BGZFWriter(buffer; n_workers = 2)
    write(writer, "Hello")
    inner = take_inner(writer)
    @test inner isa BufWriter{IOBuffer}
    @test take_inner(inner) === buffer
    @test SyncBGZFReader(r -> read(r, String), CursorReader(take!(buffer))) == "Hello"
end

@testset "take_inner in error state throws and leaves writer closable" begin
    underlying = LimitedWriter(100_000)
    writer = BGZFWriter(underlying; n_workers = 2)
    write(writer, rand(UInt8, 300_000))
    # The first call fails in writing, the second call sees the error state
    @test_throws IOError take_inner(writer)
    @test_throws BGZFError take_inner(writer)
    @test isopen(writer)
    @test !underlying.closed
    close(writer)
    @test !isopen(writer)
    @test underlying.closed
end

@testset "take_inner with force in error state" begin
    underlying = LimitedWriter(100_000)
    writer = BGZFWriter(underlying; n_workers = 2)
    write(writer, rand(UInt8, 300_000))
    @test_throws IOError shallow_flush(writer)

    n_bytes = length(underlying.inner.vec)
    @test take_inner(writer; force = true) === underlying
    @test !isopen(writer)
    @test !underlying.closed
    @test length(underlying.inner.vec) == n_bytes

    # All workers stop, even though blocks may have been in flight
    foreach(wait, writer.workers)

    close(writer)
    @test !underlying.closed
    @test_throws IOError take_inner(writer; force = true)
end

@testset "take_inner with force discards data" begin
    io = VecWriter()
    writer = BGZFWriter(io; n_workers = 2)
    write(writer, "Hello")
    @test take_inner(writer; force = true) === io
    @test isempty(io.vec)
    foreach(wait, writer.workers)
end

@testset "take_inner with force returns the BufWriter" begin
    writer = BGZFWriter(IOBuffer(); n_workers = 2)
    inner = take_inner(writer; force = true)
    @test inner isa BufWriter{IOBuffer}
    @test isopen(inner)
    close(inner)
end
