#pragma once
#include <expected>

namespace xebin {

enum class Error {
    // XEX file parsing
    UnexpectedEof,      // file truncated mid-header or mid-data
    InvalidSegment,     // end_addr < load_addr

    // Decompression
    TruncatedToken,     // escape byte not followed by a complete (count, value) pair

    // Factory / dispatch
    UnknownMethod,      // make_compressor called with unrecognised Method value
};

template<typename T>
using Result = std::expected<T, Error>;

} // namespace xebin
