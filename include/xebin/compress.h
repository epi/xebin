#pragma once
#include "error.h"
#include <cstdint>
#include <memory>
#include <span>
#include <vector>

namespace xebin {

// ---------------------------------------------------------------------------
// Method IDs match the $c4 bit flags used in sp.asm:
//   bit 0 (0x01) = RLE
//   bit 1 (0x02) = LZ77
//   bit 2 (0x04) = Huffman
// ---------------------------------------------------------------------------

enum class Method : uint8_t {
    RLE     = 0x01,
    LZ77    = 0x02,
    Huffman = 0x04,
};

class Compressor {
public:
    virtual ~Compressor() = default;

    virtual Method method() const = 0;

    // Compress input bytes.  Returns a self-contained stream that
    // decompress() can round-trip exactly.  An empty input still produces
    // a valid minimal compressed stream.
    virtual Result<std::vector<uint8_t>>
    compress(std::span<const uint8_t> input) const = 0;

    // Decompress a stream produced by compress().
    virtual Result<std::vector<uint8_t>>
    decompress(std::span<const uint8_t> input) const = 0;

protected:
    // Returns the byte with the lowest frequency in input.
    // On ties the lowest byte value wins (matches sp.asm Lac62 iteration).
    static uint8_t find_escape(std::span<const uint8_t> input);
};

// Returns the compressor for the given method, or Error::UnknownMethod.
Result<std::unique_ptr<Compressor>> make_compressor(Method m);

} // namespace xebin
