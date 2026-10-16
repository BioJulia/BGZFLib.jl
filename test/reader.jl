@testset "From AbstractBufReader" begin
    for n_workers in [1, 4]
        reader = BGZFReader(CursorReader(gz1_data); n_workers)
        @test reader isa BGZFReader{CursorReader}
        @test read(reader) == reduce(vcat, gz1_content)
        close(reader)
    end
end

@testset "From IO" begin
    for n_workers in [1, 4]
        reader = BGZFReader(IOBuffer(gz1_data); n_workers)
        @test reader isa BGZFReader{BufReader{IOBuffer}}
        @test read(reader) == reduce(vcat, gz1_content)
        close(reader)
    end
end

@testset "Read entire file" begin
    for n_workers in [1, 4]
        reader = BGZFReader(CursorReader(gz1_data); n_workers)
        all_data = read(reader)
        @test all_data == reduce(vcat, gz1_content)
        close(reader)
    end
end

@testset "Read specific amounts" begin
    for n_workers in [1, 4]
        reader = BGZFReader(CursorReader(gz1_data); n_workers)

        chunk1 = read(reader, 5)
        @test chunk1 == b"Hello"

        chunk2 = read(reader, 8)
        @test chunk2 == b", world!"

        chunk3 = read(reader, 10)
        @test chunk3 == b"more datax"

        close(reader)
    end
end

@testset "Read single byte" begin
    for n_workers in [1, 4]
        reader = BGZFReader(CursorReader(gz1_data); n_workers)

        @test read(reader, UInt8) == UInt8('H')
        @test read(reader, UInt8) == UInt8('e')
        @test read(reader, UInt8) == UInt8('l')

        close(reader)
    end
end

@testset "BGZFReader - eof" begin
    for n_workers in [1, 4]
        reader = BGZFReader(CursorReader(gz1_data); n_workers)

        @test !eof(reader)

        read(reader, 10)
        @test !eof(reader)

        read(reader)
        @test eof(reader)

        @test read(reader, 100) == UInt8[]
        @test read(reader) == UInt8[]

        close(reader)
        @test !isopen(reader)
    end
end

@testset "BGZFReader - eof with only empty blocks remaining" begin
    for n_workers in [1, 4]
        reader = BGZFReader(CursorReader(BGZFLib.EOF_BLOCK); n_workers)
        @test eof(reader)
        close(reader)

        data = vcat(BGZFLib.EOF_BLOCK, BGZFLib.EOF_BLOCK)
        reader = BGZFReader(CursorReader(data); n_workers)
        @test eof(reader)
        close(reader)
    end
end

@testset "Seeking" begin
    @testset "seekstart" begin
        for n_workers in [1, 4]
            reader = BGZFReader(CursorReader(gz1_data); n_workers)
            read(reader, 20)
            seekstart(reader)
            @test read(reader, 5) == b"Hello"

            seek(reader, VirtualOffset(0, 0))
            @test read(reader, 13) == b"Hello, world!"
            close(reader)
        end
    end
end

@testset "BGZFReader - virtual_position and seek" begin
    for n_workers in [1, 4]
        reader = BGZFReader(CursorReader(gz1_data); n_workers)

        @testset "Initial virtual position" begin
            vo = virtual_position(reader)
            @test vo.file_offset == 0
            @test vo.block_offset == 0
        end

        @testset "Virtual position after reading" begin
            read(reader, 5)
            vo = virtual_position(reader)
            @test vo.file_offset == 0
            @test vo.block_offset == 5

            read(reader, 8)
            vo = virtual_position(reader)
            @test vo.file_offset == 0
            @test vo.block_offset == 13
        end

        @testset "Virtual position across blocks" begin
            seekstart(reader)
            read(reader, 13)
            vo1 = virtual_position(reader)

            read(reader, 1)
            vo2 = virtual_position(reader)
            @test vo2.file_offset > vo1.file_offset
            @test vo2.block_offset == 1
        end

        @testset "Virtual seek to saved position" begin
            seekstart(reader)
            read(reader, 7)
            saved_vo = virtual_position(reader)

            read(reader, 10)
            seek(reader, saved_vo)

            @test virtual_position(reader) == saved_vo
            @test read(reader, 6) == b"world!"
        end

        @testset "Virtual seek to beginning" begin
            read(reader, 20)
            seek(reader, VirtualOffset(0, 0))

            @test virtual_position(reader) == VirtualOffset(0, 0)
            @test read(reader, 5) == b"Hello"
        end

        @testset "Virtual seek within same block" begin
            seekstart(reader)
            seek(reader, VirtualOffset(0, 7))

            @test read(reader, 6) == b"world!"
        end

        @testset "Virtual seek to different block" begin
            seekstart(reader)
            read(reader, 13)
            read(reader, 5)
            vo_second_block = virtual_position(reader)

            seekstart(reader)
            seek(reader, vo_second_block)

            @test virtual_position(reader) == vo_second_block
        end

        @testset "Virtual seek out of bounds throws error" begin
            seekstart(reader)
            @test_throws BGZFError seek(reader, VirtualOffset(0, 100))
        end

        close(reader)
    end
