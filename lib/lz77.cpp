#include "xebin/lz77.h"
namespace xebin {

// ---------------------------------------------------------------------------
// Compress — sp.asm Lafcf / Lb04f
//
// For each input position:
//   1. Search backward up to 1023 bytes for the longest match >= 4 bytes.
//      Max match length is 63 (6-bit field in token).
//      The search scans oldest→newest (highest→lowest offset).  If a match
//      reaches max_len the loop exits immediately (sp.asm Lb087 BCS Lb099),
//      so among equal-length max matches the highest (oldest) offset is kept.
//      For sub-max matches the loop continues and the lowest offset wins.
//      When fewer than 5 bytes remain the search is skipped entirely
//      (sp.asm Lafff / CPY #$05 BCC Lafff).
//   2. If a qualifying match is found, emit (escape, token, off_lo).
//      Advance current position by match length.
//   3. Otherwise emit the literal; if it equals the escape byte also emit 0x00.
// ---------------------------------------------------------------------------
Result<std::vector<uint8_t>>
LZ77Compressor::compress(std::span<const uint8_t> input) const
{
    uint8_t escape = find_escape(input);

    std::vector<uint8_t> out;
    out.reserve(input.size());
    out.push_back(escape);

    size_t pos = 0;
    while (pos < input.size()) {
        // Search for the best back-reference.
        size_t max_offset = std::min(pos, size_t{1023});
        size_t max_len    = std::min(input.size() - pos, size_t{63});

        size_t best_len    = 0;
        size_t best_offset = 0;

        // sp.asm Lb032/Lafff: skip search entirely when fewer than 5 bytes
        // remain (CPY #$05 / BCC Lafff).  A match of length 4 in the final
        // 4 bytes is never produced by the original compressor.
        if (max_len >= 5) {
            // Oldest to newest (large offset → small); update on >= so
            // smallest offset wins among equal-length matches.
            // sp.asm Lb087: CPY $f7 / BCS Lb099 — exit as soon as the first
            // max-length match is found, keeping the largest offset on ties.
            for (size_t off = max_offset; off >= 1; --off) {
                size_t start = pos - off;
                size_t len = 0;
                while (len < max_len && input[start + len] == input[pos + len])
                    ++len;
                if (len >= best_len) {  // mirrors CPY $f8 / BCC skip
                    best_len    = len;
                    best_offset = off;
                }
                if (len == max_len)     // mirrors CPY $f7 / BCS Lb099
                    break;
            }
        }

        if (best_len >= 4) {
            // Encode back-reference: (escape, token, off_lo)
            uint8_t token  = static_cast<uint8_t>(
                (best_len & 0x3F) | ((best_offset >> 2) & 0xC0));
            uint8_t off_lo = static_cast<uint8_t>(best_offset & 0xFF);
            out.push_back(escape);
            out.push_back(token);
            out.push_back(off_lo);
            pos += best_len;
        } else {
            // Literal
            uint8_t b = input[pos++];
            out.push_back(b);
            if (b == escape)
                out.push_back(0x00);  // mark literal escape
        }
    }

    return out;
}

// ---------------------------------------------------------------------------
// Decompress — sp.asm Lb249 / Lb288
//
// Read escape byte, then loop:
//   byte != escape  → literal
//   byte == escape  → read token
//     token == 0    → literal escape
//     token != 0    → back-reference
//       length  = token & 0x3F
//       off_hi  = (token >> 6) & 0x03   [equivalent to 3×ROL + AND #$03]
//       off_lo  = next byte
//       offset  = (off_hi << 8) | off_lo
//       copy `length` bytes from out[out.size() - offset] (byte-by-byte,
//       so overlapping copies produce repeating output)
// ---------------------------------------------------------------------------
Result<std::vector<uint8_t>>
LZ77Compressor::decompress(std::span<const uint8_t> input) const
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
            continue;
        }

        // Escape sequence — need at least the token byte.
        if (i >= input.size())
            return std::unexpected(Error::TruncatedToken);

        uint8_t token = input[i++];

        if (token == 0x00) {
            // Literal escape byte.
            out.push_back(escape);
            continue;
        }

        // Back-reference — need offset_lo byte.
        if (i >= input.size())
            return std::unexpected(Error::TruncatedToken);

        uint8_t off_lo = input[i++];

        size_t   off_hi = (token >> 6) & 0x03;
        size_t   offset = (off_hi << 8) | off_lo;
        uint8_t  length = token & 0x3F;

        if (offset == 0 || offset > out.size())
            return std::unexpected(Error::InvalidBackReference);

        size_t match_start = out.size() - offset;
        for (uint8_t k = 0; k < length; ++k) {
            uint8_t copied = out[match_start + k];
            out.push_back(copied);
        }
    }

    return out;
}

} // namespace xebin
