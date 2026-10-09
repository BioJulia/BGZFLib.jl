const WRITER_BLOCKS = 4

# Struct sent to writer workers
struct WriterWork
    # This field is used to order the work chunks, so they can be written out
    # in correct order to the underlying IO
    work_index::Int
    uncompressed::ImmutableMemoryView{UInt8}
    destination::Memory{UInt8}
end

# Struct received from writer workers
struct WriterResult
    work_index::Int
    # The unused buffer is always just recycled to the buffer pool
    unused::Memory{UInt8}
    # Either an error, and a buffer that can be recycled. Else, a view that should
    # be written to the underlying IO, after which it can be recycled.
    result::ImmutableMemoryView{UInt8}
end

"""
    BGZFWriter(io::T <: AbstractBufWriter; kwargs)::BGZFWriter{T}
    BGZFWriter(io::T <: IO; kwargs)::BGZFWriter{BufWriter{T}}

Create a `BGZFWriter <: AbstractBufWriter` that compresses data written to it,
and writes the compressed BGZF file to the underlying `io`.

This type differs from `SyncBGZFWriter` in that the compression happens in separate worker tasks.
This allows `BGZFWriter` to compress in parallel, making it faster in the presence of multiple
threads.

If `io::AbstractBufWriter`, `io` must be able to buffer up to 2^16 bytes, else a
`BGZFError(nothing, BGZFErrors.insufficient_writer_space)` is thrown.

If writing to `io` throws, the writer enters an error state, and further flushing or
writing throws a `BGZFError(nothing, BGZFErrors.operation_on_error)`. A writer in the
error state cannot be recovered, but should still be closed to release its resources.

The keyword arguments are:
* `n_workers::Int`: Set number of workers. Must be > 0. Defaults to some small number.
* `compress_level::Int`: Set compression level from 1 to 12, with 12 being slowest but with
  the best compression ratio. It defaults to an intermediate level of compression.
* `append_empty::Bool = true`. If set, closing the `BGZFWriter` will write an empty BGZF block,
  indicating EOF.

`BGZFWriter(f, io; kwargs...)` creates the writer, calls `f` on it, then closes it.
If `f` throws, the empty EOF block is not written, so that readers can detect
the output is incomplete.
"""
mutable struct BGZFWriter{T <: AbstractBufWriter} <: AbstractBufWriter
    const io::T

    # We use a pool of buffers so we can quickly replace a used up buffer while
    # the workers compress previous buffers asyncronously.
    # All buffers are reused, and we don't allocate new ones during operation.
    const buffer_pool::Vector{Memory{UInt8}}

    # FIFO queue - we take results from the receiver and add it here. Then, we popfirst
    # all finished results and flush them to io.io.
    # nothing means result is still at worker.
    const result_queue::Vector{Union{Nothing, ImmutableMemoryView{UInt8}}}
    const sender::Channel{WriterWork}
    const receiver::Channel{WriterResult}
    const workers::Memory{Task}

    # Current buffer to write into.
    buffer::Memory{UInt8}

    # Bytes 1:consumed have already been written
    consumed::Int

    # Number of WriterWork put into the sender
    n_shipped::Int

    # Number of WriterResult received from receiver.
    n_received::Int

    # Number of elements popped from FIFO queue. We use this number
    # to determine which index to add in new results to the queue,
    # e.g. if R result have been removed, then result number N is at index N - R.
    n_removed::Int

    # Write EOF block when closing the writer?
    append_empty::Bool
    state::UInt8
end

function BGZFWriter(
        io::AbstractBufWriter;
        n_workers::Int = min(4, Threads.nthreads()),
        append_empty::Bool = true,
        compress_level::Int = 6,
    )
    in(compress_level, 1:12) || throw(ArgumentError("compress_level must be in 1:12"))
    n_workers < 1 && throw(ArgumentError("Must have at least one worker"))
    # Ensure enough capacity to write a full block
    get_writer_sink_room(io)
    sender = Channel{WriterWork}(Inf)
    receiver = Channel{WriterResult}(Inf)
    # Have some more buffers than 2 x workers, just to keep things more smooth
    pool = [Memory{UInt8}(undef, 4 * MAX_BLOCK_SIZE) for _ in 1:(2 * n_workers + min(2, cld(n_workers, 2)))]
    workers = Memory{Task}(undef, n_workers)
    for i in 1:n_workers
        task = errormonitor(Threads.@spawn writer_worker_loop(sender, receiver, compress_level))
        workers[i] = task
    end
    return BGZFWriter{typeof(io)}(
        io,
        pool,
        Vector{Union{Nothing, ImmutableMemoryView{UInt8}}}(),
        sender,
        receiver,
        workers,
        pop!(pool),
        0,
        0,
        0,
        0,
        append_empty,
        STATE_OPEN,
    )
