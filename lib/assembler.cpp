// xasm 3.2.1 port to C++23 — faithful translation of app.d by Piotr Fusik.
// Global-state D code is restructured into Impl struct; public API exposed via
// Assembler class with PIMPL.  Listing and make-rule features are omitted.
#include "xebin/assembler.h"
#include "xebin/xex.h"
#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstring>
#include <map>
#include <numbers>
#include <string>
#include <vector>

namespace xebin {

// ---------------------------------------------------------------------------
// Internal exception (mirrors D's AssemblyError class).
// ---------------------------------------------------------------------------
struct AssemblyError {
    std::string msg;
    explicit AssemblyError(std::string m) : msg(std::move(m)) {}
};

// ---------------------------------------------------------------------------
// AddrMode constants — kept as int so arithmetic mirrors the D enum.
// ---------------------------------------------------------------------------
namespace AddrMode {
    constexpr int ACCUMULATOR   = 0;
    constexpr int IMMEDIATE     = 1;
    constexpr int ABSOLUTE      = 2;
    constexpr int ZEROPAGE      = 3;
    constexpr int ABSOLUTE_X    = 4;
    constexpr int ZEROPAGE_X    = 5;
    constexpr int ABSOLUTE_Y    = 6;
    constexpr int ZEROPAGE_Y    = 7;
    constexpr int INDIRECT_X    = 8;
    constexpr int INDIRECT_Y    = 9;
    constexpr int INDIRECT      = 10;
    constexpr int ABS_OR_ZP     = 11;
    constexpr int STANDARD_MASK = 15;
    constexpr int INCREMENT     = 0x20;
    constexpr int DECREMENT     = 0x30;
    constexpr int ZERO          = 0x40;
}

enum class OrgModifier { NONE, FORCE_HEADER, FORCE_FFFF, RELOCATE };

// ---------------------------------------------------------------------------
// Label
// ---------------------------------------------------------------------------
struct Label {
    int  value          = 0;
    bool unused         = true;
    bool unknownInPass1 = false;
    bool passed         = false;
    explicit Label(int v) : value(v) {}
};

// ---------------------------------------------------------------------------
// Expression parser stack entry
// ---------------------------------------------------------------------------
using OperatorFunction = int(*)(int, int);

struct ValOp {
    int              value    = 0;
    OperatorFunction func     = nullptr;
    int              priority = 0;
};

// ---------------------------------------------------------------------------
// Conditional assembly context
// ---------------------------------------------------------------------------
struct IfContext {
    bool condition          = false;
    bool wasElse            = false;
    bool aConditionMatched  = false;
};

// ===========================================================================
// Impl — all assembler state
// ===========================================================================
struct Assembler::Impl {
    // Injected callbacks
    FileLoader         m_loader;
    DiagnosticConsumer m_consumer;

    // Command-line definitions  (e.g. "FOO=42")
    std::vector<std::string> m_commandLineDefinitions;

    // Source file cache (filename → bytes)
    std::map<std::string, std::vector<uint8_t>> m_sourceFiles;

    // Pass flag
    bool m_pass2 = false;

    // Runtime options (reset each pass, then override from AssemblerOptions)
    bool m_optionFill          = false;
    bool m_option5200          = false;
    bool m_optionHeaders       = true;
    bool m_optionUnusedLabels  = true;

    // Current source location
    std::string m_currentFilename;
    int         m_lineNo       = 0;
    int         m_includeLevel = 0;
    std::string m_line;
    int         m_column       = 0;
    bool        m_foundEnd     = false;

    // Assembler location counters
    int m_origin        = -1;
    int m_loadOrigin    = -1;
    int m_loadingOrigin = -1;
    std::vector<uint16_t> m_blockEnds;
    int m_blockIndex = -1;

    // Repeat / skip / sequence state
    bool m_repeating            = false;
    int  m_repeatCounter        = 0;
    bool m_instructionBegin     = false;
    bool m_sequencing           = false;
    bool m_willSkip             = false;
    bool m_skipping             = false;
    std::vector<uint16_t> m_skipOffsets;
    int  m_skipOffsetsIndex     = 0;
    int  m_repeatOffset         = 0;
    bool m_wereManyInstructions = false;
    bool m_inOpcode             = false;

    // Label table
    std::map<std::string, std::unique_ptr<Label>> m_labelTable;
    Label*      m_currentLabel     = nullptr;
    std::string m_lastGlobalLabel;

    // Expression parser state
    std::vector<ValOp> m_valOpStack;
    int  m_value          = 0;
    bool m_unknownInPass1 = false;

    // Addressing mode and move-instruction temporaries
    int m_addrMode  = AddrMode::ACCUMULATOR;
    int m_value1    = 0;
    int m_addrMode1 = 0;
    int m_value2    = 0;
    int m_addrMode2 = 0;

    // Conditional assembly stack
    std::vector<IfContext> m_ifContexts;

    // Object output (pass2 only)
    std::vector<uint8_t> m_objectBuffer;

    // Statistics
    int m_totalLines = 0;

    // DTA real-number temporaries
    bool      m_realSign     = false;
    int       m_realExponent = 0;
    long long m_realMantissa = 0;

    // Options snapshot for the current assemble() call
    AssemblerOptions m_opts;

    // -----------------------------------------------------------------------
    explicit Impl(FileLoader loader, DiagnosticConsumer consumer)
        : m_loader(std::move(loader)), m_consumer(std::move(consumer)) {}

    // -----------------------------------------------------------------------
    // Diagnostics
    // -----------------------------------------------------------------------
    void warning(const std::string& msg, bool isError = false) {
        if (m_consumer) {
            Diagnostic d;
            d.severity = isError ? DiagnosticSeverity::Error : DiagnosticSeverity::Warning;
            d.message  = msg;
            d.filename = m_currentFilename;
            d.line     = m_lineNo;
            m_consumer(d);
        }
    }

    [[noreturn]] void illegalCharacter() {
        throw AssemblyError("Illegal character");
    }

    // -----------------------------------------------------------------------
    // Low-level character I/O
    // -----------------------------------------------------------------------
    bool eol() const { return m_column >= (int)m_line.size(); }

    char readChar() {
        if (eol()) throw AssemblyError("Unexpected end of line");
        return m_line[m_column++];
    }

    int readDigit(int base) {
        if (eol()) return -1;
        int r = (unsigned char)m_line[m_column];
        if (r >= '0' && r <= '9') r -= '0';
        else {
            r &= 0xdf;
            if (r >= 'A' && r <= 'Z') r -= ('A' - 10);
            else return -1;
        }
        if (r < base) { m_column++; return r; }
        return -1;
    }

    int readNumber(int base) {
        long long r = readDigit(base);
        if (r < 0) illegalCharacter();
        do {
            int d = readDigit(base);
            if (d < 0) return (int)r;
            r = r * base + d;
        } while (r <= 0x7fffffffLL);
        throw AssemblyError("Number too big");
    }

    void readSpaces() {
        char c = readChar();
        if (c != '\t' && c != ' ')
            throw AssemblyError("Space expected");
        while (!eol() && (m_line[m_column] == '\t' || m_line[m_column] == ' '))
            m_column++;
    }

    std::string readLabel() {
        int first = m_column;
        while (!eol()) {
            char c = m_line[m_column++];
            if ((c >= '0' && c <= '9') || c == '_' || c == '?') continue;
            c &= 0xdf;
            if (c >= 'A' && c <= 'Z') continue;
            m_column--;
            break;
        }
        std::string label = m_line.substr(first, m_column - first);
        for (char& ch : label) if (ch >= 'a' && ch <= 'z') ch -= 32;
        if (!label.empty() && label[0] == '?') {
            if (m_lastGlobalLabel.empty())
                throw AssemblyError("Global label must be declared first");
            label = m_lastGlobalLabel + label;
        }
        return label >= "A" ? label : std::string{};
    }

    void readComma() {
        if (readChar() != ',') throw AssemblyError("Bad or missing function parameter");
    }

    std::string readInstruction() {
        std::string r;
        for (int i = 0; i < 3; i++) {
            char c = readChar() & 0xdf;
            if (c < 'A' || c > 'Z') throw AssemblyError("Illegal instruction");
            r += c;
        }
        return r;
    }

    // Peek at next 3 chars + '(' for function name (e.g. "SIN(")
    std::string readFunction() {
        if (m_column + 4 > (int)m_line.size()) return {};
        if (m_line[m_column + 3] != '(') return {};
        std::string r;
        for (int i = 0; i < 3; i++) {
            char c = m_line[m_column + i] & 0xdf;
            if (c < 'A' || c > 'Z') return {};
            r += c;
        }
        m_column += 4;
        return r;
    }

    std::string readFilename() {
        readSpaces();
        char delim = readChar();
        if (delim != '"' && delim != '\'') illegalCharacter();
        std::string fn;
        char c;
        while ((c = readChar()) != delim) fn += c;
        return fn;
    }

    void readStringChar(char c) {
        if (readChar() != c) throw AssemblyError("String error");
    }

    // Read a quoted string for DTA C/D directives.
    // Returns true if a string was found and populates `out`.
    // Returns false (column unchanged) if no string delimiter at current position.
    // Caller must do m_column-- afterwards to restore to before the type letter.
    bool readStringFromDta(std::vector<uint8_t>& out) {
        if (eol()) return false;
        char delim = m_line[m_column];
        if (delim != '"' && delim != '\'') return false;
        m_column++;
        out.clear();
        for (;;) {
            char c = readChar();
            if (c == delim) {
                if (eol()) return true;
                if (m_line[m_column] != delim) {
                    if (m_line[m_column] == '*') {
                        m_column++;
                        for (auto& b : out) b ^= 0x80;
                    }
                    return true;
                }
                m_column++;
            }
            out.push_back((uint8_t)c);
        }
    }

