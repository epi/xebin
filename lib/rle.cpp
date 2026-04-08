#include "xebin/rle.h"
#include <array>

namespace xebin {

// ---------------------------------------------------------------------------
// Find the byte with the lowest frequency in input.
// Matches sp.asm Lac62–Lac85: iterate 0..255, update only on strict
// less-than, so the lowest byte value wins on ties.
// ---------------------------------------------------------------------------
uint8_t RLECompressor::find_escape(std::span<const uint8_t> input)
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

// ---------------------------------------------------------------------------
// Compress — sp.asm Lad92
// ---------------------------------------------------------------------------
Result<std::vector<uint8_t>>
RLECompressor::compress(std::span<const uint8_t> input) const
{
    uint8_t escape = find_escape(input);

    std::vector<uint8_t> out;
    out.reserve(input.size());

    // First byte of the compressed stream is always the escape marker (Lad92).
    out.push_back(escape);

    size_t i = 0;
    while (i < input.size()) {
        uint8_t cur = input[i];

        // Count consecutive identical bytes, capped at 255 (Lada6–Ladb7).
        // The 6502 original overflows the 8-bit counter and flushes at 255,
        // starting a fresh run with the same byte value; we replicate that.
        uint8_t run = 1;
        while (i + run < input.size() && input[i + run] == cur && run < 255)
            ++run;

        if (cur == escape || run >= 4) {
            // Encoded token: (escape, count, byte)  — Ladd2
            out.push_back(escape);
            out.push_back(run);
            out.push_back(cur);
        } else {
            // Literal copies  — Ladc7
            for (uint8_t k = 0; k < run; ++k)
                out.push_back(cur);
        }

        i += run;
    }

    return out;
}

// ---------------------------------------------------------------------------
// Decompress — sp.asm Lb298
// ---------------------------------------------------------------------------
Result<std::vector<uint8_t>>
RLECompressor::decompress(std::span<const uint8_t> input) const
{
    if (input.empty())
        return std::vector<uint8_t>{};

    const uint8_t escape = input[0];
    std::vector<uint8_t> out;

    size_t i = 1;
    while (i < input.size()) {
        uint8_t b = input[i++];

        if (b != escape) {
            out.push_back(b);
        } else {
            // Need count + value (Lb2ad)
            if (i + 1 >= input.size())
                return std::unexpected(Error::TruncatedToken);
            uint8_t count = input[i++];
            uint8_t value = input[i++];
            for (uint8_t k = 0; k < count; ++k)
                out.push_back(value);
        }
    }

    return out;
}

} // namespace xebin
