#include "xebin/rle.h"
#include <catch2/catch_test_macros.hpp>
#include <numeric>
#include <vector>

using namespace xebin;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static void round_trip(const std::vector<uint8_t>& input)
{
    RLECompressor rle;
    auto compressed = rle.compress(input);
    REQUIRE(compressed.has_value());
    auto decompressed = rle.decompress(*compressed);
    REQUIRE(decompressed.has_value());
    CHECK(*decompressed == input);
}

// ---------------------------------------------------------------------------
// Round-trip correctness
// ---------------------------------------------------------------------------

TEST_CASE("RLE round-trip", "[rle]")
{
    SECTION("empty input")
        { round_trip({}); }

    SECTION("single byte")
        { round_trip({0x42}); }

    SECTION("run of 3 — below threshold, stays literal")
        { round_trip({0xAA, 0xAA, 0xAA}); }

    SECTION("run of 4 — at threshold, becomes token")
        { round_trip({0xAA, 0xAA, 0xAA, 0xAA}); }

    SECTION("run of 300 — split across two tokens at 255-byte boundary")
        { round_trip(std::vector<uint8_t>(300, 0x55)); }

    SECTION("literal run followed by encoded run")
        { round_trip({0x01, 0x02, 0x03, 0x04, 0x04, 0x04, 0x04, 0x04}); }

    SECTION("100 identical bytes")
        { round_trip(std::vector<uint8_t>(100, 0x00)); }

    SECTION("all 256 byte values once each") {
        std::vector<uint8_t> all(256);
        std::iota(all.begin(), all.end(), uint8_t{0});
        round_trip(all);
    }

    SECTION("alternating bytes — worst case for RLE expansion") {
        std::vector<uint8_t> alt(200);
        for (size_t i = 0; i < alt.size(); ++i) alt[i] = (i & 1) ? 0xAA : 0x55;
        round_trip(alt);
    }
}

// ---------------------------------------------------------------------------
// Encoding format invariants (verified against sp.asm Lad92 logic)
// ---------------------------------------------------------------------------

TEST_CASE("RLE compressed stream format", "[rle]")
{
    RLECompressor rle;

    SECTION("first byte is always the escape marker") {
        // Input: all 0x00.  Freq[0]=10, all others=0, so escape=0x01 (first
        // byte with strictly lower frequency than 0x00, i.e. 0).
        auto result = rle.compress(std::vector<uint8_t>(10, 0x00));
        REQUIRE(result.has_value());
        CHECK(result->at(0) == 0x01);
    }

    SECTION("run of 4 encoded as (escape, 4, byte)") {
        // All bytes are 0xAA so escape = 0x00.
        auto result = rle.compress(std::vector<uint8_t>(4, 0xAA));
        REQUIRE(result.has_value());
        // Stream: [escape, escape, 4, 0xAA]
        REQUIRE(result->size() == 4);
        uint8_t esc = result->at(0);
        CHECK(result->at(1) == esc);
        CHECK(result->at(2) == 4);
        CHECK(result->at(3) == 0xAA);
    }

    SECTION("run of 3 emitted as 3 literals") {
        // Input: 3 × 0xAA → escape = 0x00 (freq 0), 0xAA appears 3 times.
        auto result = rle.compress(std::vector<uint8_t>(3, 0xAA));
        REQUIRE(result.has_value());
        // Stream: [escape, 0xAA, 0xAA, 0xAA]
        REQUIRE(result->size() == 4);
        uint8_t esc = result->at(0);
        CHECK(esc != 0xAA);
        CHECK(result->at(1) == 0xAA);
        CHECK(result->at(2) == 0xAA);
        CHECK(result->at(3) == 0xAA);
    }

    SECTION("escape byte never appears as a bare literal") {
        // Use all 256 distinct byte values so every byte has freq >= 1; the
        // one with the lowest count becomes the escape.  Then verify that the
        // escape byte value never appears outside of a (escape, count, value)
        // triple in the compressed stream.
        std::vector<uint8_t> input;
        // Each byte value appears at least once; give 0x42 extra occurrences
        // so it is definitely NOT the escape, making the escape something with
        // freq=1.
        for (int v = 0; v < 256; ++v) input.push_back(static_cast<uint8_t>(v));
        for (int i = 0; i < 5; ++i) input.push_back(0x42);

        auto result = rle.compress(input);
        REQUIRE(result.has_value());
        const auto& v = *result;
        uint8_t esc = v[0];

        for (size_t i = 1; i < v.size(); ++i) {
            if (v[i] == esc) {
                // Must be followed by count + value bytes.
                REQUIRE(i + 2 < v.size());
                i += 2;
            }
        }
    }

    SECTION("run of 255 is one token; the 256th byte becomes a literal") {
        // 256 × 0xBB.  escape = 0x00 (freq 0).
        // First 255 bytes → encoded token (escape, 255, 0xBB).
        // Remaining 1 byte: run=1, value≠escape → emitted as a literal.
        // Stream: [escape, escape, 255, 0xBB, 0xBB] = 5 bytes.
        std::vector<uint8_t> input(256, 0xBB);
        auto result = rle.compress(input);
        REQUIRE(result.has_value());

        CHECK(result->size() == 5);
        uint8_t esc = result->at(0);
        CHECK(result->at(1) == esc);   // token start
        CHECK(result->at(2) == 255);   // count
        CHECK(result->at(3) == 0xBB);  // value
        CHECK(result->at(4) == 0xBB);  // trailing literal

        auto back = rle.decompress(*result);
        REQUIRE(back.has_value());
        CHECK(*back == input);
    }
}

// ---------------------------------------------------------------------------
// Decompressor error handling
// ---------------------------------------------------------------------------

TEST_CASE("RLE decompress error handling", "[rle]")
{
    RLECompressor rle;

    SECTION("empty input yields empty output") {
        auto result = rle.decompress({});
        REQUIRE(result.has_value());
        CHECK(result->empty());
    }

    SECTION("escape byte with no following bytes — TruncatedToken") {
        // Stream: [escape_byte=0x01, 0x01] — escape seen but count/value missing
        auto result = rle.decompress(std::vector<uint8_t>{0x01, 0x01});
        REQUIRE_FALSE(result.has_value());
        CHECK(result.error() == Error::TruncatedToken);
    }

    SECTION("escape byte with only count, no value — TruncatedToken") {
        // Stream: [escape=0x01, 0x01, 5] — only count byte present, value missing
        auto result = rle.decompress(std::vector<uint8_t>{0x01, 0x01, 5});
        REQUIRE_FALSE(result.has_value());
        CHECK(result.error() == Error::TruncatedToken);
    }
}
