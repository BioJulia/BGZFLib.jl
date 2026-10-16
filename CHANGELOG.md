# 0.2.0
## Breaking changes
* `seek` now only takes a `VirtualOffset`. The `Int` method (an offset in the
  compressed stream, inconsistent with BufferIO's `seek`) and `virtual_seek` are removed.
  `seekstart` is still supported.
* Rename `SyncBGZFWriter` keyword `compresslevel` to `compress_level`, matching `BGZFWriter`.
* Rename `BGZFErrors.unsorted_index` to `invalid_index`, since it is thrown for all
  invalid indices.
* `index_bgzf` creates the same index as `bgzip --reindex`: Empty blocks are not
  indexed, and the first block is always (0, 0).

## New features
* Add `is_data_error` to distinguish errors caused by malformed data from misuse
  of readers and writers.
* `VirtualOffset` defines `isless`, so `sort`, `min` and `max` work.
* The package is compatible with trimming (`juliac --trim`).

## Bugfixes
GZI index:
* Read and write GZI files in the htslib format, where the first block at (0, 0)
  is implicit. GZI files written by older versions of BGZFLib still load.
* `load_gzi` converts offsets from little-endian, and `write_gzi` works on big-endian CPUs.
* Disallow empty `GZIndex`. `index_bgzf` of an empty file returns a one-block index.
* `GZIndex` no longer requires consecutive indexed blocks to be at most 2^16 bytes apart
  in the compressed stream, since empty blocks between them are not indexed.

Readers:
* `virtual_position` is now correct at EOF, directly after `seek`, and on empty
  input. At EOF, it points to the final empty block, or to the end of the stream.
* Seeking with an out-of-bounds block offset puts the reader in the error state.
* Truncated or non-BGZF input gives more accurate errors, depending on where the
  data is cut off.
* `SyncBGZFReader`: `close` in the error state now closes the underlying IO.
* `BGZFReader`: `eof` is correct when only empty blocks remain.
* `BGZFReader`: Using the reader after closing it partway through a block
  no longer throws a bounds error.

Writers:
* `close` is idempotent, and closes the underlying IO even if flushing fails.
* Writing after `close` throws.
* The do-block form only writes the EOF block if the function succeeds.
* `BGZFWriter` enters an error state if writing to the underlying IO fails,
  instead of silently continuing to write a corrupt file.
* `BGZFWriter`: `shallow_flush` returns the number of uncompressed bytes flushed.
* `VirtualOffset`: negative offsets throw `ArgumentError`, like other out-of-bounds
  construction.

## Other
* Performance improvements for `BGZFReader`: Lower latency for the first block, and
  faster seeking. `SyncBGZFReader` does not re-decompress when seeking within the
  current block.
* `SyncBGZFWriter` avoids a redundant copy of the underlying writer's buffer.

# 0.1.4
* Support MemoryViews v0.5.
* `BGZFReader`: Fix `close` sometimes making in-flight worker tasks throw.
* `BGZFReader`: Fix a bug in `fill_buffer` after seeking.
* `SyncBGZFReader`: Seeking a closed reader throws an `IOError`.

# 0.1.3
* Support MemoryViews v0.4.

# 0.1.2
* Fix offsets in errors from malformed data double-counting skipped empty blocks.
* `get_virtual_offset` returns `nothing` for block offsets of 2^16 and above.
* `BGZFWriter` validates the capacity of fixed-size underlying writers on construction.

# 0.1.1
* Fix out-of-bounds read when parsing blocks with truncated extra fields.
* Fix `BGZFReader` reporting the wrong `file_offset` in errors.
* Fix `SyncBGZFReader` losing the last byte of the buffer in `fill_buffer`.
* `GZIndex` validates that the first block has zero offsets.
* Write GZI lengths as `UInt64`, fixing writing on 32-bit systems.
* Fix `BGZFError` docstring: The field is `file_offset`, not `block_offset`.

# 0.1.0
Initial release