end

@testset "BGZFReader - seek" begin
    for n_workers in [1, 4]
        test_seek_api(io -> BGZFReader(io; n_workers))
    end
end

@testset "BGZFReader - out of bounds seek sets error state" begin
    for n_workers in [1, 4]
        test_seek_out_of_bounds(io -> BGZFReader(io; n_workers))
    end
end

@testset "BGZFReader - virtual_position at EOF and after seek" begin
    for n_workers in [1, 4]
        test_virtual_position_eof((io; kw...) -> BGZFReader(io; n_workers, kw...))
    end
end

@testset "BGZFReader - non-BGZF data" begin
    for n_workers in [1, 4]
        test_non_bgzf_data((f, io) -> BGZFReader(f, io; n_workers))
    end
end

@testset "virtual_position file_offset after empty blocks" begin
    for n_workers in [1, 4]
        reader = BGZFReader(CursorReader(gz1_data); n_workers)
        # gz1_data has empty blocks interspersed. Read all data and verify
        # that virtual_position round-trips: seek back to each saved position
        # and read the same data.
        positions = VirtualOffset[]
        while !eof(reader)
            push!(positions, virtual_position(reader))
            fill_buffer(reader)
            buf = get_buffer(reader)
            isempty(buf) && break
            consume(reader, length(buf))
        end
        for vo in positions
            seek(reader, vo)
            @test virtual_position(reader) == vo
        end
        close(reader)
    end
end

@testset "Error recovery with seek" begin
    for n_workers in [1, 4]
        data = append!(copy(gz1_data), b"bad data")
        reader = BGZFReader(CursorReader(data); n_workers)
        @test_throws BGZFError read(reader)
        @test_throws Exception fill_buffer(reader)

        seekstart(reader)
        @test read(reader, 10) == b"Hello, wor"
        n_bytes_in_data = sum(length, gz1_content)

        # No error, even as malformed block has been encountered.
        read(reader, n_bytes_in_data - 10)

        # Attempting to read one byte from malformed block errors.
        @test_throws BGZFError read(reader, UInt8)

        close(reader)
    end
end

@testset "Close in middle of block" begin
    for n_workers in [1, 4]
        reader = BGZFReader(CursorReader(gz1_data); n_workers)
        read(reader, 3)
        close(reader)
        @test isempty(get_buffer(reader))
        @test eof(reader)
        @test read(reader) == UInt8[]
    end
end

@testset "Parse error is last in result queue" begin
    for n_workers in [1, 4]
        data = append!(copy(gz1_data), b"bad data")
        reader = BGZFReader(CursorReader(data); n_workers)
        # How many blocks are queued per `fill_buffer` depends on the buffer pool,
        # so read until the parse error has been queued.
        for _ in 1:100
            any(x -> x isa BGZFError, reader.result_queue) && break
            consume(reader, length(get_buffer(reader)))
            fill_buffer(reader)
        end
        @test last(reader.result_queue) isa BGZFError
        @test_throws BGZFError read(reader)
        close(reader)
    end
end

@testset "Malformed trailing data reports true file offset" begin
    for n_workers in [1, 4]
        data = append!(copy(gz1_data), b"bad data")
        reader = BGZFReader(CursorReader(data); n_workers)
        err = try
            read(reader)
            nothing
        catch e
            e
        end
        @test err isa BGZFError
        @test err.type === BGZFLib.LibDeflateErrors.gzip_bad_magic_bytes
        @test err.file_offset == length(gz1_data)
        close(reader)
    end
end

@testset "Function argument constructor" begin
    io = IOBuffer(gz1_data)
    result = BGZFReader(io; n_workers = 2) do reader
        @test isopen(reader)
        @test read(reader, 5) == b"Hello"
        @test read(reader, 8) == b", world!"
        read(reader)
    end

    @test !isopen(io)
    @test result == b"more dataxthen some moremore content herethis is another block"
