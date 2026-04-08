#include "xebin/compress.h"
#include "xebin/rle.h"

namespace xebin {

Result<std::unique_ptr<Compressor>> make_compressor(Method m)
{
    switch (m) {
    case Method::RLE:
        return std::make_unique<RLECompressor>();
    // LZ77 and Huffman will be added here as they are implemented.
    default:
        return std::unexpected(Error::UnknownMethod);
    }
}

} // namespace xebin
