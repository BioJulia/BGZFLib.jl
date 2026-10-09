@testset "From AbstractBufWriter" begin
    io = VecWriter()
    writer = SyncBGZFWriter(io)
    @test writer isa SyncBGZFWriter{VecWriter}
    @test write(writer, b"test data") == 9
    close(writer)

    reader = BGZFReader(CursorReader(io.vec))
    @test read(reader) == b"test data"
    close(reader)
end

@testset "From IO" begin
    io = IOBuffer()
    writer = SyncBGZFWriter(io)
    @test writer isa SyncBGZFWriter{BufWriter{IOBuffer}}
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
        writer = SyncBGZFWriter(io)
        write(writer, b"Hello, ")
        write(writer, b"world!")
        write(writer, b" More data.")
        close(writer)

        reader = SyncBGZFReader(CursorReader(io.vec))
        @test read(reader) == b"Hello, world! More data."
        close(reader)
    end

    @testset "Empty write" begin
        io = VecWriter()
        writer = SyncBGZFWriter(io)
        close(writer)

        @test io.vec == BGZFLib.EOF_BLOCK
        reader = SyncBGZFReader(CursorReader(io.vec))
        @test read(reader) == UInt8[]
        close(reader)
    end
end

@testset "Large write" begin
    io = VecWriter()
    writer = SyncBGZFWriter(io)

    # Create data larger than 16 KiB (65536 bytes)
    data = repeat(b"0123456789", 7000)  # 70000 bytes
    @test length(data) > 2^16

    @test write(writer, data) == length(data)
    close(writer)

    reader = SyncBGZFReader(CursorReader(io.vec))
    @test read(reader) == data
    close(reader)
end

@testset "Without empty block fails check_truncated" begin
    io = VecWriter()
    writer = SyncBGZFWriter(io; append_empty = false)
    write(writer, b"test data")
    close(writer)

    # Should fail with check_truncated=true
    reader = SyncBGZFReader(CursorReader(io.vec); check_truncated = true)
    @test_throws BGZFError read(reader)
    close(reader)

    # Should succeed with check_truncated=false
    reader = SyncBGZFReader(CursorReader(io.vec); check_truncated = false)
    @test read(reader) == b"test data"
    close(reader)
end

@testset "Manual write_empty_block passes check_truncated" begin
    io = VecWriter()
    writer = SyncBGZFWriter(io; append_empty = false)
    write(writer, b"test data")
    write_empty_block(writer)
    close(writer)

    # Should succeed with check_truncated=true now
    reader = SyncBGZFReader(CursorReader(io.vec); check_truncated = true)
    @test read(reader) == b"test data"
    close(reader)
end

@testset "Function argument constructor" begin
    io = VecWriter()

    result = SyncBGZFWriter(io; append_empty = true, compress_level = 6) do writer
        @test isopen(writer)
        @test write(writer, b"Hello, ") == 7
        @test write(writer, b"world!") == 6
    end

    # Verify the writer was properly closed
    reader = SyncBGZFReader(CursorReader(io.vec); check_truncated = true)
    @test read(reader) == b"Hello, world!"
    close(reader)
end

@testset "Close twice" begin
    io = VecWriter()
    writer = SyncBGZFWriter(io)
    write(writer, "abc")
    close(writer)
    @test !isopen(writer)
    n_bytes = length(io.vec)
    close(writer)
    @test length(io.vec) == n_bytes
end

@testset "No EOF block when function argument throws" begin
    test_no_eof_block_on_exception(SyncBGZFWriter)
end

@testset "Write after close throws" begin
    writer = SyncBGZFWriter(VecWriter())
    write(writer, "abc")
    close(writer)
    @test isempty(get_buffer(writer))
    @test isempty(BufferIO.get_unflushed(writer))
    @test_throws IOError write(writer, "hello")
    @test_throws IOError write(writer, 0x01)
end

@testset "Close inside function argument constructor" begin
    io = VecWriter()
    SyncBGZFWriter(io) do writer
        write(writer, "abc")
        close(writer)
    end
    @test SyncBGZFReader(read, CursorReader(io.vec)) == b"abc"
end

@testset "Close with failing flush closes underlying" begin
    underlying = FailingFlushWriter()
    writer = SyncBGZFWriter(underlying)
    write(writer, "abc")
    @test_throws ErrorException close(writer)
    @test !isopen(writer)
    @test underlying.closed
end

@testset "shallow_flush returns number of uncompressed bytes" begin
    writer = SyncBGZFWriter(VecWriter())
    write(writer, "a"^1000)
    @test shallow_flush(writer) == 1000
    @test shallow_flush(writer) == 0
    close(writer)
end

@testset "show" begin
    # We just test that showing doesn't error
    buf = IOBuffer()
    writer = SyncBGZFWriter(VecWriter())
    show(buf, writer)
    @test !isempty(take!(buf))
end