end

function BGZFWriter(
        io::IO;
        n_workers::Int = min(4, Threads.nthreads()),
        append_empty::Bool = true,
        compress_level::Int = 6,
    )
    in(compress_level, 1:12) || throw(ArgumentError("compress_level must be in 1:12"))
    n_workers < 1 && throw(ArgumentError("Must have at least one worker"))
    bufio = BufWriter(io, MAX_BLOCK_SIZE)
    return BGZFWriter(bufio; n_workers, append_empty, compress_level)
end

function BGZFWriter(f, io::Union{AbstractBufWriter, IO}; kwargs...)
    writer = BGZFWriter(io; kwargs...)
    return try
        f(writer)
    catch
        # Don't mark the output as complete if `f` failed
        writer.append_empty = false
        rethrow()
    finally
        close(writer)
    end
end

Base.isopen(io::BGZFWriter) = io.state != STATE_CLOSED

function write_empty_block(io::BGZFWriter)
    shallow_flush(io)
    write_underlying(io, ImmutableMemoryView(EOF_BLOCK))
    return nothing
end

# We don't expose the full buffer. The reason is that compression may increase the size slightly,
# so if we ship e.g. 4 full blocks, the compressed result does not fit into 4 blocks.
# It's more efficient to expose slightly less, such that if the user fills the exposed buffer,
# it neatly fits in WRITER_BLOCKS number of blocks.
function BufferIO.get_buffer(io::BGZFWriter)
    return @inbounds MemoryView(io.buffer)[(io.consumed + 1):(WRITER_BLOCKS * SAFE_DECOMPRESSED_SIZE)]
end

function BufferIO.consume(io::BGZFWriter, n::Int)
    @boundscheck if n % UInt > (WRITER_BLOCKS * SAFE_DECOMPRESSED_SIZE - io.consumed) % UInt
        throw(IOError(IOErrorKinds.ConsumeBufferError))
    end
    io.consumed += n
    return nothing
end

function check_open(io::BGZFWriter)
    io.state == STATE_CLOSED && throw(IOError(IOErrorKinds.ClosedIO))
    io.state == STATE_ERROR && throw(BGZFError(nothing, BGZFErrors.operation_on_error))
    return nothing
end

# Make `get_buffer` return an empty buffer, so that writing calls `grow_buffer`,
# which throws if the writer is closed or in an error state.
function disable_buffer!(io::BGZFWriter)
    io.consumed = WRITER_BLOCKS * SAFE_DECOMPRESSED_SIZE
    return nothing
end

# If writing to the underlying IO fails, an unknown amount of the data may have been
# written, so the output can't be recovered. We set the error state so the writer
# can't silently continue writing a corrupt file.
function write_underlying(io::BGZFWriter, data::ImmutableMemoryView{UInt8})
    return try
        write(io.io, data)
    catch
        io.state = STATE_ERROR
        disable_buffer!(io)
        rethrow()
    end
end

function BufferIO.shallow_flush(io::BGZFWriter)::Int
    # grow_buffer will ship all data in the current buffer, if any.
    n_flushed = grow_buffer(io)
    # With no data in the buffer, we first need to wait for all shipped
    # data to be received, thus ensuring workers are done.
    while io.n_received < io.n_shipped
        take_result(io)
    end
    # Now, all results should be in the queue. So, we flush it.
    flush_next_result_queue(io)
    # It must be empty now, since we made sure to wait for all data
    # from the workers.
    @assert isempty(io.result_queue)
    return n_flushed
end

function Base.flush(io::BGZFWriter)
    shallow_flush(io)
    flush(io.io)
    return nothing
end

