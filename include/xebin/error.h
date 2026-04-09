#pragma once
#include <expected>

namespace xebin {

enum class Error {
    // XEX file parsing
    UnexpectedEof,      // file truncated mid-header or mid-data
    InvalidSegment,     // end_addr < load_addr

    // Decompression
    TruncatedToken,       // escape byte not followed by a complete token
    InvalidBackReference, // LZ77 back-reference offset exceeds output size

    // Factory / dispatch
    UnknownMethod,      // make_compressor called with unrecognised Method value

    // Assembler
    AssemblyFailed,     // assembly error (details via DiagnosticConsumer)
};

template<typename T>
using Result = std::expected<T, Error>;

} // namespace xebin
