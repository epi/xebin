#pragma once
#include "compress.h"

namespace xebin {

// ---------------------------------------------------------------------------
// LZ77 compressor — Method 0x02
// Derived from sp.asm Lafcf (compressor) and Lb249 (decompressor).
//
// Compressed stream layout:
//   byte 0       : escape byte (least-frequent byte value in the input)
//   bytes 1..n   : encoded data
//
// Each input position is encoded as one of:
//   literal (byte != escape) : emit byte as-is
//   literal escape            : (escape, 0x00)          [2 bytes]
//   back-reference            : (escape, token, off_lo)  [3 bytes]
//
// Back-reference token:
//   token = (length & 0x3F) | ((offset >> 2) & 0xC0)
//   off_lo = offset & 0xFF
//   offset is 10 bits (1..1023), length is 6 bits (4..63)
//   token is never 0x00 because length >= 4
//
// A back-reference may overlap the current write position (offset < length).
// The decompressor copies byte-by-byte, so overlap produces repeating output.
// ---------------------------------------------------------------------------

class LZ77Compressor : public Compressor {
public:
    Method method() const override { return Method::LZ77; }

    Result<std::vector<uint8_t>>
    compress(std::span<const uint8_t> input) const override;

    Result<std::vector<uint8_t>>
    decompress(std::span<const uint8_t> input) const override;
};

} // namespace xebin