    void checkNoExtraCharacters() {
        if (eol()) return;
        char c = m_line[m_column];
        if (c == '\t' || c == ' ') return;
        throw AssemblyError("Extra characters on line");
    }

    void checkOriginDefined() {
        if (m_origin < 0) throw AssemblyError("No ORG specified");
    }

    // -----------------------------------------------------------------------
    // Operator functions (free functions stored as function pointers)
    // -----------------------------------------------------------------------
    static int opPlus  (int, int b) { return b; }
    static int opMinus (int, int b) { return -b; }
    static int opLow   (int, int b) { return b & 0xff; }
    static int opHigh  (int, int b) { return (b >> 8) & 0xff; }
    static int opLogNot(int, int b) { return !b; }
    static int opBitNot(int, int b) { return ~b; }

    static int opAdd(int a, int b) {
        long long r = (long long)a + b;
        if (r < -0x80000000LL || r > 0x7fffffffLL) throw AssemblyError("Arithmetic overflow");
        return a + b;
    }
    static int opSub(int a, int b) {
        long long r = (long long)a - b;
        if (r < -0x80000000LL || r > 0x7fffffffLL) throw AssemblyError("Arithmetic overflow");
        return a - b;
    }
    static int opMul(int a, int b) {
        long long r = (long long)a * b;
        if (r < -0x80000000LL || r > 0x7fffffffLL) throw AssemblyError("Arithmetic overflow");
        return a * b;
    }
    static int opDiv(int a, int b) {
        if (b == 0) throw AssemblyError("Divide by zero");
        return a / b;
    }
    static int opMod(int a, int b) {
        if (b == 0) throw AssemblyError("Divide by zero");
        return a % b;
    }
    static int opAnd   (int a, int b) { return a & b; }
    static int opOr    (int a, int b) { return a | b; }
    static int opXor   (int a, int b) { return a ^ b; }
    static int opEq    (int a, int b) { return a == b; }
    static int opNe    (int a, int b) { return a != b; }
    static int opLt    (int a, int b) { return a < b; }
    static int opGt    (int a, int b) { return a > b; }
    static int opLe    (int a, int b) { return a <= b; }
    static int opGe    (int a, int b) { return a >= b; }
    static int opLogAnd(int a, int b) { return a && b; }
    static int opLogOr (int a, int b) { return a || b; }

    static int opShl(int a, int b) {
        if (b < 0) return opShr(a, -b);
        if (a != 0 && b >= 32) throw AssemblyError("Arithmetic overflow");
        long long r = (long long)a << b;
        if (r & 0xffffffff00000000LL) throw AssemblyError("Arithmetic overflow");
        return a << b;
    }
    static int opShr(int a, int b) {
        if (b < 0) return opShl(a, -b);
        if (b >= 32) b = 31;
        return a >> b;
    }

    // -----------------------------------------------------------------------
    // Expression parser
    // -----------------------------------------------------------------------
    void pushValOp(int v, OperatorFunction f, int priority) {
        m_valOpStack.push_back({v, f, priority});
    }

    void readValue();
    void mustBeKnownInPass1() {
        if (m_unknownInPass1) throw AssemblyError("Label not defined before");
    }
    void readWord() {
        readValue();
        if ((!m_unknownInPass1 || m_pass2) && (m_value < -0xffff || m_value > 0xffff))
            throw AssemblyError("Value out of range");
    }
    void readUnsignedWord() {
        readWord();
        if ((!m_unknownInPass1 || m_pass2) && m_value < 0)
            throw AssemblyError("Value out of range");
    }
    void readKnownPositive() {
        readValue();
        mustBeKnownInPass1();
        if (m_value <= 0) throw AssemblyError("Value out of range");
    }

    // -----------------------------------------------------------------------
    // Addressing mode parser
    // -----------------------------------------------------------------------
    void optionalIncDec() {
        if (eol()) return;
        if (m_line[m_column] == '+') { m_column++; m_addrMode += AddrMode::INCREMENT; }
        else if (m_line[m_column] == '-') { m_column++; m_addrMode += AddrMode::DECREMENT; }
    }

    void readAddrMode();
    void readAbsoluteAddrMode() {
        if (m_inOpcode && readChar() == '}') { m_column--; }
        else {
            readAddrMode();
            if (m_addrMode != AddrMode::ABSOLUTE && m_addrMode != AddrMode::ZEROPAGE)
                illegalAddrMode();
        }
        m_addrMode = AddrMode::ABSOLUTE;
    }
    [[noreturn]] void illegalAddrMode() { throw AssemblyError("Illegal addressing mode"); }

    // -----------------------------------------------------------------------
    // Output helpers
    // -----------------------------------------------------------------------
    void objectByte(uint8_t b) { if (m_pass2) m_objectBuffer.push_back(b); }
    void objectWord(uint16_t w) { objectByte((uint8_t)w); objectByte((uint8_t)(w >> 8)); }

    void putByte(uint8_t b);
    void putWord(uint16_t w) { putByte((uint8_t)w); putByte((uint8_t)(w >> 8)); }
    void putCommand(uint8_t b);

    // -----------------------------------------------------------------------
    // Instruction helpers
    // -----------------------------------------------------------------------
    using MoveFunction = void(Impl::*)(int);

    void noOpcode() { if (m_inOpcode) throw AssemblyError("Can't get opcode of this"); }
    void directive() {
        noOpcode();
        if (m_repeating)  throw AssemblyError("Can't repeat this directive");
        if (m_sequencing) throw AssemblyError("Can't pair this directive");
    }
    void noRepeatSkipDirective() {
        directive();
        if (m_willSkip) throw AssemblyError("Can't skip over this");
        m_repeatOffset = 0;
    }

    void addrModeForMove(int move) {
        if (move == 0) readAddrMode();
        else if (move == 1) { m_value = m_value1; m_addrMode = m_addrMode1; }
        else                { m_value = m_value2; m_addrMode = m_addrMode2; }
    }

    void assemblyAccumulator(uint8_t b, uint8_t prefix, int move);
    void assemblyShift(uint8_t b);
    void assemblyCompareIndex(uint8_t b);
    void assemblyLda(int move) { assemblyAccumulator(0xa0, 0,    move); }
    void assemblyLdx(int move);
    void assemblyLdy(int move);
    void assemblySta(int move) { assemblyAccumulator(0x80, 0,    move); }
    void assemblyStx(int move);
    void assemblySty(int move);
    void assemblyBit();
    void putJump();
    void assemblyJmp();
    void assemblyConditionalJump(uint8_t b);
    void assemblyJsr();
    uint8_t calculateBranch(int offset);
    void assemblyBranch(uint8_t b);
    void assemblyRepeat(uint8_t b);
    void assemblySkip(uint8_t b);
    void assemblyInw();
    void assemblyMove();
    void assemblyMoveByte(MoveFunction load, MoveFunction store);
    void assemblyMoveWord(MoveFunction load, MoveFunction store, uint8_t inc, uint8_t dec);

    // DTA
    void storeDtaNumber(int val, char letter);
    void assemblyDtaInteger(char letter);
    bool readSign();
    void readExponent();
    void readFraction();
    void putReal();
    void assemblyDtaReal();
    void assemblyDtaNumbers(char letter);
    void assemblyDta();

    // Directives
    void assemblyEqu();
    void assemblyEnd();
    void assemblyIftEli();
    void checkMissingIft();
    void assemblyIft();
    void assemblyEliEls();
    void assemblyEli();
    void assemblyEls();
    void assemblyEif();
    void assemblyErt();
    bool readOptionFlag();
    void assemblyOpt();

    // Origin / segment headers
    OrgModifier readOrgModifier();
    void setOrigin(int addr, OrgModifier modifier);
    void checkHeadersOn();
    void assemblyOrg();
    void assemblyRunIni(uint16_t addr);

    // Includes / binary inserts
    void assemblyIcl();
    void assemblyIns();

    // Main assembly loop
    void assemblyInstruction(const std::string& instr);
    void assemblySequence();
    void assemblyLine();
    void assemblyFile(const std::string& filename);
    void assemblyPass(const std::string& mainFile);

    bool inFalseCondition() const {
        for (const auto& ic : m_ifContexts)
            if (!ic.condition) return true;
        return false;
    }

