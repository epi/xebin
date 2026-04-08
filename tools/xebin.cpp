#include "xebin/compress.h"
#include "xebin/error.h"
#include "xebin/rle.h"
#include "xebin/xex.h"
#include <cstdio>
#include <cstring>
#include <fstream>
#include <vector>

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static const char* error_str(xebin::Error e)
{
    switch (e) {
    case xebin::Error::UnexpectedEof:   return "unexpected end of file";
    case xebin::Error::InvalidSegment:  return "segment end address < load address";
    case xebin::Error::TruncatedToken:        return "truncated compressed token";
    case xebin::Error::InvalidBackReference:  return "invalid LZ77 back-reference";
    case xebin::Error::UnknownMethod:         return "unknown compression method";
    }
    return "unknown error";
}

static std::vector<uint8_t> read_file(const char* path)
{
    std::ifstream f(path, std::ios::binary);
    if (!f) {
        std::fprintf(stderr, "error: cannot open '%s'\n", path);
        std::exit(2);
    }
    return {std::istreambuf_iterator<char>(f), {}};
}

static void write_file(const char* path, const std::vector<uint8_t>& data)
{
    std::ofstream f(path, std::ios::binary);
    if (!f) {
        std::fprintf(stderr, "error: cannot write '%s'\n", path);
        std::exit(2);
    }
    f.write(reinterpret_cast<const char*>(data.data()),
            static_cast<std::streamsize>(data.size()));
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

static int cmd_info(const char* path)
{
    auto raw = read_file(path);
    auto xex = xebin::parse_xex(raw);
    if (!xex) {
        std::fprintf(stderr, "error: %s\n", error_str(xex.error()));
        return 1;
    }

    std::printf("%s: %zu segment(s)\n", path, xex->segments.size());
    for (size_t i = 0; i < xex->segments.size(); ++i) {
        const auto& seg = xex->segments[i];
        std::printf("  [%zu]  $%04X–$%04X  (%zu bytes)\n",
                    i, seg.load_addr, seg.end_addr(), seg.size());
    }
    return 0;
}

static int cmd_compress(xebin::Method method,
                        const char* in_path, const char* out_path)
{
    auto comp = xebin::make_compressor(method);
    if (!comp) {
        std::fprintf(stderr, "error: %s\n", error_str(comp.error()));
        return 1;
    }

    auto raw = read_file(in_path);
    auto xex = xebin::parse_xex(raw);
    if (!xex) {
        std::fprintf(stderr, "error: %s\n", error_str(xex.error()));
        return 1;
    }

    for (auto& seg : xex->segments) {
        auto result = (*comp)->compress(seg.data);
        if (!result) {
            std::fprintf(stderr, "error: %s\n", error_str(result.error()));
            return 1;
        }
        std::printf("  $%04X–$%04X  %zu → %zu bytes\n",
                    seg.load_addr, seg.end_addr(), seg.size(), result->size());
        seg.data = std::move(*result);
    }

    write_file(out_path, xebin::write_xex(*xex));
    return 0;
}

static int cmd_decompress(xebin::Method method,
                          const char* in_path, const char* out_path)
{
    auto comp = xebin::make_compressor(method);
    if (!comp) {
        std::fprintf(stderr, "error: %s\n", error_str(comp.error()));
        return 1;
    }

    auto raw = read_file(in_path);
    auto xex = xebin::parse_xex(raw);
    if (!xex) {
        std::fprintf(stderr, "error: %s\n", error_str(xex.error()));
        return 1;
    }

    for (auto& seg : xex->segments) {
        auto result = (*comp)->decompress(seg.data);
        if (!result) {
            std::fprintf(stderr, "error: %s\n", error_str(result.error()));
            return 1;
        }
        std::printf("  $%04X–$%04X  %zu → %zu bytes\n",
                    seg.load_addr, seg.end_addr(), seg.size(), result->size());
        seg.data = std::move(*result);
    }

    write_file(out_path, xebin::write_xex(*xex));
    return 0;
}

// ---------------------------------------------------------------------------
// Usage / main
// ---------------------------------------------------------------------------

static void usage(const char* argv0)
{
    std::fprintf(stderr,
        "Usage:\n"
        "  %s info   <input.xex>\n"
        "  %s compress   --method <rle|lz77|huffman>  <input.xex> <output.xex>\n"
        "  %s decompress --method <rle|lz77|huffman>  <input.xex> <output.xex>\n",
        argv0, argv0, argv0);
}

static xebin::Method parse_method(const char* s)
{
    if (std::strcmp(s, "rle")     == 0) return xebin::Method::RLE;
    if (std::strcmp(s, "lz77")    == 0) return xebin::Method::LZ77;
    if (std::strcmp(s, "huffman") == 0) return xebin::Method::Huffman;
    std::fprintf(stderr, "error: unknown method '%s'\n", s);
    std::exit(2);
}

int main(int argc, char* argv[])
{
    if (argc < 2) { usage(argv[0]); return 1; }

    const std::string cmd = argv[1];

    if (cmd == "info") {
        if (argc != 3) { usage(argv[0]); return 1; }
        return cmd_info(argv[2]);
    }

    if (cmd == "compress" || cmd == "decompress") {
        if (argc != 6 || std::strcmp(argv[2], "--method") != 0) {
            usage(argv[0]); return 1;
        }
        xebin::Method m = parse_method(argv[3]);
        if (cmd == "compress")
            return cmd_compress(m, argv[4], argv[5]);
        else
            return cmd_decompress(m, argv[4], argv[5]);
    }

    usage(argv[0]);
    return 1;
}
