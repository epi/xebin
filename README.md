# xebin — Atari XL/XE Binary File Library and Tools

**xebin** is a C++ library and command-line tool for reading, writing, and
compressing Atari XL/XE binary executable (`.xex`) files.


## Requirements

| Dependency | Version |
|------------|---------|
| C++ compiler with C++23 support | e.g. GCC ≥ 13, clang ≥ 17 |
| CMake      | ≥ 3.20  |
| Catch2     | ≥ 3     |


## Building

```sh
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build
```

Artifacts:

| File | Description |
|------|-------------|
| `build/libxebin.a` | Static library |
| `build/xebin`    | Command-line tool |
| `build/test_rle`   | Unit tests |

Run tests:

```sh
ctest --test-dir build --output-on-failure
```


## Command-line tool — `xebin`

### Show file info

```sh
xebin info <input.xex>
```

Prints the number of segments and, for each one, its load address range and
byte size.

```
game.xex: 3 segment(s)
  [0]  $2000–$3FFF  (8192 bytes)
  [1]  $02E0–$02E1  (2 bytes)
  [2]  $02E2–$02E3  (2 bytes)
```

### Compress

```sh
xebin compress --method <method> <input.xex> <output.xex>
```

Compresses every segment of `input.xex` independently and writes the result
to `output.xex`.  Per-segment before/after sizes are printed to stdout.

Available methods:

| `--method` | Algorithm |
|------------|-----------|
| `rle`      | Escape-byte run-length encoding |
| `lz77`     | *(not yet implemented)* |
| `huffman`  | *(not yet implemented)* |

### Decompress

```sh
xebin decompress --method <method> <input.xex> <output.xex>
```

Reverses a previous `compress` step.  The method must match the one used
during compression.


## Library API

Add `include/` to your include path and link against `libxebin.a`.

### Error handling — `<xebin/error.h>`

All fallible operations return `Result<T>`, an alias for
`std::expected<T, Error>`.

```cpp
namespace xebin {

enum class Error {
    UnexpectedEof,   // file truncated mid-header or mid-data
    InvalidSegment,  // segment end_addr < load_addr
    TruncatedToken,  // compressed token cut off before count/value
    UnknownMethod,   // make_compressor called with unrecognised Method
};

template<typename T>
using Result = std::expected<T, Error>;

} // namespace xebin
```

### XEX file format — `<xebin/xex.h>`

```cpp
namespace xebin {

struct Segment {
    uint16_t load_addr;
    std::vector<uint8_t> data;

    uint16_t end_addr() const;
    size_t   size()     const;
};

struct XEXFile {
    std::vector<Segment> segments;
};

Result<XEXFile>      parse_xex(std::span<const uint8_t> bytes);
std::vector<uint8_t> write_xex(const XEXFile& file);

} // namespace xebin
```

`parse_xex` accepts the raw bytes of a `.xex` file (including the optional
`$FF $FF` block marker) and returns the parsed segment list, or an `Error`.

`write_xex` serialises a `XEXFile` back to bytes, emitting `$FF $FF` before
the first segment.

### Compression — `<xebin/compress.h>`, `<xebin/rle.h>`

```cpp
namespace xebin {

enum class Method : uint8_t {
    RLE     = 0x01,
    LZ77    = 0x02,  // not yet implemented
    Huffman = 0x04,  // not yet implemented
};

class Compressor {
public:
    virtual Method method() const = 0;
    virtual Result<std::vector<uint8_t>> compress  (std::span<const uint8_t>) const = 0;
    virtual Result<std::vector<uint8_t>> decompress(std::span<const uint8_t>) const = 0;
};

Result<std::unique_ptr<Compressor>> make_compressor(Method m);

} // namespace xebin
```

`make_compressor` is the preferred way to obtain a compressor.  It returns
`Error::UnknownMethod` for methods that have not been implemented yet.

#### Example

```cpp
#include "xebin/xex.h"
#include "xebin/compress.h"

auto raw  = /* read file bytes */;
auto xex  = xebin::parse_xex(raw);
if (!xex) { /* handle xex.error() */ }

auto comp = xebin::make_compressor(xebin::Method::RLE);
if (!comp) { /* handle comp.error() */ }

for (auto& seg : xex->segments) {
    auto result = (*comp)->compress(seg.data);
    if (!result) { /* handle result.error() */ }
    seg.data = std::move(*result);
}

auto out = xebin::write_xex(*xex);
/* write out to file */
```

#### RLE format

The compressed stream begins with the escape byte (the least-frequent byte
value in the input).  What follows is a mix of:

- **Literal bytes** — any byte other than the escape, emitted as-is.
- **Encoded runs** — `(escape, count, value)`: `count` copies of `value`.
  Used when `value == escape` or the run length is ≥ 4.  Runs longer than
  255 bytes are split into multiple tokens.


## License

```
Poetic License:

This work 'as-is' we provide.
No warranty express or implied.
We've done our best,
to debug and test.
Liability for damages denied.

Permission is granted hereby,
to copy, share, and modify.
Use as is fit,
free or for profit.
These rights, on this notice, rely.
```


## Authors

**Piotr Fusik** — original FlashPack program, depacker routines, testing.
**Jiří Bernášek** — original Super Packer program.
**Adrian Matoga** — programming.
