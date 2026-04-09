#pragma once
#include "error.h"
#include "xex.h"
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace xebin {

// ---------------------------------------------------------------------------
// Diagnostic — out-of-band error/warning message with source location.
// Delivered via DiagnosticConsumer callback; return type stays Result<XEXFile>.
// ---------------------------------------------------------------------------

enum class DiagnosticSeverity { Warning, Error };

struct Diagnostic {
    DiagnosticSeverity severity = DiagnosticSeverity::Error;
    std::string        message;
    std::string        filename;
    int                line = 0;
};

using DiagnosticConsumer = std::function<void(const Diagnostic&)>;

// ---------------------------------------------------------------------------
// FileLoader — decouples the assembler from the filesystem.
// Called with a resolved filename (default extension .asx already appended).
// Return nullopt to signal "file not found".
// ---------------------------------------------------------------------------

using FileLoader = std::function<std::optional<std::vector<uint8_t>>(std::string_view)>;

// ---------------------------------------------------------------------------
// AssemblerOptions — mirrors the OPT directive and key CLI flags of xasm.
// ---------------------------------------------------------------------------

struct AssemblerOptions {
    bool fill         = false; // OPT f  / fill gaps with 0xFF
    bool atari5200    = false; // OPT g  / Atari 5200 GTIA/POKEY addresses
    bool headers      = true;  // OPT h  / emit XEX segment headers
    bool unusedLabels = true;  // OPT u  / warn on unused labels
};

// ---------------------------------------------------------------------------
// Assembler — two-pass 6502 assembler compatible with xasm 3.2.1 syntax.
// ---------------------------------------------------------------------------

class Assembler {
public:
    explicit Assembler(FileLoader loader = {}, DiagnosticConsumer consumer = {});
    ~Assembler();

    // Define a label before assembly (equivalent to xasm -d LABEL=VALUE).
    void define(std::string_view label, int value);

    // Assemble main_file (FileLoader is called to obtain source bytes).
    // Returns the assembled XEXFile on success, or Error::AssemblyFailed on error
    // (details delivered via the DiagnosticConsumer).
    Result<XEXFile> assemble(std::string_view main_file, AssemblerOptions opts = {});

    // Clear all state (definitions, source cache, label table).
    void reset();

private:
    struct Impl;
    std::unique_ptr<Impl> m_impl;
};

} // namespace xebin
