#include "xebin/assembler.h"
#include "xebin/compress.h"
#include "xebin/error.h"
#include "xebin/rle.h"
#include "xebin/xex.h"
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <string>
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
    case xebin::Error::AssemblyFailed:        return "assembly failed";
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
// xasm-compatible assembler command
// ---------------------------------------------------------------------------

static int cmd_asm(int argc, char* argv[])
{
    // Mirrors xasm option parsing:
    //   -d LABEL=VALUE  define a label
    //   -o FILENAME     output filename (default: source.obx)
    //   -u              warn on unused labels
    //   -f              fill gaps with 0xFF
    //   -g              Atari 5200 mode
    //   (listing / make options are not supported in the library)

    const char*  src_file    = nullptr;
    const char*  out_file    = nullptr;
    bool         warn_unused = false;
    bool         fill        = false;
    bool         atari5200   = false;
    std::vector<std::string> defines;

    for (int i = 0; i < argc; i++) {
        std::string arg = argv[i];
        auto is_opt = [&](char c) {
            return arg.size() >= 2 && arg[0] == '-' && (arg[1] == c || arg[1] == (c - 32));
        };
        if (is_opt('d')) {
            const char* def = nullptr;
            if (arg.size() > 2) def = argv[i] + 2;
            else if (i + 1 < argc) def = argv[++i];
            if (!def || !std::strchr(def, '=')) {
                std::fprintf(stderr, "error: -d requires LABEL=VALUE\n");
                return 1;
            }
            defines.push_back(def);
        } else if (is_opt('o')) {
            if (arg.size() > 2) out_file = argv[i] + 2;
            else if (i + 1 < argc) out_file = argv[++i];
            else { std::fprintf(stderr, "error: -o requires a filename\n"); return 1; }
        } else if (is_opt('u')) {
            warn_unused = true;
        } else if (is_opt('f')) {
            fill = true;
        } else if (is_opt('g')) {
            atari5200 = true;
        } else if (arg[0] == '-') {
            // silently ignore unrecognised flags (listing, make, etc.)
        } else {
            if (src_file) { std::fprintf(stderr, "error: multiple source files\n"); return 1; }
            src_file = argv[i];
        }
    }

    if (!src_file) {
        std::fprintf(stderr,
            "Usage: xebin asm SOURCE [OPTIONS]\n"
            "  -d LABEL=VALUE  define a label\n"
            "  -o FILENAME     output filename\n"
            "  -u              warn on unused labels\n"
            "  -f              fill memory gaps with 0xFF\n"
            "  -g              Atari 5200 mode\n");
        return 1;
    }

    // Determine output filename
    std::string out_path;
    if (out_file) {
        out_path = out_file;
    } else {
        out_path = std::filesystem::path(src_file).replace_extension(".obx").string();
    }

    // Set up FileLoader that reads from the filesystem
    auto loader = [](std::string_view name) -> std::optional<std::vector<uint8_t>> {
        std::ifstream f{std::string(name), std::ios::binary};
        if (!f) return std::nullopt;
        return std::vector<uint8_t>{std::istreambuf_iterator<char>(f), {}};
    };

    // Set up DiagnosticConsumer
    auto consumer = [](const xebin::Diagnostic& d) {
        std::fprintf(stderr, "%s (%d) %s: %s\n",
            d.filename.c_str(), d.line,
            d.severity == xebin::DiagnosticSeverity::Error ? "ERROR" : "WARNING",
            d.message.c_str());
    };

    xebin::Assembler asm_inst(loader, consumer);
    for (const auto& def : defines) {
        size_t eq = def.find('=');
        std::string label = def.substr(0, eq);
        int value = std::stoi(def.substr(eq + 1));
        asm_inst.define(label, value);
    }

    xebin::AssemblerOptions opts;
    opts.fill         = fill;
    opts.atari5200    = atari5200;
    opts.unusedLabels = warn_unused;

    auto result = asm_inst.assemble(src_file, opts);
    if (!result) {
        // Error already reported via consumer
        return 2;
    }

    write_file(out_path.c_str(), xebin::write_xex(*result));
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
        "  %s decompress --method <rle|lz77|huffman>  <input.xex> <output.xex>\n"
        "  %s asm    SOURCE [OPTIONS]\n",
        argv0, argv0, argv0, argv0);
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

    if (cmd == "asm") {
        return cmd_asm(argc - 2, argv + 2);
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
