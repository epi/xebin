#include "xebin/assembler.h"
#include "xebin/xex.h"
#include <catch2/catch_test_macros.hpp>
#include <string>
#include <vector>

using namespace xebin;
using V = std::vector<uint8_t>;

// ---------------------------------------------------------------------------
// Helper: assemble a source string and return the raw XEX bytes.
// The string is stored under the key "test.asx".
// ---------------------------------------------------------------------------
static V assemble_raw(const std::string& src)
{
    V src_bytes(src.begin(), src.end());
    Assembler a(
        [&src_bytes](std::string_view name) -> std::optional<V> {
            if (name == "test.asx") return src_bytes;
            return std::nullopt;
        });
    auto result = a.assemble("test");
    REQUIRE(result.has_value());
    return write_xex(*result);
}

// Assemble and return only the data bytes of the first segment.
static V assemble_data(const std::string& src)
{
    V src_bytes(src.begin(), src.end());
    Assembler a(
        [&src_bytes](std::string_view name) -> std::optional<V> {
            if (name == "test.asx") return src_bytes;
            return std::nullopt;
        });
    auto result = a.assemble("test");
    REQUIRE(result.has_value());
    REQUIRE_FALSE(result->segments.empty());
    return result->segments[0].data;
}

// Assemble, expect failure, return the error message.
static std::string assemble_error(const std::string& src)
{
    V src_bytes(src.begin(), src.end());
    std::string msg;
    Assembler a(
        [&src_bytes](std::string_view name) -> std::optional<V> {
            if (name == "test.asx") return src_bytes;
            return std::nullopt;
        },
        [&msg](const Diagnostic& d) { msg = d.message; });
    auto result = a.assemble("test");
    REQUIRE_FALSE(result.has_value());
    CHECK(result.error() == Error::AssemblyFailed);
    return msg;
}

// ---------------------------------------------------------------------------
// Expression parser (mirrors D unittest block 1 / testValue)
// ---------------------------------------------------------------------------
TEST_CASE("Assembler expression: integer literals")
{
    // Verify that constants evaluate correctly by using EQU and checking output.
    // We use DTA to emit the value as a byte/word.
    CHECK(assemble_data(" org $600\n dta b(123)") == V{123});
    CHECK(assemble_data(" org $600\n dta b($1a)") == V{0x1a});
    CHECK(assemble_data(" org $600\n dta b(%101)") == V{5});
}

TEST_CASE("Assembler expression: hardware register shortcuts")
{
    CHECK(assemble_data(" org $600\n dta a(^07)") == V{0x07, 0xd0});  // $d007 little-endian
    CHECK(assemble_data(" org $600\n dta a(^49)") == V{0x09, 0xd4});  // $d409
}

TEST_CASE("Assembler expression: operators")
{
    CHECK(assemble_data(" org $600\n dta b(!0)")       == V{1});
    CHECK(assemble_data(" org $600\n dta b(<$1234)")   == V{0x34});
    CHECK(assemble_data(" org $600\n dta b(>$1234)")   == V{0x12});
    CHECK(assemble_data(" org $600\n dta b(1+2)")      == V{3});
    CHECK(assemble_data(" org $600\n dta b(1+2*3)")    == V{7});
    CHECK(assemble_data(" org $600\n dta b([1+2]*3)")  == V{9});
}

TEST_CASE("Assembler expression: opcode embedding")
{
    CHECK(assemble_data(" org $600\n dta b({nop})")        == V{0xea});
    CHECK(assemble_data(" org $600\n dta b({CLC}+{sec})") == V{0x50});
    CHECK(assemble_data(" org $600\n dta b({Jsr})")        == V{0x20});
    CHECK(assemble_data(" org $600\n dta b({bit a:})")     == V{0x2c});
    CHECK(assemble_data(" org $600\n dta b({bIt $7d})")    == V{0x24});
}

// ---------------------------------------------------------------------------
// Addressing mode parser (mirrors D unittest block 2 / testAddrMode)
// Verified indirectly by checking emitted opcodes.
// ---------------------------------------------------------------------------
TEST_CASE("Assembler addressing: accumulator")
{
    // ASL @ → 0x0a
    CHECK(assemble_data(" org $600\n asl @") == V{0x0a});
}

TEST_CASE("Assembler addressing: absolute indexed with inc/dec")
{
    // STA $abc,x- → sta abs,x + dex (0x9d 0xbc 0x0a 0xca)
    auto d = assemble_data(" org $600\n sta $abc,x-");
    REQUIRE(d.size() == 4);
    CHECK(d[0] == 0x9d);
    CHECK(d[3] == 0xca);  // DEX
}

