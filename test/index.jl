@testset "VirtualOffset" begin
    @testset "Construction" begin
        vo = VirtualOffset(100, 50)
        @test vo.file_offset == 100
        @test vo.block_offset == 50
    end

    @testset "Valid ranges" begin
        # Maximum valid file offset: 2^48 - 1
        vo1 = VirtualOffset(2^48 - 1, 0)
        @test vo1.file_offset == 2^48 - 1

        # Maximum valid block offset: 2^16 - 1
        vo2 = VirtualOffset(0, 2^16 - 1)
        @test vo2.block_offset == 2^16 - 1
    end

    @testset "Out of range throws error" begin
        # File offset too large
        @test_throws ArgumentError VirtualOffset(2^48, 0)

        # Block offset too large
        @test_throws ArgumentError VirtualOffset(0, 2^16)

        # Negative offsets
        @test_throws ArgumentError VirtualOffset(-1, 0)
        @test_throws ArgumentError VirtualOffset(0, -1)
    end

    @testset "Comparison" begin
        vo1 = VirtualOffset(100, 10)
        vo2 = VirtualOffset(100, 20)
        vo3 = VirtualOffset(200, 5)
        vo4 = VirtualOffset(100, 10)

        @test vo1 < vo2
        @test vo1 < vo3
        @test vo2 < vo3
        @test !(vo1 < vo4)

        @test cmp(vo1, vo2) == -1
        @test cmp(vo2, vo1) == 1
        @test cmp(vo1, vo4) == 0

        @test sort([vo3, vo1, vo2]) == [vo1, vo2, vo3]
        @test max(vo1, vo3, vo2) == vo3
        @test isless(vo1, vo2)
        @test !isless(vo1, vo4)
    end

    @testset "Show" begin
        vo = VirtualOffset(2^48 - 1, 2^16 - 1)
        io = IOBuffer()
        show(io, vo)
        @test !isempty(take!(io))
    end
end


@testset "GZIndex constructor" begin
    @testset "Valid sorted blocks" begin
        blocks = [
            (compressed_offset = 0x0000000000000000, decompressed_offset = 0x0000000000000000),
            (compressed_offset = 0x000000000000002c, decompressed_offset = 0x000000000000000d),
            (compressed_offset = 0x0000000000000058, decompressed_offset = 0x0000000000000016),
        ]

        gzi = GZIndex(blocks)
        @test gzi isa GZIndex
        @test gzi.blocks == blocks
    end

    @testset "Unsorted compressed offsets throws error" begin
        blocks = [
            (compressed_offset = 0x0000000000000058, decompressed_offset = 0x0000000000000000),
            (compressed_offset = 0x000000000000002c, decompressed_offset = 0x000000000000000d),
        ]

        err = try
            GZIndex(blocks)
            nothing
        catch e
            e
        end
        @test err isa BGZFError
        @test err.type == BGZFErrors.invalid_index
    end

    @testset "Large compressed distance between blocks" begin
        # Empty blocks are not indexed, so consecutive indexed blocks
        # may be more than 2^16 bytes apart in the compressed stream
        blocks = [
            (compressed_offset = UInt64(0), decompressed_offset = UInt64(0)),
            (compressed_offset = UInt64(100_000), decompressed_offset = UInt64(10)),
        ]
        @test GZIndex(blocks).blocks == blocks
    end

    @testset "Unsorted decompressed offsets throws error" begin
        blocks = [
            (compressed_offset = 0x000000000000002c, decompressed_offset = 0x000000000000000d),
            (compressed_offset = 0x0000000000000058, decompressed_offset = 0x0000000000000000),
        ]

        @test_throws BGZFError GZIndex(blocks)
    end

    @testset "Nonzero first block offsets throws error" begin
        @test_throws BGZFError GZIndex(
            [
                (compressed_offset = UInt64(100), decompressed_offset = UInt64(0)),
            ]
        )
        @test_throws BGZFError GZIndex(
            [
                (compressed_offset = UInt64(0), decompressed_offset = UInt64(100)),
            ]
        )
    end

    @testset "Empty blocks vector throws error" begin
        @test_throws ArgumentError GZIndex(BGZFLib.IndexBlock[])
    end
end

