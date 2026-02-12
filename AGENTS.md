# Project overview
BGZFLib.jl reads and writes BGZF (Blocked GNU Zip Format) files, used in bioinformatics (e.g. BAM files).
It implements the `AbstractBufReader`/`AbstractBufWriter` interfaces from BufferIO.jl.

Key dependencies: BufferIO.jl, LibDeflate.jl, MemoryViews.jl.

## Source layout
* `src/BGZFLib.jl` — Module definition, exports, shared types (`BGZFError`, `BGZFErrors`, `VirtualOffset`), constants (`MAX_BLOCK_SIZE = 2^16`, `SAFE_DECOMPRESSED_SIZE`, `BLOCK_HEADER`, `EOF_BLOCK`), and shared helpers (`parse_bgzf_block!`, `compress_block!`, `get_reader_source_room`, `get_writer_sink_room`, `unsafe_bitload`, `unsafe_bitstore!`)
* `src/syncreader.jl` — `SyncBGZFReader{T}`: single-task synchronous BGZF reader
* `src/syncwriter.jl` — `SyncBGZFWriter{T}`: single-task synchronous BGZF writer
* `src/reader.jl` — `BGZFReader{T}`: async multi-worker BGZF reader using `Threads.@spawn` and `Channel`s
* `src/writer.jl` — `BGZFWriter{T}`: async multi-worker BGZF writer using `Threads.@spawn` and `Channel`s
* `src/index.jl` — `GZIndex`, `load_gzi`, `write_gzi`, `index_bgzf`, `get_virtual_offset`

## Test layout
* `test/runtests.jl` — entry point; loads test data from `data/` directory
* `test/syncreader.jl`, `test/syncwriter.jl`, `test/reader.jl`, `test/writer.jl`, `test/index.jl` — corresponding test files
* Test data: `data/1.gz` (BGZF file with multiple blocks), `data/1.gzi` (GZI index)

## Running tests
```
JULIA_TEST_FAILFAST=true julia --startup=no --project -e 'using Pkg; Pkg.test()'
```

## Key architecture notes
* All readers/writers have fixed-size (non-expandable) buffers. `fill_buffer` returns `nothing` when the buffer is nonempty. `grow_buffer` on writers does a shallow flush instead of expanding.
* Async variants (`BGZFReader`/`BGZFWriter`) use a buffer pool + worker tasks via channels. Workers decompress/compress blocks. Results are ordered via a FIFO queue indexed by `buffer_offset`/`work_index`.
* Readers wrap an `AbstractBufReader` of compressed data; writers wrap an `AbstractBufWriter` that receives compressed output.
* Seeking invalidates in-flight worker results by incrementing skip counters (reader) so stale results get negative queue indices and are discarded.
* Error state: readers enter error state on malformed data. Recovery is via `seek`/`seekstart`. Writers don't recover.
* `VirtualOffset` packs file_offset (48 bits) and block_offset (16 bits) into a UInt64.
* BGZF blocks: gzip with BC extra field giving block size. Max block 2^16 bytes. EOF marker is an empty BGZF block.

# Overall instructions
* Avoid comments where the purpose can easily be inferred from the code and variable names themselves

# How to write tests
* Keep tests small and self-contained. Do not make long chains of tests that mutate the same state, unless it's necessary for the test logic.
* See existing tests for the style and structure of the tests

# Docstrings for BufferIO functions
This section contains docstrings from the BufferIO package.

These should be followed by implementations in BGZFLib.
In particular, readers and writers in BGZFLib cannot expand their buffer.

## fill_buffer
"""
    fill_buffer(io::AbstractBufReader)::Union{Int, Nothing}

Fill more bytes into the buffer from `io`'s underlying buffer, returning
the number of bytes added. After calling `fill_buffer` and getting `n`,
the buffer obtained by `get_buffer` should have `n` new bytes appended.

This function must fill at least one byte, except
* If the underlying io is EOF, or there is no underlying io to fill bytes from, return 0
* If the buffer is not empty, and cannot be expanded, return `nothing`.

Buffered readers which do not wrap another underlying IO, and therefore can't fill
its buffer should return 0 unconditionally.
This function should never return `nothing` if the buffer is empty.

!!! note
    Idiomatically, users should not call `fill_buffer` when the buffer is not empty,
    because doing so may force growing the buffer instead of letting `io` choose an optimal
    buffer size. Calling `fill_buffer` with a nonempty buffer is only appropriate if, for
    algorithmic reasons you need `io` itself to buffer some minimum amount of data.
"""

# get_buffer
"""
    get_buffer(io::AbstractBufReader)::ImmutableMemoryView{UInt8}

Get the available bytes of `io`.

Calling this function, even when the buffer is empty, should never do actual system I/O,
and in particular should not attempt to fill the buffer.
To fill the buffer, call [`fill_buffer`](@ref).

    get_buffer(io::AbstractBufWriter)::MutableMemoryView{UInt8}

Get the available mutable buffer of `io` that can be written to.

Calling this function should never do actual system I/O, and in particular
should not attempt to flush data from the buffer or grow the buffer.
To increase the size of the buffer, call [`grow_buffer`](@ref).
"""

# consume
"""
    consume(io::Union{AbstractBufReader, AbstractBufWriter}, n::Int)::Nothing

Remove the first `n` bytes of the buffer of `io`.
Consumed bytes will not be returned by future calls to `get_buffer`.

If n is negative, or larger than the current buffer size,
throw an `IOError` with `ConsumeBufferError` kind.
This check is a boundscheck and may be elided with `@inbounds`.
"""