TEST_CASE("Assembler addressing: zeropage indexed with inc")
{
    // STY $ab,x+ → sty zp,x + inx (0x94 0xab 0xe8) ... but $ab fits in zeropage
    // Actually STY $ab,X uses ZEROPAGE_X: opcode 0x94, then 0xe8 for INC
    // Wait: assemblySty ABSOLUTE_X → m_addrMode++ → ZEROPAGE_X → putCommand(0x94)
    // putCommand: ZEROPAGE_X → 1-byte address + post-INX (0xe8)
    // Oh: $ab,Y+ → STY ZP,Y is invalid (STY doesn't have ,Y mode).
    // The test is for $ab,Y+ meaning (ZEROPAGE_Y+INCREMENT): but
    // assemblySty only handles ABSOLUTE_X/ZEROPAGE_X so ,Y would illegalAddrMode.
    // Use STA $ab,Y+ instead: STA ZP,Y → ZEROPAGE_Y-1=ABSOLUTE_Y 0x99 0xab 0x00 0xc8
    auto d = assemble_data(" org $600\n sta $ab,Y+");
    REQUIRE(d.size() == 4);
    CHECK(d[0] == 0x99); // STA abs,Y (zp,Y promoted)
    CHECK(d[3] == 0xc8); // INY
}

TEST_CASE("Assembler addressing: indirect X and Y")
{
    auto dx = assemble_data(" org $600\n lda ($10,x)");
    CHECK(dx == V{0xa1, 0x10});

    auto dy = assemble_data(" org $600\n lda ($10),y");
    CHECK(dy == V{0xb1, 0x10});
}

TEST_CASE("Assembler addressing: indirect jump")
{
    auto d = assemble_data(" org $600\n jmp ($abcd)");
    CHECK(d == V{0x6c, 0xcd, 0xab});
}

// ---------------------------------------------------------------------------
// Instruction assembler (mirrors D unittest block 3 / testInstruction)
// ---------------------------------------------------------------------------
TEST_CASE("Assembler instruction: NOP")
{
    CHECK(assemble_data(" org $600\n nop") == V{0xea});
}

TEST_CASE("Assembler instruction: ADD with indirect-X-zero")
{
    // add (5,0) → CLC + ADC (0,x) with X=5 preamble: 18 a2 00 61 05
    // Wait: ADD = CLC prefix + ADC. (5,0) is INDIRECT_X+ZERO: putWord(0x00a2)=LDX#0 then ADC (5,x).
    // So: 0x18 0xa2 0x00 0x61 0x05
    CHECK(assemble_data(" org $600\n add (5,0)") == V{0x18, 0xa2, 0x00, 0x61, 0x05});
}

TEST_CASE("Assembler instruction: MWA immediate")
{
    // mwa #$abcd $1234 → lda #$cd / sta $1234 / lda #$ab / sta $1235
    CHECK(assemble_data(" org $600\n mwa #$abcd $1234")
          == V{0xa9, 0xcd, 0x8d, 0x34, 0x12, 0xa9, 0xab, 0x8d, 0x35, 0x12});
}

TEST_CASE("Assembler instruction: MWX immediate")
{
    // mwx #-256 $80 → ldx #0 / stx $80 / dex / stx $81
    CHECK(assemble_data(" org $600\n mwx #-256 $80")
          == V{0xa2, 0x00, 0x86, 0x80, 0xca, 0x86, 0x81});
}

TEST_CASE("Assembler instruction: DTA integer and string")
{
    // dta 5, d'Foo'*, a($4589)
    CHECK(assemble_data(" org $600\n dta 5,d'Foo'*,a($4589)")
          == V{0x05, 0xa6, 0xef, 0xef, 0x89, 0x45});
}

TEST_CASE("Assembler instruction: DTA real numbers")
{
    // dta r(1, 12, 123, 1234567890, 12345678900000, .5, .03, 000.1664534589, 1e97)
    V expected = {
        0x40, 0x01, 0x00, 0x00, 0x00, 0x00,
        0x40, 0x12, 0x00, 0x00, 0x00, 0x00,
        0x41, 0x01, 0x23, 0x00, 0x00, 0x00,
        0x44, 0x12, 0x34, 0x56, 0x78, 0x90,
        0x46, 0x12, 0x34, 0x56, 0x78, 0x90,
        0x3f, 0x50, 0x00, 0x00, 0x00, 0x00,
        0x3f, 0x03, 0x00, 0x00, 0x00, 0x00,
        0x3f, 0x16, 0x64, 0x53, 0x45, 0x89,
        0x70, 0x10, 0x00, 0x00, 0x00, 0x00,
    };
    CHECK(assemble_data(" org $600\n dta r(1,12,123,1234567890,12345678900000,.5,.03,000.1664534589,1e97)")
          == expected);
}