    const std::vector<uint8_t>& getSource(const std::string& filename);
};

// ===========================================================================
// readValue — expression parser (mirrors D's readValue)
// ===========================================================================
void Assembler::Impl::readValue()
{
    assert(m_valOpStack.empty());
    m_unknownInPass1 = false;
    int priority = 0;

    do {
        int operand = 0;
        char c = readChar();
        switch (c) {
        case '[':
            priority += 10;
            continue;
        case '+': pushValOp(0, &opPlus,   priority + 8); continue;
        case '-': pushValOp(0, &opMinus,  priority + 8); continue;
        case '<': pushValOp(0, &opLow,    priority + 8); continue;
        case '>': pushValOp(0, &opHigh,   priority + 8); continue;
        case '!': pushValOp(0, &opLogNot, priority + 4); continue;
        case '~': pushValOp(0, &opBitNot, priority + 8); continue;
        case '(':
            throw AssemblyError("Use square brackets instead");
        case '*':
            checkOriginDefined();
            operand = m_origin;
            break;
        case '#':
            if (!m_repeating) throw AssemblyError("'#' is allowed only in repeated lines");
            operand = m_repeatCounter;
            break;
        case '\'': case '"': {
            operand = readChar();
            if (operand == c) readStringChar((char)c);
            readStringChar((char)c);
            if (!eol() && m_line[m_column] == '*') { m_column++; operand ^= 0x80; }
            break;
        }
        case '^': {
            char d2 = readChar();
            switch (d2) {
            case '0': operand = m_option5200 ? 0xc000 : 0xd000; break;
            case '1': operand = m_option5200 ? 0xc010 : 0xd010; break;
            case '2': operand = m_option5200 ? 0xe800 : 0xd200; break;
            case '3':
                if (m_option5200) throw AssemblyError("There's no PIA chip in Atari 5200");
                operand = 0xd300; break;
            case '4': operand = 0xd400; break;
            default:  illegalCharacter();
            }
            int d = readDigit(16);
            if (d < 0) illegalCharacter();
            operand += d;
            break;
        }
        case '{': {
            if (m_inOpcode) throw AssemblyError("Nested opcodes not supported");
            auto savedStack     = m_valOpStack;
            int  savedAddrMode  = m_addrMode;
            bool savedUnknown   = m_unknownInPass1;
            bool savedInstrBegin= m_instructionBegin;
            m_valOpStack.clear();
            m_inOpcode = true;
            assemblyInstruction(readInstruction());
            if (readChar() != '}') throw AssemblyError("Missing '}'");
            assert(!m_instructionBegin);
            m_inOpcode          = false;
            m_valOpStack        = savedStack;
            m_addrMode          = savedAddrMode;
            m_unknownInPass1    = savedUnknown;
            m_instructionBegin  = savedInstrBegin;
            operand = m_value;
            break;
        }
        case '$': operand = readNumber(16); break;
        case '%': operand = readNumber(2);  break;
        default:
            m_column--;
            if (c >= '0' && c <= '9') { operand = readNumber(10); break; }
            {
                std::string label = readLabel();
                if (label.empty()) illegalCharacter();
                auto it = m_labelTable.find(label);
                if (it != m_labelTable.end()) {
                    Label* l = it->second.get();
                    operand = l->value;
                    l->unused = false;
                    if (m_pass2) {
                        if (l->passed) {
                            if (l->unknownInPass1) m_unknownInPass1 = true;
                        } else {
                            if (l->unknownInPass1) throw AssemblyError("Illegal forward reference");
                            m_unknownInPass1 = true;
                        }
                    } else {
                        if (l->unknownInPass1) m_unknownInPass1 = true;
                    }
                } else {
                    if (m_pass2) throw AssemblyError("Undeclared label: " + label);
                    m_unknownInPass1 = true;
                }
            }
            break;
        }

        // Close square brackets
        while (!eol() && m_line[m_column] == ']') {
            m_column++;
            priority -= 10;
            if (priority < 0) throw AssemblyError("Unmatched bracket");
        }

        // Push the operand with the following binary operator
        if (eol()) {
            if (priority != 0) throw AssemblyError("Unmatched bracket");
            pushValOp(operand, &opPlus, 1);
        } else {
            char op = m_line[m_column++];
            switch (op) {
            case '+': pushValOp(operand, &opAdd, priority + 6); break;
            case '-': pushValOp(operand, &opSub, priority + 6); break;
            case '*': pushValOp(operand, &opMul, priority + 7); break;
            case '/': pushValOp(operand, &opDiv, priority + 7); break;
            case '%': pushValOp(operand, &opMod, priority + 7); break;
            case '<': {
                char c2 = readChar();
                if      (c2 == '<') pushValOp(operand, &opShl, priority + 7);
                else if (c2 == '=') pushValOp(operand, &opLe,  priority + 5);
                else if (c2 == '>') pushValOp(operand, &opNe,  priority + 5);
                else { m_column--; pushValOp(operand, &opLt, priority + 5); }
                break;
            }
            case '=': {
                char c2 = readChar();
                if (c2 != '=') m_column--;
                pushValOp(operand, &opEq, priority + 5);
                break;
            }
            case '>': {
                char c2 = readChar();
                if      (c2 == '>') pushValOp(operand, &opShr, priority + 7);
                else if (c2 == '=') pushValOp(operand, &opGe,  priority + 5);
                else { m_column--; pushValOp(operand, &opGt, priority + 5); }
                break;
            }
            case '!': {
                char c2 = readChar();
                if (c2 == '=') pushValOp(operand, &opNe, priority + 5);
                else illegalCharacter();
                break;
            }
            case '&': {
                char c2 = readChar();
                if (c2 == '&') pushValOp(operand, &opLogAnd, priority + 3);
                else { m_column--; pushValOp(operand, &opAnd, priority + 7); }
                break;
            }
            case '|': {
                char c2 = readChar();
                if (c2 == '|') pushValOp(operand, &opLogOr, priority + 2);
                else { m_column--; pushValOp(operand, &opOr, priority + 6); }
                break;
            }
            case '^':
                pushValOp(operand, &opXor, priority + 6);
                break;
            default:
                m_column--;
                if (priority != 0) throw AssemblyError("Unmatched bracket");
                pushValOp(operand, &opPlus, 1);
                break;
            }
        }

        // Reduce: collapse entries with decreasing priority
        for (;;) {
            int sp = (int)m_valOpStack.size() - 1;
            if (sp <= 0 || m_valOpStack[sp].priority > m_valOpStack[sp - 1].priority)
                break;
            int              op1 = m_valOpStack[sp - 1].value;
            OperatorFunction f1  = m_valOpStack[sp - 1].func;
            m_valOpStack[sp - 1] = m_valOpStack[sp];
            m_valOpStack.pop_back();
            if (m_pass2 || !m_unknownInPass1)
                m_valOpStack.back().value = f1(op1, m_valOpStack.back().value);
        }
    } while (m_valOpStack.size() != 1 || m_valOpStack[0].priority != 1);

    m_value = m_valOpStack[0].value;
    m_valOpStack.clear();
}

// ===========================================================================
// readAddrMode
// ===========================================================================
void Assembler::Impl::readAddrMode()
{
    readSpaces();
    char c = readChar();
    switch (c) {
    case '@':
        m_addrMode = AddrMode::ACCUMULATOR;
        return;
    case '#': case '<': case '>':
        m_addrMode = AddrMode::IMMEDIATE;
        if (m_inOpcode && !eol() && m_line[m_column] == '}') return;
        readWord();
        if (c == '<') m_value &= 0xff;
        else if (c == '>') m_value = (m_value >> 8) & 0xff;
        return;
    case '(':
        if (m_inOpcode) {
            char c2 = readChar();
            if (c2 == ',') {
                char c3 = readChar();
                if (c3 != 'X' && c3 != 'x') illegalCharacter();
                if (readChar() != ')') throw AssemblyError("Need parenthesis");
                m_addrMode = AddrMode::INDIRECT_X;
                return;
            }
            if (c2 == ')') {
                char c3 = readChar();
                if (c3 == ',') {
                    char c4 = readChar();
                    if (c4 != 'Y' && c4 != 'y') illegalCharacter();
                    m_addrMode = AddrMode::INDIRECT_Y;
                    return;
                }
                m_column--;
                m_addrMode = AddrMode::INDIRECT;
                return;
            }
            m_column--;
        }
        readUnsignedWord();
        {
            char c2 = readChar();
            if (c2 == ',') {
                char c3 = readChar();
                if      (c3 == 'X' || c3 == 'x') m_addrMode = AddrMode::INDIRECT_X;
                else if (c3 == '0')               m_addrMode = AddrMode::INDIRECT_X + AddrMode::ZERO;
                else illegalCharacter();
                if (readChar() != ')') throw AssemblyError("Need parenthesis");
            } else if (c2 == ')') {
                if (eol()) { m_addrMode = AddrMode::INDIRECT; return; }
                if (m_line[m_column] == ',') {
                    m_column++;
                    char c3 = readChar();
                    if      (c3 == 'Y' || c3 == 'y') m_addrMode = AddrMode::INDIRECT_Y;
                    else if (c3 == '0')               m_addrMode = AddrMode::INDIRECT_Y + AddrMode::ZERO;
                    else illegalCharacter();
                    optionalIncDec();
                } else {
                    m_addrMode = AddrMode::INDIRECT;
                }
            } else {
                illegalCharacter();
            }
        }
        return;
    case 'A': case 'a':
        if (!eol() && m_line[m_column] == ':') { m_column++; m_addrMode = AddrMode::ABSOLUTE; }
        else { m_addrMode = AddrMode::ABS_OR_ZP; m_column--; }
        break;
    case 'Z': case 'z':
        if (!eol() && m_line[m_column] == ':') { m_column++; m_addrMode = AddrMode::ZEROPAGE; }
        else { m_addrMode = AddrMode::ABS_OR_ZP; m_column--; }
        break;
    default:
        m_addrMode = AddrMode::ABS_OR_ZP;
        m_column--;
        break;
    }

    // Absolute or zero-page, optionally indexed
    if (m_inOpcode && (m_addrMode == AddrMode::ABSOLUTE || m_addrMode == AddrMode::ZEROPAGE)) {
        char c2 = readChar();
        if (c2 == '}') { m_column--; return; }
        if (c2 == ',') {
            char c3 = readChar();
            if      (c3 == 'X' || c3 == 'x') m_addrMode += AddrMode::ABSOLUTE_X - AddrMode::ABSOLUTE;
            else if (c3 == 'Y' || c3 == 'y') m_addrMode += AddrMode::ABSOLUTE_Y - AddrMode::ABSOLUTE;
            else illegalCharacter();
            return;
        }
        m_column--;
    }

    readUnsignedWord();
    if (m_addrMode == AddrMode::ABS_OR_ZP) {
        m_addrMode = (m_unknownInPass1 || m_value > 0xff)
            ? AddrMode::ABSOLUTE : AddrMode::ZEROPAGE;
    }
    if (eol()) return;
    if (m_line[m_column] == ',') {
        m_column++;
        char c2 = readChar();
        if (c2 == 'X' || c2 == 'x') {
            m_addrMode += AddrMode::ABSOLUTE_X - AddrMode::ABSOLUTE;
            optionalIncDec();
        } else if (c2 == 'Y' || c2 == 'y') {
            m_addrMode += AddrMode::ABSOLUTE_Y - AddrMode::ABSOLUTE;
            optionalIncDec();
        } else {
            illegalCharacter();
        }
    }
}

// ===========================================================================
// putByte / putCommand
// ===========================================================================
void Assembler::Impl::putByte(uint8_t b)
{
    if (m_inOpcode) {
        if (m_instructionBegin) { m_value = b; m_instructionBegin = false; }
        return;
    }
    if (m_willSkip) { m_willSkip = false; m_skipping = true; }
    if (m_skipping) { assert(!m_pass2); m_skipOffsets.back()++; }
    if (m_instructionBegin) { m_repeatOffset = -2; m_instructionBegin = false; }
    m_repeatOffset--;

    if (m_optionFill && m_loadingOrigin >= 0 && m_loadingOrigin != m_loadOrigin) {
        if (m_loadingOrigin > m_loadOrigin)
            throw AssemblyError("Can't fill from higher to lower memory location");
        if (m_pass2) {
            while (m_loadingOrigin < m_loadOrigin) {
                objectByte(0xff);
                m_loadingOrigin++;
            }
        }
    }

    if (m_pass2) objectByte(b);

    if (m_optionHeaders) {
        if (m_origin < 0) throw AssemblyError("No ORG specified");
        assert(m_blockIndex >= 0);
        if (!m_pass2) m_blockEnds[m_blockIndex] = (uint16_t)m_loadOrigin;
    }
    if (m_origin >= 0) {
        m_origin++;
        m_loadingOrigin = ++m_loadOrigin;
    }
}

void Assembler::Impl::putCommand(uint8_t b)
{
    putByte(b);
    if (m_inOpcode) return;
    switch (m_addrMode & AddrMode::STANDARD_MASK) {
    case AddrMode::ACCUMULATOR:
        break;
    case AddrMode::IMMEDIATE:
    case AddrMode::ZEROPAGE:
    case AddrMode::ZEROPAGE_X:
    case AddrMode::ZEROPAGE_Y:
    case AddrMode::INDIRECT_X:
    case AddrMode::INDIRECT_Y:
        if (m_pass2 && (m_value < -0xff || m_value > 0xff))
            throw AssemblyError("Value out of range");
        putByte((uint8_t)m_value);
        break;
    case AddrMode::ABSOLUTE:
    case AddrMode::ABSOLUTE_X:
    case AddrMode::ABSOLUTE_Y:
    case AddrMode::INDIRECT:
        putWord((uint16_t)m_value);
        break;
    default:
        assert(0);
    }
    switch (m_addrMode) {
    case AddrMode::ABSOLUTE_X + AddrMode::INCREMENT:
    case AddrMode::ZEROPAGE_X + AddrMode::INCREMENT:  putByte(0xe8); break;
    case AddrMode::ABSOLUTE_X + AddrMode::DECREMENT:
    case AddrMode::ZEROPAGE_X + AddrMode::DECREMENT:  putByte(0xca); break;
    case AddrMode::ABSOLUTE_Y + AddrMode::INCREMENT:
    case AddrMode::ZEROPAGE_Y + AddrMode::INCREMENT:
    case AddrMode::INDIRECT_Y + AddrMode::INCREMENT:
    case AddrMode::INDIRECT_Y + AddrMode::INCREMENT + AddrMode::ZERO: putByte(0xc8); break;
    case AddrMode::ABSOLUTE_Y + AddrMode::DECREMENT:
    case AddrMode::ZEROPAGE_Y + AddrMode::DECREMENT:
    case AddrMode::INDIRECT_Y + AddrMode::DECREMENT:
    case AddrMode::INDIRECT_Y + AddrMode::DECREMENT + AddrMode::ZERO: putByte(0x88); break;
    default: break;
    }
}

// ===========================================================================
// Instruction assemblers
// ===========================================================================
void Assembler::Impl::assemblyAccumulator(uint8_t b, uint8_t prefix, int move)
{
    addrModeForMove(move);
    if (prefix) putByte(prefix);
    switch (m_addrMode & AddrMode::STANDARD_MASK) {
    case AddrMode::ACCUMULATOR: illegalAddrMode();
    case AddrMode::INDIRECT:    illegalAddrMode();
    case AddrMode::IMMEDIATE:
        if (b == 0x80) illegalAddrMode(); // STA #
        putCommand((uint8_t)(b + 9));
        break;
    case AddrMode::ABSOLUTE:    putCommand((uint8_t)(b + 0xd));  break;
    case AddrMode::ZEROPAGE:    putCommand((uint8_t)(b + 5));    break;
    case AddrMode::ABSOLUTE_X:  putCommand((uint8_t)(b + 0x1d)); break;
    case AddrMode::ZEROPAGE_X:  putCommand((uint8_t)(b + 0x15)); break;
    case AddrMode::ZEROPAGE_Y:
        m_addrMode--;   // ZEROPAGE_Y(7) → ABSOLUTE_Y(6)
        [[fallthrough]];
    case AddrMode::ABSOLUTE_Y:  putCommand((uint8_t)(b + 0x19)); break;
    case AddrMode::INDIRECT_X:
        if (m_addrMode & AddrMode::ZERO) putWord(0x00a2);
        putCommand((uint8_t)(b + 1));
        break;
    case AddrMode::INDIRECT_Y:
        if (m_addrMode & AddrMode::ZERO) putWord(0x00a0);
        putCommand((uint8_t)(b + 0x11));
        break;
    default: assert(0);
    }
}

void Assembler::Impl::assemblyShift(uint8_t b)
{
    readAddrMode();
    switch (m_addrMode & AddrMode::STANDARD_MASK) {
    case AddrMode::ACCUMULATOR:
        if (b == 0xc0 || b == 0xe0) illegalAddrMode();
        putByte((uint8_t)(b + 0xa));
        break;
    case AddrMode::ABSOLUTE:   putCommand((uint8_t)(b + 0xe));  break;
    case AddrMode::ZEROPAGE:   putCommand((uint8_t)(b + 6));    break;
    case AddrMode::ABSOLUTE_X: putCommand((uint8_t)(b + 0x1e)); break;
    case AddrMode::ZEROPAGE_X: putCommand((uint8_t)(b + 0x16)); break;
    default: illegalAddrMode();
    }
}

void Assembler::Impl::assemblyCompareIndex(uint8_t b)
{
    readAddrMode();
    switch (m_addrMode) {
    case AddrMode::IMMEDIATE: putCommand(b);                   break;
    case AddrMode::ABSOLUTE:  putCommand((uint8_t)(b + 0xc)); break;
    case AddrMode::ZEROPAGE:  putCommand((uint8_t)(b + 4));   break;
    default: illegalAddrMode();
    }
}

void Assembler::Impl::assemblyLdx(int move)
{
    addrModeForMove(move);
    switch (m_addrMode & AddrMode::STANDARD_MASK) {
    case AddrMode::IMMEDIATE:  putCommand(0xa2); break;
    case AddrMode::ABSOLUTE:   putCommand(0xae); break;
    case AddrMode::ZEROPAGE:   putCommand(0xa6); break;
    case AddrMode::ABSOLUTE_Y: putCommand(0xbe); break;
    case AddrMode::ZEROPAGE_Y: putCommand(0xb6); break;
    default: illegalAddrMode();
    }
}

void Assembler::Impl::assemblyLdy(int move)
{
    addrModeForMove(move);
    switch (m_addrMode & AddrMode::STANDARD_MASK) {
    case AddrMode::IMMEDIATE:  putCommand(0xa0); break;
    case AddrMode::ABSOLUTE:   putCommand(0xac); break;
    case AddrMode::ZEROPAGE:   putCommand(0xa4); break;
    case AddrMode::ABSOLUTE_X: putCommand(0xbc); break;
    case AddrMode::ZEROPAGE_X: putCommand(0xb4); break;
    default: illegalAddrMode();
    }
}

void Assembler::Impl::assemblyStx(int move)
{
    addrModeForMove(move);
    switch (m_addrMode & AddrMode::STANDARD_MASK) {
    case AddrMode::ABSOLUTE:   putCommand(0x8e); break;
    case AddrMode::ZEROPAGE:   putCommand(0x86); break;
    case AddrMode::ABSOLUTE_Y:
        m_addrMode++;   // ABSOLUTE_Y(6) → ZEROPAGE_Y(7)
        [[fallthrough]];
    case AddrMode::ZEROPAGE_Y: putCommand(0x96); break;
    default: illegalAddrMode();
    }
}

void Assembler::Impl::assemblySty(int move)
{
    addrModeForMove(move);
    switch (m_addrMode & AddrMode::STANDARD_MASK) {
    case AddrMode::ABSOLUTE:   putCommand(0x8c); break;
    case AddrMode::ZEROPAGE:   putCommand(0x84); break;
    case AddrMode::ABSOLUTE_X:
        m_addrMode++;   // ABSOLUTE_X(4) → ZEROPAGE_X(5)
        [[fallthrough]];
    case AddrMode::ZEROPAGE_X: putCommand(0x94); break;
    default: illegalAddrMode();
    }
}

void Assembler::Impl::assemblyBit()
{
    readAddrMode();
    switch (m_addrMode) {
    case AddrMode::ABSOLUTE: putCommand(0x2c); break;
    case AddrMode::ZEROPAGE: putCommand(0x24); break;
    default: illegalAddrMode();
    }
}

void Assembler::Impl::putJump()
{
    switch (m_addrMode) {
    case AddrMode::ZEROPAGE:
        m_addrMode = AddrMode::ABSOLUTE;
        [[fallthrough]];
    case AddrMode::ABSOLUTE:
        putCommand(0x4c);
        break;
    case AddrMode::INDIRECT:
        if (m_pass2 && (m_value & 0xff) == 0xff)
            warning("Buggy indirect jump");
        putCommand(0x6c);
        break;
    default: illegalAddrMode();
    }
}

void Assembler::Impl::assemblyJmp()
{
    readAddrMode();
    putJump();
}

void Assembler::Impl::assemblyConditionalJump(uint8_t b)
{
    noOpcode();
    readAddrMode();
    if ((m_addrMode == AddrMode::ABSOLUTE || m_addrMode == AddrMode::ZEROPAGE)
        && m_pass2 && m_origin >= 0
        && m_value - m_origin - 2 >= -0x80 && m_value - m_origin - 2 <= 0x7f)
        warning("Plain branch instruction would be sufficient");
    putByte(b);
    putByte(3);
    putJump();
}

void Assembler::Impl::assemblyJsr()
{
    readAbsoluteAddrMode();
    putCommand(0x20);
}

uint8_t Assembler::Impl::calculateBranch(int offset)
{
    if (offset < -0x80 || offset > 0x7f) {
        int dist = offset < 0 ? -offset - 0x80 : offset - 0x7f;
        throw AssemblyError("Branch out of range by " + std::to_string(dist) + " bytes");
    }
    return (uint8_t)offset;
}

void Assembler::Impl::assemblyBranch(uint8_t b)
{
    readAbsoluteAddrMode();
    if (m_inOpcode) { putByte(b); return; }
    checkOriginDefined();
    putByte(b);
    putByte(m_pass2 ? calculateBranch(m_value - m_origin - 1) : 0);
}

void Assembler::Impl::assemblyRepeat(uint8_t b)
{
    noOpcode();
    int offset = m_repeatOffset;
    if (offset >= 0) throw AssemblyError("No instruction to repeat");
    if (m_pass2 && m_wereManyInstructions) warning("Repeating only the last instruction");
    putByte(b);
    putByte(calculateBranch(offset));
}

void Assembler::Impl::assemblySkip(uint8_t b)
{
    noOpcode();
    if (m_willSkip) { m_skipOffsets.back() = 2; m_willSkip = false; }
    putByte(b);
    if (m_pass2) {
        putByte(calculateBranch(m_skipOffsets[m_skipOffsetsIndex++]));
    } else {
        putByte(0);
        m_skipOffsets.push_back(0);
        m_willSkip = true;
    }
}

void Assembler::Impl::assemblyInw()
{
    noOpcode();
    readAddrMode();
    switch (m_addrMode) {
    case AddrMode::ABSOLUTE:
        putCommand(0xee); putWord(0x03d0); m_value++; putCommand(0xee); break;
    case AddrMode::ZEROPAGE:
        putCommand(0xe6); putWord(0x02d0); m_value++; putCommand(0xe6); break;
    case AddrMode::ABSOLUTE_X:
        putCommand(0xfe); putWord(0x03d0); m_value++; putCommand(0xfe); break;
    case AddrMode::ZEROPAGE_X:
        putCommand(0xf6); putWord(0x02d0); m_value++; putCommand(0xf6); break;
    default: illegalAddrMode();
    }
}

void Assembler::Impl::assemblyMove()
{
    noOpcode();
    readAddrMode();
    m_value1 = m_value; m_addrMode1 = m_addrMode;
    bool unknown1 = m_unknownInPass1;
    readAddrMode();
    m_value2 = m_value; m_addrMode2 = m_addrMode;
    m_unknownInPass1 = unknown1;
}

void Assembler::Impl::assemblyMoveByte(MoveFunction load, MoveFunction store)
{
    assemblyMove();
    (this->*load)(1);
    (this->*store)(2);
}

void Assembler::Impl::assemblyMoveWord(MoveFunction load, MoveFunction store,
                                       uint8_t inc, uint8_t dec)
{
    assemblyMove();
    switch (m_addrMode2 & AddrMode::STANDARD_MASK) {
    case AddrMode::ABSOLUTE: case AddrMode::ZEROPAGE:
    case AddrMode::ABSOLUTE_X: case AddrMode::ZEROPAGE_X:
    case AddrMode::ABSOLUTE_Y: case AddrMode::ZEROPAGE_Y:
        break;
    default: illegalAddrMode();
    }
    switch (m_addrMode1 & AddrMode::STANDARD_MASK) {
    case AddrMode::IMMEDIATE: {
        int high  = (m_value1 >> 8) & 0xff;
        m_value1 &= 0xff;
        (this->*load)(1); (this->*store)(2);
        m_value2++;
        if (m_unknownInPass1) {
            m_value1 = high;
            (this->*load)(1);
        } else {
            if (inc && ((m_value1 + 1) & 0xff) == high)  putByte(inc);
            else if (dec && ((m_value1 - 1) & 0xff) == high) putByte(dec);
            else if (m_value1 != high) { m_value1 = high; (this->*load)(1); }
        }
        (this->*store)(2);
        break;
    }
    case AddrMode::ABSOLUTE: case AddrMode::ZEROPAGE:
    case AddrMode::ABSOLUTE_X: case AddrMode::ZEROPAGE_X:
    case AddrMode::ABSOLUTE_Y: case AddrMode::ZEROPAGE_Y:
        (this->*load)(1); (this->*store)(2);
        m_value1++; m_value2++;
        (this->*load)(1); (this->*store)(2);
        break;
    default: illegalAddrMode();
    }
}

// ===========================================================================
// DTA
// ===========================================================================
void Assembler::Impl::storeDtaNumber(int val, char letter)
{
    int limit = (letter == 'b') ? 0xff : 0xffff;
    if ((!m_unknownInPass1 || m_pass2) && (val < -limit || val > limit))
        throw AssemblyError("Value out of range");
    switch (letter) {
    case 'a': putWord((uint16_t)val); break;
    case 'b': case 'l': putByte((uint8_t)val); break;
    case 'h': putByte((uint8_t)(val >> 8)); break;
    }
}

void Assembler::Impl::assemblyDtaInteger(char letter)
{
    std::string fn = readFunction();
    if (fn == "SIN") {
        readWord(); int sinCenter = m_value;
        readComma();
        readWord(); int sinAmp = m_value;
        readComma();
        readKnownPositive(); int sinPeriod = m_value;
        int sinMin = 0, sinMax = sinPeriod - 1;
        char next = readChar();
        if (next == ',') {
            readUnsignedWord(); mustBeKnownInPass1(); sinMin = m_value;
            readComma();
            readUnsignedWord(); mustBeKnownInPass1(); sinMax = m_value;
            if (readChar() != ')') illegalCharacter();
        } else if (next != ')') {
            illegalCharacter();
        }
        while (sinMin <= sinMax) {
            using std::numbers::pi;
            int val = sinCenter + (int)std::rint(sinAmp * std::sin(sinMin * 2.0 * pi / sinPeriod));
            storeDtaNumber(val, letter);
            sinMin++;
        }
        return;
    }
    readWord();
    storeDtaNumber(m_value, letter);
}

bool Assembler::Impl::readSign()
{
    char c = readChar();
    if (c == '+') return false;
    if (c == '-') return true;
    m_column--;
    return false;
}

void Assembler::Impl::putReal()
{
    if (m_realMantissa == 0) { putWord(0); putWord(0); putWord(0); return; }
    while (m_realMantissa < 0x1000000000LL) { m_realMantissa <<= 4; m_realExponent--; }
    if (m_realExponent & 1) {
        if (m_realMantissa & 0xf) throw AssemblyError("Out of precision");
        m_realMantissa >>= 4;
    }
    m_realExponent = (m_realExponent + 0x89) >> 1;
    if (m_realExponent < 64 - 49) throw AssemblyError("Out of precision");
    if (m_realExponent > 64 + 49) throw AssemblyError("Number too big");
    putByte((uint8_t)(m_realSign ? m_realExponent + 0x80 : m_realExponent));
    putByte((uint8_t)(m_realMantissa >> 32));
    putByte((uint8_t)(m_realMantissa >> 24));
    putByte((uint8_t)(m_realMantissa >> 16));
    putByte((uint8_t)(m_realMantissa >> 8));
    putByte((uint8_t)m_realMantissa);
}

void Assembler::Impl::readExponent()
{
    bool sign = readSign();
    char c = readChar();
    if (c < '0' || c > '9') illegalCharacter();
    int e = c - '0';
    c = readChar();
    if (c >= '0' && c <= '9') e = 10 * e + c - '0';
    else m_column--;
    m_realExponent += sign ? -e : e;
    putReal();
}

void Assembler::Impl::readFraction()
{
    for (;;) {
        char c = readChar();
        if (c >= '0' && c <= '9') {
            if (c != '0' && m_realMantissa >= 0x1000000000LL)
                throw AssemblyError("Out of precision");
            m_realMantissa <<= 4;
            m_realMantissa += c - '0';
            m_realExponent--;
            continue;
        }
        if (c == 'E' || c == 'e') { readExponent(); return; }
        m_column--;
        putReal();
        return;
    }
}

void Assembler::Impl::assemblyDtaReal()
{
    m_realSign     = readSign();
    m_realExponent = 0;
    m_realMantissa = 0;
    char c = readChar();
    if (c == '.') { readFraction(); return; }
    if (c < '0' || c > '9') illegalCharacter();
    do {
        if (m_realMantissa < 0x1000000000LL) {
            m_realMantissa <<= 4;
            m_realMantissa += c - '0';
        } else {
            if (c != '0') throw AssemblyError("Out of precision");
            m_realExponent++;
        }
        c = readChar();
    } while (c >= '0' && c <= '9');
    switch (c) {
    case '.':         readFraction();  break;
    case 'E': case 'e': readExponent(); break;
    default: m_column--; putReal();   break;
    }
}

void Assembler::Impl::assemblyDtaNumbers(char letter)
{
    if (eol() || m_line[m_column] != '(') {
        m_column--;   // back up to the type letter; assemblyDtaInteger reads from there
        assemblyDtaInteger('b');
        return;
    }
    m_column++;   // consume '('
    for (;;) {
        switch (letter) {
        case 'a': case 'b': case 'h': case 'l': assemblyDtaInteger(letter); break;
        case 'r': assemblyDtaReal(); break;
        }
        char c = readChar();
        if (c == ')') return;
        if (c != ',') illegalCharacter();
    }
}

void Assembler::Impl::assemblyDta()
{
    noOpcode();
    readSpaces();
    for (;;) {
        char c = readChar();
        switch (c & 0xdf) {   // uppercase
        case 'A': assemblyDtaNumbers('a'); break;
        case 'B': assemblyDtaNumbers('b'); break;
        case 'C': {
            std::vector<uint8_t> s;
            if (!readStringFromDta(s)) { m_column--; assemblyDtaInteger('b'); break; }
            for (auto b : s) putByte(b);
            break;
        }
        case 'D': {
            std::vector<uint8_t> s;
            if (!readStringFromDta(s)) { m_column--; assemblyDtaInteger('b'); break; }
            for (auto b : s) {
                switch (b & 0x60) {
                case 0x00: putByte((uint8_t)(b + 0x40)); break;
                case 0x20: case 0x40: putByte((uint8_t)(b - 0x20)); break;
                case 0x60: putByte(b); break;
                }
            }
            break;
        }
        case 'H': assemblyDtaNumbers('h'); break;
        case 'L': assemblyDtaNumbers('l'); break;
        case 'R': assemblyDtaNumbers('r'); break;
        default:
            m_column--;
            assemblyDtaInteger('b');
            break;
        }
        if (eol() || m_line[m_column] != ',') break;
        m_column++;
    }
}

// ===========================================================================
// Directives
// ===========================================================================
void Assembler::Impl::assemblyEqu()
{
    directive();
    if (!m_currentLabel) throw AssemblyError("Label name required");
    m_currentLabel->value = 0;
    readSpaces();
    readValue();
    m_currentLabel->value          = m_value;
    m_currentLabel->unknownInPass1 = m_unknownInPass1;
}

void Assembler::Impl::assemblyEnd()
{
    directive();
    assert(!m_foundEnd);
    m_foundEnd = true;
}

void Assembler::Impl::assemblyIftEli()
{
    m_ifContexts.back().condition = true;
    if (!inFalseCondition()) {
        readSpaces();
        readValue();
        mustBeKnownInPass1();
        if (m_value) m_ifContexts.back().aConditionMatched = true;
        m_ifContexts.back().condition = (m_value != 0);
    }
}

void Assembler::Impl::checkMissingIft()
{
    if (m_ifContexts.empty()) throw AssemblyError("Missing IFT");
}

void Assembler::Impl::assemblyIft()
{
    directive();
    m_ifContexts.push_back({});
    assemblyIftEli();
}

void Assembler::Impl::assemblyEliEls()
{
    directive();
    checkMissingIft();
    if (m_ifContexts.back().wasElse) throw AssemblyError("EIF expected");
}

void Assembler::Impl::assemblyEli()
{
    assemblyEliEls();
    if (m_ifContexts.back().aConditionMatched) {
        m_ifContexts.back().condition = false;
        return;
    }
    assemblyIftEli();
}

void Assembler::Impl::assemblyEls()
{
    assemblyEliEls();
    auto& ic = m_ifContexts.back();
    ic.wasElse  = true;
    ic.condition = !ic.aConditionMatched;
}

void Assembler::Impl::assemblyEif()
{
    directive();
    checkMissingIft();
    m_ifContexts.pop_back();
}

void Assembler::Impl::assemblyErt()
{
    directive();
    readSpaces();
    readValue();
    if (m_pass2 && m_value) throw AssemblyError("User-defined error");
}

bool Assembler::Impl::readOptionFlag()
{
    char pm = readChar();
    if (pm == '+') return true;
    if (pm == '-') return false;
    illegalCharacter();
}

void Assembler::Impl::assemblyOpt()
{
    directive();
    readSpaces();
    while (!eol()) {
        char letter = m_line[m_column++] & 0xdf;   // consume + uppercase
        switch (letter) {
        case 'F': m_optionFill         = readOptionFlag(); break;
        case 'G': m_option5200         = readOptionFlag(); break;
        case 'H': m_optionHeaders      = readOptionFlag(); break;
        case 'L': readOptionFlag(); break;  // listing — no-op
        case 'O': readOptionFlag(); break;  // object  — no-op
        case 'U': m_optionUnusedLabels = readOptionFlag(); break;
        case '?':
            if (!readOptionFlag()) throw AssemblyError("OPT ?- not supported");
            break;
        default:
            m_column--;
            return;
        }
    }
}

// ===========================================================================
// Origin / segment headers
// ===========================================================================
OrgModifier Assembler::Impl::readOrgModifier()
{
    readSpaces();
    if (m_column + 2 <= (int)m_line.size() && m_line[m_column + 1] == ':') {
        char c = m_line[m_column] & 0xdf;
        if (c == 'F') { checkHeadersOn(); m_column += 2; return OrgModifier::FORCE_FFFF; }
        if (c == 'A') { checkHeadersOn(); m_column += 2; return OrgModifier::FORCE_HEADER; }
        if (c == 'R') {                   m_column += 2; return OrgModifier::RELOCATE; }
    }
    return OrgModifier::NONE;
}

void Assembler::Impl::setOrigin(int addr, OrgModifier modifier)
{
    m_origin = m_loadOrigin = addr;
    bool requested = (modifier != OrgModifier::NONE);
    if (requested || m_loadingOrigin < 0 || (addr != m_loadingOrigin && !m_optionFill)) {
        m_blockIndex++;
        if (!m_pass2) {
            assert(m_blockIndex == (int)m_blockEnds.size());
            m_blockEnds.push_back((uint16_t)(addr - 1));
        }
        if (m_pass2 && m_optionHeaders) {
            if (addr - 1 == m_blockEnds[m_blockIndex]) {
                if (requested) throw AssemblyError("Cannot generate an empty block");
                return;
            }
            if (modifier == OrgModifier::FORCE_FFFF || m_objectBuffer.empty())
                objectWord(0xffff);
            if (requested || addr != m_loadingOrigin) {
                objectWord((uint16_t)addr);
                objectWord(m_blockEnds[m_blockIndex]);
                m_loadingOrigin = -1;
            }
        }
    }
}

void Assembler::Impl::checkHeadersOn()
{
    if (!m_optionHeaders) throw AssemblyError("Illegal when Atari file headers disabled");
}

void Assembler::Impl::assemblyOrg()
{
    noRepeatSkipDirective();
    OrgModifier modifier = readOrgModifier();
    readUnsignedWord();
    mustBeKnownInPass1();
    if (modifier == OrgModifier::RELOCATE) {
        checkOriginDefined();
        m_origin = m_value;
    } else {
        setOrigin(m_value, modifier);
    }
}

void Assembler::Impl::assemblyRunIni(uint16_t addr)
{
    noRepeatSkipDirective();
    checkHeadersOn();
    m_loadingOrigin = -1;
    OrgModifier modifier = readOrgModifier();
    if (modifier == OrgModifier::RELOCATE) throw AssemblyError("r: invalid here");
    setOrigin(addr, modifier);
    readUnsignedWord();
    putWord((uint16_t)m_value);
    m_loadingOrigin = -1;
}

// ===========================================================================
// File I/O helpers
// ===========================================================================
const std::vector<uint8_t>& Assembler::Impl::getSource(const std::string& filename)
{
    auto it = m_sourceFiles.find(filename);
    if (it != m_sourceFiles.end()) return it->second;
    if (m_loader) {
        auto content = m_loader(filename);
        if (content) {
            m_sourceFiles[filename] = std::move(*content);
            return m_sourceFiles[filename];
        }
    }
    throw AssemblyError("Cannot open file: " + filename);
}

void Assembler::Impl::assemblyIcl()
{
    directive();
    std::string filename = readFilename();
    checkNoExtraCharacters();
    m_includeLevel++;
    assemblyFile(filename);
    m_includeLevel--;
    m_line.clear();
}

void Assembler::Impl::assemblyIns()
{
    std::string filename = readFilename();
    int offset = 0;
    int length = -1;
    if (!eol() && m_line[m_column] == ',') {
        m_column++;
        readValue(); mustBeKnownInPass1(); offset = m_value;
        if (!eol() && m_line[m_column] == ',') {
            m_column++;
            readKnownPositive(); length = m_value;
        }
    }
    const auto& src = getSource(filename);
    size_t start;
    if (offset >= 0) {
        start = (size_t)offset;
    } else {
        size_t off = (size_t)(-offset);
        if (off > src.size()) throw AssemblyError("Error seeking file");
        start = src.size() - off;
    }
    if (m_inOpcode) length = 1;
    size_t end = (length < 0) ? src.size() : start + (size_t)length;
    if (length > 0 && end > src.size()) throw AssemblyError("File is too short");
    for (size_t i = start; i < end && i < src.size(); i++) putByte(src[i]);
}

// ===========================================================================
// assemblyInstruction
// ===========================================================================
void Assembler::Impl::assemblyInstruction(const std::string& instr)
{
    if (!m_inOpcode && m_origin < 0 && m_currentLabel && instr != "EQU")
        throw AssemblyError("No ORG specified");
    m_instructionBegin = true;

    switch (instr[0]) {
    case 'A':
        if (instr == "ADC") { assemblyAccumulator(0x60, 0x00, 0); break; }
        if (instr == "ADD") { assemblyAccumulator(0x60, 0x18, 0); break; }
        if (instr == "AND") { assemblyAccumulator(0x20, 0x00, 0); break; }
        if (instr == "ASL") { assemblyShift(0x00); break; }
        throw AssemblyError("Illegal instruction");
    case 'B':
        if (instr == "BCC") { assemblyBranch(0x90); break; }
        if (instr == "BCS") { assemblyBranch(0xb0); break; }
        if (instr == "BEQ") { assemblyBranch(0xf0); break; }
        if (instr == "BIT") { assemblyBit(); break; }
        if (instr == "BMI") { assemblyBranch(0x30); break; }
        if (instr == "BNE") { assemblyBranch(0xd0); break; }
        if (instr == "BPL") { assemblyBranch(0x10); break; }
        if (instr == "BRK") { putByte(0x00); break; }
        if (instr == "BVC") { assemblyBranch(0x50); break; }
        if (instr == "BVS") { assemblyBranch(0x70); break; }
        throw AssemblyError("Illegal instruction");
    case 'C':
        if (instr == "CLC") { putByte(0x18); break; }
        if (instr == "CLD") { putByte(0xd8); break; }
        if (instr == "CLI") { putByte(0x58); break; }
        if (instr == "CLV") { putByte(0xb8); break; }
        if (instr == "CMP") { assemblyAccumulator(0xc0, 0, 0); break; }
        if (instr == "CPX") { assemblyCompareIndex(0xe0); break; }
        if (instr == "CPY") { assemblyCompareIndex(0xc0); break; }
        throw AssemblyError("Illegal instruction");
    case 'D':
        if (instr == "DEC") { assemblyShift(0xc0); break; }
        if (instr == "DEX") { putByte(0xca); break; }
        if (instr == "DEY") { putByte(0x88); break; }
        if (instr == "DTA") { assemblyDta(); break; }
        throw AssemblyError("Illegal instruction");
    case 'E':
        if (instr == "EIF") { assemblyEif(); break; }
        if (instr == "ELI") { assemblyEli(); break; }
        if (instr == "ELS") { assemblyEls(); break; }
        if (instr == "END") { assemblyEnd(); break; }
        if (instr == "EOR") { assemblyAccumulator(0x40, 0, 0); break; }
        if (instr == "EQU") { assemblyEqu(); break; }
        if (instr == "ERT") { assemblyErt(); break; }
        throw AssemblyError("Illegal instruction");
    case 'I':
        if (instr == "ICL") { assemblyIcl(); break; }
        if (instr == "IFT") { assemblyIft(); break; }
        if (instr == "INC") { assemblyShift(0xe0); break; }
        if (instr == "INI") { assemblyRunIni(0x02e2); break; }
        if (instr == "INS") { assemblyIns(); break; }
        if (instr == "INW") { assemblyInw(); break; }
        if (instr == "INX") { putByte(0xe8); break; }
        if (instr == "INY") { putByte(0xc8); break; }
        throw AssemblyError("Illegal instruction");
    case 'J':
        if (instr == "JCC") { assemblyConditionalJump(0xb0); break; }
        if (instr == "JCS") { assemblyConditionalJump(0x90); break; }
        if (instr == "JEQ") { assemblyConditionalJump(0xd0); break; }
        if (instr == "JMI") { assemblyConditionalJump(0x10); break; }
        if (instr == "JMP") { assemblyJmp(); break; }
        if (instr == "JNE") { assemblyConditionalJump(0xf0); break; }
        if (instr == "JPL") { assemblyConditionalJump(0x30); break; }
        if (instr == "JSR") { assemblyJsr(); break; }
        if (instr == "JVC") { assemblyConditionalJump(0x70); break; }
        if (instr == "JVS") { assemblyConditionalJump(0x50); break; }
        throw AssemblyError("Illegal instruction");
    case 'L':
        if (instr == "LDA") { assemblyLda(0); break; }
        if (instr == "LDX") { assemblyLdx(0); break; }
        if (instr == "LDY") { assemblyLdy(0); break; }
        if (instr == "LSR") { assemblyShift(0x40); break; }
        throw AssemblyError("Illegal instruction");
    case 'M':
        if (instr == "MVA") { assemblyMoveByte(&Impl::assemblyLda, &Impl::assemblySta); break; }
        if (instr == "MVX") { assemblyMoveByte(&Impl::assemblyLdx, &Impl::assemblyStx); break; }
        if (instr == "MVY") { assemblyMoveByte(&Impl::assemblyLdy, &Impl::assemblySty); break; }
        if (instr == "MWA") { assemblyMoveWord(&Impl::assemblyLda, &Impl::assemblySta, 0,    0   ); break; }
        if (instr == "MWX") { assemblyMoveWord(&Impl::assemblyLdx, &Impl::assemblyStx, 0xe8, 0xca); break; }
        if (instr == "MWY") { assemblyMoveWord(&Impl::assemblyLdy, &Impl::assemblySty, 0xc8, 0x88); break; }
        throw AssemblyError("Illegal instruction");
    case 'N':
        if (instr == "NOP") { putByte(0xea); break; }
        throw AssemblyError("Illegal instruction");
    case 'O':
        if (instr == "OPT") { assemblyOpt(); break; }
        if (instr == "ORA") { assemblyAccumulator(0x00, 0, 0); break; }
        if (instr == "ORG") { assemblyOrg(); break; }
        throw AssemblyError("Illegal instruction");
    case 'P':
        if (instr == "PHA") { putByte(0x48); break; }
        if (instr == "PHP") { putByte(0x08); break; }
        if (instr == "PLA") { putByte(0x68); break; }
        if (instr == "PLP") { putByte(0x28); break; }
        throw AssemblyError("Illegal instruction");
    case 'R':
        if (instr == "RCC") { assemblyRepeat(0x90); break; }
        if (instr == "RCS") { assemblyRepeat(0xb0); break; }
        if (instr == "REQ") { assemblyRepeat(0xf0); break; }
        if (instr == "RMI") { assemblyRepeat(0x30); break; }
        if (instr == "RNE") { assemblyRepeat(0xd0); break; }
        if (instr == "ROL") { assemblyShift(0x20); break; }
        if (instr == "ROR") { assemblyShift(0x60); break; }
        if (instr == "RPL") { assemblyRepeat(0x10); break; }
        if (instr == "RTI") { putByte(0x40); break; }
        if (instr == "RTS") { putByte(0x60); break; }
        if (instr == "RUN") { assemblyRunIni(0x02e0); break; }
        if (instr == "RVC") { assemblyRepeat(0x50); break; }
        if (instr == "RVS") { assemblyRepeat(0x70); break; }
        throw AssemblyError("Illegal instruction");
    case 'S':
        if (instr == "SBC") { assemblyAccumulator(0xe0, 0x00, 0); break; }
        if (instr == "SCC") { assemblySkip(0x90); break; }
        if (instr == "SCS") { assemblySkip(0xb0); break; }
        if (instr == "SEC") { putByte(0x38); break; }
        if (instr == "SED") { putByte(0xf8); break; }
        if (instr == "SEI") { putByte(0x78); break; }
        if (instr == "SEQ") { assemblySkip(0xf0); break; }
        if (instr == "SMI") { assemblySkip(0x30); break; }
        if (instr == "SNE") { assemblySkip(0xd0); break; }
        if (instr == "SPL") { assemblySkip(0x10); break; }
        if (instr == "STA") { assemblySta(0); break; }
        if (instr == "STX") { assemblyStx(0); break; }
        if (instr == "STY") { assemblySty(0); break; }
        if (instr == "SUB") { assemblyAccumulator(0xe0, 0x38, 0); break; }
        if (instr == "SVC") { assemblySkip(0x50); break; }
        if (instr == "SVS") { assemblySkip(0x70); break; }
        throw AssemblyError("Illegal instruction");
    case 'T':
        if (instr == "TAX") { putByte(0xaa); break; }
        if (instr == "TAY") { putByte(0xa8); break; }
        if (instr == "TSX") { putByte(0xba); break; }
        if (instr == "TXA") { putByte(0x8a); break; }
        if (instr == "TXS") { putByte(0x9a); break; }
        if (instr == "TYA") { putByte(0x98); break; }
        throw AssemblyError("Illegal instruction");
    default:
        throw AssemblyError("Illegal instruction");
    }
    m_skipping = false;
}

// ===========================================================================
// assemblySequence
// ===========================================================================
void Assembler::Impl::assemblySequence()
{
    assert(!m_inOpcode);
    std::string instruction = readInstruction();
    std::vector<std::string> extras;
    while (!eol() && m_line[m_column] == ':') {
        m_sequencing = true;
        m_column++;
        extras.push_back(readInstruction());
    }
    if (!extras.empty()) {
        int savedColumn = m_column;
        if (m_willSkip) warning("Skipping only the first instruction");
        assemblyInstruction(instruction);
        checkNoExtraCharacters();
        m_wereManyInstructions = false;
        for (const auto& ni : extras) {
            m_column = savedColumn;
            assemblyInstruction(ni);
            m_wereManyInstructions = true;
        }
    } else {
        m_sequencing = false;
        assemblyInstruction(instruction);
        m_wereManyInstructions = false;
    }
}

// ===========================================================================
// assemblyLine
// ===========================================================================
void Assembler::Impl::assemblyLine()
{
    m_lineNo++;
    m_totalLines++;
    m_column = 0;

    std::string label = readLabel();
    m_currentLabel = nullptr;
    if (!label.empty()) {
        if (!inFalseCondition()) {
            if (label.find('?') == std::string::npos)
                m_lastGlobalLabel = label;
            if (!m_pass2) {
                if (m_labelTable.count(label))
                    throw AssemblyError("Label declared twice");
                auto p = std::make_unique<Label>(m_origin);
                m_currentLabel = p.get();
                m_labelTable[label] = std::move(p);
            } else {
                auto it = m_labelTable.find(label);
                assert(it != m_labelTable.end());
                m_currentLabel = it->second.get();
                m_currentLabel->passed = true;
                if (m_currentLabel->unused && m_optionUnusedLabels)
                    warning("Unused label: " + label);
            }
        }
        if (eol()) return;
        readSpaces();
    }

    // Skip whitespace, detect comments and repeat prefix ':'
    while (true) {
        if (eol()) return;
        char c = m_line[m_column];
        if (c == '\t' || c == ' ') { m_column++; continue; }
        if (c == '*' || c == ';' || c == '|') return;
        if (c == ':') {
            if (inFalseCondition()) return;
            m_column++;
            readUnsignedWord();
            mustBeKnownInPass1();
            int repeatLimit = m_value;
            if (repeatLimit == 0) return;
            readSpaces();
            m_repeating = true;
            if (repeatLimit == 1) {
                // D: break out of switch (inner), for continues → hits default → repeating=false
                m_repeating = false;
                break;
            }
            if (m_willSkip) warning("Skipping only the first instruction");
            int savedColumn = m_column;
            for (m_repeatCounter = 0; m_repeatCounter < repeatLimit; m_repeatCounter++) {
                m_column = savedColumn;
                assemblySequence();
            }
            checkNoExtraCharacters();
            m_wereManyInstructions = true;
            return;
        }
        m_repeating = false;
        break;
    }

    // Handle false-condition branches (only conditional directives are processed)
    if (inFalseCondition()) {
        std::string instr = readInstruction();
        if      (instr == "END") assemblyEnd();
        else if (instr == "IFT") assemblyIft();
        else if (instr == "ELI") assemblyEli();
        else if (instr == "ELS") assemblyEls();
        else if (instr == "EIF") assemblyEif();
        else return;
        checkNoExtraCharacters();
        return;
    }

    assemblySequence();
    checkNoExtraCharacters();
}

// ===========================================================================
// assemblyFile
// ===========================================================================
void Assembler::Impl::assemblyFile(const std::string& filename)
{
    // Add default .asx extension if no extension in the base name
    std::string resolved = filename;
    {
        std::string base = resolved;
        size_t slash = base.find_last_of("/\\");
        if (slash != std::string::npos) base = base.substr(slash + 1);
        if (!base.empty() && base.find('.') == std::string::npos)
            resolved += ".asx";
    }

    const std::vector<uint8_t>& source = getSource(resolved);

    std::string oldFilename = m_currentFilename;
    int         oldLineNo   = m_lineNo;
    m_currentFilename = resolved;
    m_lineNo  = 0;
    m_foundEnd = false;
    m_line.clear();

    size_t pos = 0;
    while (!m_foundEnd) {
        if (pos >= source.size()) break;
        uint8_t b = source[pos++];
        if (b == '\r') {
            assemblyLine();
            m_line.clear();
            if (pos >= source.size()) break;
            uint8_t b2 = source[pos++];
            if (b2 != '\n') m_line += (char)b2;
        } else if (b == '\n' || b == 0x9b) {
            assemblyLine();
            m_line.clear();
        } else {
            m_line += (char)b;
        }
    }
    if (!m_foundEnd) assemblyLine();
    m_foundEnd = false;
    m_currentFilename = oldFilename;
    m_lineNo          = oldLineNo;
}

// ===========================================================================
// assemblyPass
// ===========================================================================
void Assembler::Impl::assemblyPass(const std::string& mainFile)
{
    m_origin        = -1;
    m_loadOrigin    = -1;
    m_loadingOrigin = -1;
    m_blockIndex    = -1;
    m_optionFill         = m_opts.fill;
    m_option5200         = m_opts.atari5200;
    m_optionHeaders      = m_opts.headers;
    m_optionUnusedLabels = m_opts.unusedLabels;
    m_willSkip              = false;
    m_skipping              = false;
    m_repeatOffset          = 0;
    m_wereManyInstructions  = false;
    m_currentFilename = "command line";
    m_lineNo = 0;

    for (const auto& def : m_commandLineDefinitions) {
        size_t eq = def.find('=');
        m_line = (eq != std::string::npos)
            ? def.substr(0, eq) + " equ " + def.substr(eq + 1)
            : def;
        assemblyLine();
    }
    m_line.clear();
    m_totalLines = 0;
    assemblyFile(mainFile);

    if (!m_ifContexts.empty()) throw AssemblyError("Missing EIF");
    if (m_willSkip)            throw AssemblyError("Can't skip over this");
}

// ===========================================================================
// Assembler public API
// ===========================================================================
Assembler::Assembler(FileLoader loader, DiagnosticConsumer consumer)
    : m_impl(std::make_unique<Impl>(std::move(loader), std::move(consumer)))
{}

Assembler::~Assembler() = default;

void Assembler::define(std::string_view label, int value)
{
    m_impl->m_commandLineDefinitions.push_back(
        std::string(label) + "=" + std::to_string(value));
}

Result<XEXFile> Assembler::assemble(std::string_view main_file, AssemblerOptions opts)
{
    m_impl->m_opts   = opts;
    m_impl->m_pass2  = false;
    m_impl->m_objectBuffer.clear();
    m_impl->m_blockEnds.clear();
    m_impl->m_skipOffsets.clear();
    m_impl->m_skipOffsetsIndex = 0;
    m_impl->m_ifContexts.clear();
    m_impl->m_labelTable.clear();
    m_impl->m_lastGlobalLabel.clear();
    m_impl->m_valOpStack.clear();

    std::string main(main_file);
    try {
        m_impl->assemblyPass(main);

        m_impl->m_pass2 = true;
        m_impl->m_objectBuffer.clear();
        m_impl->m_skipOffsetsIndex = 0;
        m_impl->m_ifContexts.clear();
        // Keep labelTable; reset per-pass flag
        for (auto& [k, v] : m_impl->m_labelTable) v->passed = false;

        m_impl->assemblyPass(main);
    } catch (AssemblyError& e) {
        if (m_impl->m_consumer) {
            Diagnostic d;
            d.severity = DiagnosticSeverity::Error;
            d.message  = e.msg;
            d.filename = m_impl->m_currentFilename;
            d.line     = m_impl->m_lineNo;
            m_impl->m_consumer(d);
        }
        return std::unexpected(Error::AssemblyFailed);
    }
    return parse_xex(m_impl->m_objectBuffer);
}

void Assembler::reset()
{
    m_impl->m_commandLineDefinitions.clear();
    m_impl->m_sourceFiles.clear();
    m_impl->m_labelTable.clear();
    m_impl->m_lastGlobalLabel.clear();
    m_impl->m_valOpStack.clear();
    m_impl->m_objectBuffer.clear();
    m_impl->m_blockEnds.clear();
    m_impl->m_skipOffsets.clear();
    m_impl->m_ifContexts.clear();
    m_impl->m_pass2 = false;
}

} // namespace xebin