function Base.close(io::BGZFWriter)
    io.state == STATE_CLOSED && return nothing
    try
        # In the error state, the error has already been thrown, and the output is corrupt.
        # So, we only release resources. Throwing here would also mask the original error
        # if `close` is called in a `finally` block.
        if io.state != STATE_ERROR
            shallow_flush(io)
            io.append_empty && write(io.io, EOF_BLOCK)
            flush(io.io)
        end
    finally
        io.state = STATE_CLOSED
        disable_buffer!(io)
        empty!(io.buffer_pool)
        empty!(io.result_queue)
        # Closing the sender terminates the worker loops. We don't close the receiver,
        # because if the flush above failed, workers may still be compressing,
        # and closing the receiver would make their `put!` throw.
        close(io.sender)
        close(io.io)
    end
    return nothing
end

function BufferIO.grow_buffer(io::BGZFWriter)::Int
    check_open(io)
    iszero(io.consumed) && return 0

    while true
        # Take available, finished work from receiver. This frees up buffers
        # without having to wait.
        if !isempty(io.receiver)
            @lock io.receiver begin
                while !isempty(io.receiver)
                    take_result(io)
                end
            end
        end

        # Flush all ready work to underlying IO, potentially freeing up more buffers
        flush_next_result_queue(io)

        # We need two buffers to continue: One to replace the one we send to compression,
        # and one to store the compressed data.
        # It's possible all buffers are in the channels or at workers. If so, we wait
        # for some work, which frees up at least 1 buffer.
        if length(io.buffer_pool) < 2

            # If the logic is sound, the only reason the buffers could be missing
            # is because they have been sent to workers and not yet received (and recycled)
            @assert io.n_received < io.n_shipped
            take_result(io)
            continue
        end

        # Now we have two buffers. We ship the current buffer to the sender channel for
        # compression, and replace it with a fresh buffer from the pool.
        uncompressed = ImmutableMemoryView(io.buffer)[1:io.consumed]
        io.n_shipped += 1
        work = WriterWork(io.n_shipped, uncompressed, pop!(io.buffer_pool))
        put!(io.sender, work)

        io.buffer = pop!(io.buffer_pool)
        old_consumed = io.consumed
        io.consumed = 0
        return old_consumed
    end
    return unreachable()
end

# Take a result from the receiver channel. Before calling this, the io
# should make sure that there are any results in the channel, or at the workers,
# or else this will deadlock.
function take_result(io::BGZFWriter)
    result = take!(io.receiver)
    io.n_received += 1
    push!(io.buffer_pool, result.unused)
    # We popfirst'ed io.n_removed times from the queue, so therefore result number N
    # is at index N - io.n_removed.
    index = result.work_index - io.n_removed

    # Work we have not yet received is represented by `nothing`.
    for _ in (length(io.result_queue) + 1):index
        push!(io.result_queue, nothing)
    end
    # We can't receive the same package twice
    @assert isnothing(io.result_queue[index])
    io.result_queue[index] = result.result
    return nothing
end


# Flush results from queue until we hit a `nothing`, indicating the next result
# has not yet been received.
function flush_next_result_queue(io::BGZFWriter)
    while !isempty(io.result_queue) && !isnothing(first(io.result_queue))
        fst = something(first(io.result_queue)) # we just checked for is nothing
        write_underlying(io, fst)
        popfirst!(io.result_queue)
        io.n_removed += 1
        push!(io.buffer_pool, unsafe_memory(fst))
    end
    return nothing
end

function writer_worker_loop(
        work_channel::Channel{WriterWork},
        result_channel::Channel{WriterResult},
        compress_level::Int,
    )
    compressor = Compressor(compress_level % UInt8)
    for work in work_channel
        n_written = 0
        @assert length(work.uncompressed) ≤ WRITER_BLOCKS * SAFE_DECOMPRESSED_SIZE
        for src in Iterators.partition(work.uncompressed, SAFE_DECOMPRESSED_SIZE)
            dst = MemoryView(work.destination)[(n_written + 1):end]
            block_size = compress_block!(dst, src, compressor)
            # Note: This yield slows down the code too much - we can't yield
            # at every block. Instead, we rely on our channels to yield for us.
            # yield()
            n_written += block_size
        end
        result = WriterResult(
            work.work_index,
            unsafe_memory(work.uncompressed),
            ImmutableMemoryView(work.destination)[1:n_written],
        )
        put!(result_channel, result)
    end
    return
end
