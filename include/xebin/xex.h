#pragma once
#include "error.h"
#include <cstdint>
#include <span>
#include <vector>

namespace xebin {

// ---------------------------------------------------------------------------
// Atari XL/XE binary executable (.xex) format
//
// A .xex file is a sequence of segments, each with a 4-byte header:
//   load_addr_lo  load_addr_hi  end_addr_lo  end_addr_hi
// followed by (end_addr - load_addr + 1) data bytes.
//
// The optional marker $FF $FF may appear before the first segment and,
// depending on the creating tool, between subsequent segments as well.
//
// Two well-known load addresses are treated specially by the OS:
//   $02E0-$02E1  INITAD: called (JSR) by the OS after each segment is loaded
//   $02E2-$02E3  RUNAD:  jumped to after the entire file is loaded
//
// SpartaDOS X extends the format with additional header markers ($FE $FF,
// etc.) for special segment types; those will be added here in a future pass.
// ---------------------------------------------------------------------------

struct Segment {
    uint16_t load_addr = 0;
    std::vector<uint8_t> data;

    uint16_t end_addr() const
    {
        return static_cast<uint16_t>(load_addr + data.size() - 1);
    }
    size_t size() const { return data.size(); }
};

struct XEXFile {
    std::vector<Segment> segments;
};

// Parse a .xex file from raw bytes.
Result<XEXFile> parse_xex(std::span<const uint8_t> bytes);

// Serialize a .xex file.  Emits $FF $FF before the first segment only.
std::vector<uint8_t> write_xex(const XEXFile& file);

} // namespace xebin
