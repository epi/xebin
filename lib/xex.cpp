#include "xebin/xex.h"

namespace xebin {

Result<XEXFile> parse_xex(std::span<const uint8_t> bytes)
{
    XEXFile file;
    size_t i = 0;

    auto read8 = [&]() -> Result<uint8_t> {
        if (i >= bytes.size())
            return std::unexpected(Error::UnexpectedEof);
        return bytes[i++];
    };

    auto read16 = [&]() -> Result<uint16_t> {
        auto lo = read8();
        if (!lo) return std::unexpected(lo.error());
        auto hi = read8();
        if (!hi) return std::unexpected(hi.error());
        return static_cast<uint16_t>(*lo | (*hi << 8));
    };

    while (i < bytes.size()) {
        // Consume the optional $FF $FF block marker.
        if (i + 1 < bytes.size() && bytes[i] == 0xFF && bytes[i + 1] == 0xFF)
            i += 2;

        if (i >= bytes.size())
            break;

        auto load = read16();
        if (!load) return std::unexpected(load.error());
        auto end = read16();
        if (!end) return std::unexpected(end.error());

        if (*end < *load)
            return std::unexpected(Error::InvalidSegment);

        size_t seg_size = static_cast<size_t>(*end - *load) + 1;
        if (i + seg_size > bytes.size())
            return std::unexpected(Error::UnexpectedEof);

        Segment seg;
        seg.load_addr = *load;
        seg.data.assign(bytes.begin() + i, bytes.begin() + i + seg_size);
        i += seg_size;

        file.segments.push_back(std::move(seg));
    }

    return file;
}

std::vector<uint8_t> write_xex(const XEXFile& file)
{
    std::vector<uint8_t> out;
    bool first = true;

    for (const Segment& seg : file.segments) {
        if (first) {
            out.push_back(0xFF);
            out.push_back(0xFF);
            first = false;
        }
        uint16_t end = seg.end_addr();
        out.push_back(static_cast<uint8_t>(seg.load_addr & 0xFF));
        out.push_back(static_cast<uint8_t>(seg.load_addr >> 8));
        out.push_back(static_cast<uint8_t>(end & 0xFF));
        out.push_back(static_cast<uint8_t>(end >> 8));
        out.insert(out.end(), seg.data.begin(), seg.data.end());
    }

    return out;
}

} // namespace xebin