@testset "load_gzi" begin
    @testset "From AbstractBufReader" begin
        gzi = load_gzi(CursorReader(gzi_data))
        @test gzi isa GZIndex
        @test !isempty(gzi.blocks)
        @test all(i -> gzi.blocks[i].compressed_offset <= gzi.blocks[i + 1].compressed_offset, 1:(length(gzi.blocks) - 1))
        @test all(i -> gzi.blocks[i].decompressed_offset <= gzi.blocks[i + 1].decompressed_offset, 1:(length(gzi.blocks) - 1))
    end

    @testset "From IO" begin
        gzi = load_gzi(IOBuffer(gzi_data))
        @test gzi isa GZIndex
        @test !isempty(gzi.blocks)
    end

    @testset "Truncated file throws EOF error" begin
        # Remove some bytes from the end
        truncated = gzi_data[1:(end - 10)]
        @test_throws IOError load_gzi(CursorReader(truncated))
    end

    @testset "Empty file throws EOF error" begin
        @test_throws IOError load_gzi(CursorReader(UInt8[]))
    end
end

@testset "index_bgzf" begin
    @testset "From AbstractBufReader" begin
        gzi = index_bgzf(CursorReader(gz1_data))
        @test gzi isa GZIndex
        @test !isempty(gzi.blocks)

        # First block should start at offset 0
        @test gzi.blocks[1].compressed_offset == 0
        @test gzi.blocks[1].decompressed_offset == 0

        # Blocks should be sorted
        @test all(i -> gzi.blocks[i].compressed_offset <= gzi.blocks[i + 1].compressed_offset, 1:(length(gzi.blocks) - 1))
        @test all(i -> gzi.blocks[i].decompressed_offset <= gzi.blocks[i + 1].decompressed_offset, 1:(length(gzi.blocks) - 1))
    end

    @testset "From IO" begin
        gzi = index_bgzf(IOBuffer(gz1_data))
        @test gzi isa GZIndex
        @test !isempty(gzi.blocks)
    end

    @testset "Index matches loaded gzi" begin
        computed_gzi = index_bgzf(CursorReader(gz1_data))
        loaded_gzi = load_gzi(CursorReader(gzi_data))

        @test computed_gzi.blocks == loaded_gzi.blocks
    end

    @testset "Empty file returns 1-element index" begin
        empty_bgzf = BGZFLib.EOF_BLOCK
        gzi = index_bgzf(CursorReader(empty_bgzf))
        @test gzi.blocks == [(compressed_offset = 0x0000000000000000, decompressed_offset = 0x0000000000000000)]
    end

    @testset "Use index for seeking" begin
        gzi = index_bgzf(CursorReader(gz1_data))
        reader = SyncBGZFReader(CursorReader(gz1_data))
        decompressed = read(reader)

        # Read from all the blocks in the index
        for (; compressed_offset, decompressed_offset) in gzi.blocks
            seek(reader, VirtualOffset(compressed_offset, 0))
            @test read(reader) == decompressed[(decompressed_offset + 1):end]
        end

        close(reader)
    end

    @testset "Some decompressed offsets" begin
        gzi = load_gzi(CursorReader(gzi_data))
        reader = SyncBGZFReader(CursorReader(gz1_data))
        decompressed = read(reader)
        for dco in [0, 5, 10, 30, 45, 60]
            vo = get_virtual_offset(gzi, dco)
            seek(reader, vo)
            v = read(reader)
            @test v == decompressed[(dco + 1):end]
        end
        close(reader)

        @test get_virtual_offset(gzi, -1) === nothing
        @test get_virtual_offset(gzi, 100_000) === nothing
        max_last_block = Int(last(gzi.blocks).decompressed_offset) + 2^16
        @test get_virtual_offset(gzi, max_last_block) === nothing
    end
end

@testset "Round trip: index, write, load" begin
    # Create an index from the BGZF file
    original_gzi = index_bgzf(CursorReader(gz1_data))

    # Write it to a buffer
    io = VecWriter()
    write_gzi(io, original_gzi)

    # Load it back
    loaded_gzi = load_gzi(CursorReader(io.vec))

    # Should match
    @test original_gzi.blocks == loaded_gzi.blocks
end

