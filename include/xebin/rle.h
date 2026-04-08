#pragma once
#include "compress.h"

namespace xebin {

// ---------------------------------------------------------------------------
// RLE compressor — Method 0x01
// Derived from sp.asm Lad92 (compressor) and Lb298 (decompressor).
//
// Compressed stream layout:
//   byte 0       : escape byte (least-frequent byte value in the input)
//   bytes 1..n   : encoded data
//
// Encoding for a run of N identical bytes with value B:
//   B == escape  OR  N >= 4  →  (escape, N, B)   [3 bytes]
//   otherwise                →  B repeated N times [N < 4 bytes]
//
// Runs longer than 255 are split into multiple tokens.
// The escape byte never appears as a literal; a single occurrence is
// encoded as (escape, 1, escape).
// ---------------------------------------------------------------------------

class RLECompressor : public Compressor {
public:
    Method method() const override { return Method::RLE; }

    Result<std::vector<uint8_t>>
    compress(std::span<const uint8_t> input) const override;

    Result<std::vector<uint8_t>>
    decompress(std::span<const uint8_t> input) const override;

};

} // namespace xebin