// ---------------------------------------------------------------------------
// Full-file assembly (mirrors D unittest block 4 / assemblyFile)
// ---------------------------------------------------------------------------
TEST_CASE("Assembler full: sequence directive (lda:sne:ldy:inx)")
{
    // " lda:sne:ldy:inx $1234"
    // lda $1234 (0xad 0x34 0x12) : sne (SNE = skip if not equal → BNE +3: 0xd0 0x03)
    //   : ldy $1234 (0xac 0x34 0x12) : inx (0xe8)
    // sne skips the NEXT instruction, so it branches over ldy (3 bytes).
    // Expected: ad 34 12 d0 03 ac 34 12 e8
    CHECK(assemble_data(" org $600\n lda:sne:ldy:inx $1234")
          == V{0xad, 0x34, 0x12, 0xd0, 0x03, 0xac, 0x34, 0x12, 0xe8});
}

TEST_CASE("Assembler full: labels and branches")
{
    // Simple forward branch test
    std::string src =
        " org $600\n"
        "loop lda #0\n"
        " bne loop\n";
    auto d = assemble_data(src);
    // lda #0 = a9 00 (2 bytes), bne loop = d0 fe (-2 from PC after bne operand)
    REQUIRE(d.size() == 4);
    CHECK(d[0] == 0xa9);
    CHECK(d[1] == 0x00);
    CHECK(d[2] == 0xd0);
    CHECK(d[3] == (uint8_t)-4);  // target $600 - (PC after BNE = $604) = -4 = 0xFC
}

TEST_CASE("Assembler full: conditional assembly IFT/EIF")
{
    std::string src =
        " org $600\n"
        "FLAG equ 1\n"
        " ift FLAG\n"
        " nop\n"
        " eif\n";
    CHECK(assemble_data(src) == V{0xea});
}

TEST_CASE("Assembler full: conditional assembly skipped block")
{
    std::string src =
        " org $600\n"
        "FLAG equ 0\n"
        " ift FLAG\n"
        " nop\n"
        " eif\n"
        " brk\n";
    CHECK(assemble_data(src) == V{0x00});
}

TEST_CASE("Assembler full: RUN directive emits RUNAD segment")
{
    std::string src =
        " org $600\n"
        " nop\n"
        " run $600\n";
    auto raw = assemble_raw(src);
    // Should contain: ff ff 00 06 00 06 <code> ff ff e0 02 e1 02 <addr>
    // Find RUNAD segment (load addr $02e0):
    bool found = false;
    for (size_t i = 0; i + 3 < raw.size(); i++) {
        if (raw[i] == 0xe0 && raw[i+1] == 0x02 && raw[i+2] == 0xe1 && raw[i+3] == 0x02) {
            found = true;
            // The word after end_addr should be $0600 (little-endian)
            CHECK(raw[i+4] == 0x00);
            CHECK(raw[i+5] == 0x06);
            break;
        }
    }
    CHECK(found);
}

TEST_CASE("Assembler full: repeat directive (:n)")
{
    std::string src = " org $600\n :3 nop\n";
    CHECK(assemble_data(src) == V{0xea, 0xea, 0xea});
}

// ---------------------------------------------------------------------------
// Error handling
// ---------------------------------------------------------------------------
TEST_CASE("Assembler error: undeclared label")
{
    std::string err = assemble_error(" org $600\n lda MISSING\n");
    CHECK(err.find("Undeclared label") != std::string::npos);
}

TEST_CASE("Assembler error: label declared twice")
{
    std::string err = assemble_error(" org $600\nFOO nop\nFOO nop\n");
    CHECK(err.find("declared twice") != std::string::npos);
}

TEST_CASE("Assembler error: branch out of range")
{
    // Fill 200 bytes then branch to start — way out of range
    std::string src = " org $600\nlabel nop\n :200 nop\n bne label\n";
    std::string err = assemble_error(src);
    CHECK(err.find("Branch out of range") != std::string::npos);
}

TEST_CASE("Assembler error: no ORG")
{
    std::string err = assemble_error(" nop\n");
    CHECK(err.find("ORG") != std::string::npos);
}

TEST_CASE("Assembler: define() sets label before assembly")
{
    V src_bytes;
    {
        std::string s = " org $600\n dta b(VERSION)\n";
        src_bytes = V(s.begin(), s.end());
    }
    Assembler a([&src_bytes](std::string_view name) -> std::optional<V> {
        if (name == "test.asx") return src_bytes;
        return std::nullopt;
    });
    a.define("VERSION", 42);
    auto result = a.assemble("test");
    REQUIRE(result.has_value());
    REQUIRE_FALSE(result->segments.empty());
    CHECK(result->segments[0].data == V{42});
}
