#include "xebin/compress.h"
#include "xebin/rle.h"
#include "xebin/lz77.h"
#include <array>

namespace xebin {

// ---------------------------------------------------------------------------
// Shared helper — sp.asm Lac62–Lac85
// ---------------------------------------------------------------------------
uint8_t Compressor::find_escape(std::span<const uint8_t> input)
{
    std::array<uint32_t, 256> freq{};
    for (uint8_t b : input)
        ++freq[b];

    uint8_t escape = 0;
    uint32_t min_freq = freq[0];
    for (int i = 1; i < 256; ++i) {
        if (freq[i] < min_freq) {
            min_freq = freq[i];
            escape = static_cast<uint8_t>(i);
        }
    }
    return escape;
}

Result<std::unique_ptr<Compressor>> make_compressor(Method m)
{
    switch (m) {
    case Method::RLE:
        return std::make_unique<RLECompressor>();
    case Method::LZ77:
        return std::make_unique<LZ77Compressor>();
    // Huffman will be added here when implemented.
    default:
        return std::unexpected(Error::UnknownMethod);
    }
}

} // namespace xebin