function gzi_bytes(entries)
    io = VecWriter()
    write(io, htol(UInt64(length(entries))))
    for (co, dco) in entries
        write(io, htol(UInt64(co)), htol(UInt64(dco)))
    end
    return io.vec
end

@testset "htslib GZI compatibility" begin
    @testset "Load GZI written by bgzip" begin
        # Output of `bgzip -r` on data/1.gz. htslib omits the first block and empty blocks
        data = gzi_bytes([(44, 13), (115, 22), (178, 23), (223, 37), (271, 54)])
        gzi = load_gzi(CursorReader(data))
        @test [(Int(i.compressed_offset), Int(i.decompressed_offset)) for i in gzi.blocks] ==
            [(0, 0), (44, 13), (115, 22), (178, 23), (223, 37), (271, 54)]

        reader = SyncBGZFReader(CursorReader(gz1_data))
        decompressed = read(reader)
        for dco in [0, 5, 13, 22, 30, 60]
            seek(reader, get_virtual_offset(gzi, dco))
            @test read(reader) == decompressed[(dco + 1):end]
        end
        close(reader)
    end

    @testset "Load GZI with only one block" begin
        gzi = load_gzi(CursorReader(gzi_bytes(Tuple{Int, Int}[])))
        @test gzi.blocks == [(compressed_offset = UInt64(0), decompressed_offset = UInt64(0))]
    end

    @testset "Load GZI with explicit first block" begin
        data = gzi_bytes([(0, 0), (44, 13), (84, 22)])
        gzi = load_gzi(CursorReader(data))
        @test [(Int(i.compressed_offset), Int(i.decompressed_offset)) for i in gzi.blocks] ==
            [(0, 0), (44, 13), (84, 22)]
    end

    @testset "Written GZI omits first block" begin
        gzi = index_bgzf(CursorReader(gz1_data))
        io = VecWriter()
        @test write_gzi(io, gzi) == 8 + 16 * (length(gzi.blocks) - 1)
        @test io.vec == gzi_data
    end

    @testset "Index of empty file round trips" begin
        gzi = index_bgzf(CursorReader(UInt8[]))
        @test gzi.blocks == [(compressed_offset = UInt64(0), decompressed_offset = UInt64(0))]
        io = VecWriter()
        @test write_gzi(io, gzi) == 8
        @test load_gzi(CursorReader(io.vec)).blocks == gzi.blocks
        @test get_virtual_offset(gzi, 0) == VirtualOffset(0, 0)
    end
end

@testset "index_bgzf matches bgzip" begin
    # Each element is either a string, written as one block, or `:empty`, an empty block.
    # The expected indexed blocks are those that `bgzip --reindex` (htslib 1.24) creates:
    # The first block is (0, 0), and the remaining are the non-empty blocks after the
    # first non-empty block.
    cases = [
        ([:empty, "abc"], Int[]),
        (["abc", :empty, :empty, "defg"], [4]),
        (["abc", :empty], Int[]),
        (Any[], Int[]),
        ([:empty, :empty, "abc", "de"], [4]),
    ]
    for (parts, indexed) in cases
        io = VecWriter()
        block_offsets = Int[]
        decompressed_offsets = Int[]
        n_decompressed = 0
        SyncBGZFWriter(io) do writer
            for part in parts
                push!(block_offsets, length(io.vec))
                push!(decompressed_offsets, n_decompressed)
                if part === :empty
                    write_empty_block(writer)
                else
                    write(writer, part)
                    shallow_flush(writer)
                    n_decompressed += ncodeunits(part)
                end
            end
        end
        expected = [(0, 0); [(block_offsets[i], decompressed_offsets[i]) for i in indexed]]
        gzi = index_bgzf(CursorReader(io.vec))
        @test [(Int(i.compressed_offset), Int(i.decompressed_offset)) for i in gzi.blocks] == expected

        # Seeking to all decompressed offsets with the index, like htslib does
        content = SyncBGZFReader(read, CursorReader(io.vec))
        reader = SyncBGZFReader(CursorReader(io.vec))
        for offset in 0:length(content)
            seek(reader, get_virtual_offset(gzi, offset))
            @test read(reader) == content[(offset + 1):end]
        end
        close(reader)
    end
end