end

@testset "show" begin
    # We just test that showing doesn't error

end

@testset "Large files are read like SyncBGZFReader" begin
    for blocks in (BIG_BLOCKS, SMALL_BLOCKS, MIXED_BLOCKS)
        data = first(make_bgzf(blocks))
        @test length(data) > 2^20
        expected = read_buffers(SyncBGZFReader(CursorReader(data)))
        @test expected[3] === nothing
        for make_source in READER_SOURCES, n_workers in [1, 4]
            @test read_buffers(BGZFReader(make_source(data); n_workers)) == expected
        end
    end
end

@testset "Malformed blocks give the same errors as SyncBGZFReader" begin
    (mixed, offsets) = make_bgzf(MIXED_BLOCKS)
    # Corrupt a block after the first MiB, so the reader has queued many blocks before it
    i = findfirst(>(2^20), offsets)
    off = offsets[i]
    block_size = offsets[i + 1] - off

    # An empty block after the first MiB
    (small, small_offsets) = make_bgzf(SMALL_BLOCKS)
    j = findfirst(eachindex(SMALL_BLOCKS)) do k
        isempty(SMALL_BLOCKS[k]) && small_offsets[k] > 2^20
    end
    empty_off = small_offsets[j]
    # A non-empty block after it
    nonempty_off = small_offsets[findnext(!isempty, SMALL_BLOCKS, j)]

    # Each case has the data and a bit of the expected error type, as a sanity check
    with_byte(data, index, byte) = (data = copy(data); data[index] = byte; data)
    cases = [
        # Reserved flag bit: Only the workers' full parsing of the header detects this
        (with_byte(mixed, off + 4, mixed[off + 4] | 0x20), BGZFLib.LibDeflateErrors.gzip_reserved_flags_set),
        (with_byte(mixed, off + block_size - 7, ~mixed[off + block_size - 7]), BGZFLib.LibDeflateErrors.gzip_bad_crc32),
        (with_byte(mixed, off + 1, 0x00), BGZFLib.LibDeflateErrors.gzip_bad_magic_bytes),
        # Tag of the BC field
        (with_byte(mixed, off + 13, UInt8('X')), BGZFErrors.missing_bc_field),
        (with_byte(small, empty_off + 4, small[empty_off + 4] | 0x20), BGZFLib.LibDeflateErrors.gzip_reserved_flags_set),
        # First byte of the DEFLATE payload: A final block with the reserved block type
        (with_byte(small, nonempty_off + 19, 0xff), BGZFLib.LibDeflateErrors.deflate_bad_payload),
        (mixed[1:(off + 30)], BGZFErrors.truncated_file),
        (mixed[1:off], BGZFErrors.truncated_file),
    ]
    for (data, expected_type) in cases
        expected = read_buffers(SyncBGZFReader(CursorReader(data)))
        @test first(expected[3]) == expected_type
        for make_source in READER_SOURCES, n_workers in [1, 4]
            @test read_buffers(BGZFReader(make_source(data); n_workers)) == expected
        end
    end
end

@testset "Seeking in large files" begin
    data = first(make_bgzf(MIXED_BLOCKS))
    content = reduce(vcat, MIXED_BLOCKS)
    (buffers, _, _) = read_buffers(SyncBGZFReader(CursorReader(data)))
    # Offset of each buffer in the decompressed content
    content_offsets = cumsum([0; [length(b) for (_, b) in buffers[1:(end - 1)]]])
    for make_source in READER_SOURCES, n_workers in [1, 4]
        reader = BGZFReader(make_source(data); n_workers)
        # Seek both forwards and backwards. Read across blocks, but not to EOF,
        # so packages are in flight when seeking.
        for k in 1:length(buffers)
            i = mod1(37 * k, length(buffers))
            (vo, buffer) = buffers[i]
            block_offset = min(100, length(buffer) - 1)
            seek(reader, VirtualOffset(vo.file_offset, block_offset))
            start = content_offsets[i] + block_offset + 1
            @test read(reader, 70000) == content[start:min(end, start + 69999)]
        end
        # All buffers are returned once the reader is EOF
        seekstart(reader)
        @test read(reader) == content
        @test length(reader.buffer_pool) == BGZFLib.total_buffers(n_workers)
        close(reader)
    end
end
