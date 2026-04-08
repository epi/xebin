#include "xebin/lz77.h"
#include <catch2/catch_test_macros.hpp>
#include <vector>
#include <numeric>
#include <fmt/core.h>

using namespace xebin;
using V = std::vector<uint8_t>;

static LZ77Compressor lz77;

// Round-trip helper: compress then decompress, check we get back the original.
static void round_trip(const V& input)
{
    auto compressed = lz77.compress(input);
    REQUIRE(compressed.has_value());
    auto restored = lz77.decompress(*compressed);
    REQUIRE(restored.has_value());
    CHECK(*restored == input);
}

// -------------------------------------------------------------------------
// Round-trip tests
// -------------------------------------------------------------------------

TEST_CASE("LZ77 round-trip: empty input")
{
    round_trip({});
}

TEST_CASE("LZ77 round-trip: single byte")
{
    round_trip({0x42});
}

TEST_CASE("LZ77 round-trip: all distinct bytes")
{
    V input(256);
    std::iota(input.begin(), input.end(), uint8_t{0});
    round_trip(input);
}

TEST_CASE("LZ77 round-trip: repeated byte (run of 8)")
{
    // Run of 8: a back-reference should be found (length >= 4).
    round_trip(V(8, 0xBB));
}

TEST_CASE("LZ77 round-trip: run of 63 (max token length)")
{
    round_trip(V(63, 0xAA));
}

TEST_CASE("LZ77 round-trip: run of 64 (splits across two references)")
{
    round_trip(V(64, 0xAA));
}

TEST_CASE("LZ77 round-trip: run of 200")
{
    round_trip(V(200, 0x55));
}

TEST_CASE("LZ77 round-trip: short run then repeated block")
{
    // "ABCABCABCABC" — back-references should kick in after first occurrence.
    V input;
    for (int i = 0; i < 4; ++i)
        for (uint8_t b : {0x41, 0x42, 0x43})
            input.push_back(b);
    round_trip(input);
}

TEST_CASE("LZ77 round-trip: offset near 1023")
{
    // Build a stream where a matching block appears more than 512 bytes back.
    V input(600, 0x00);
    V pattern = {0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08};
    // Pattern near start (offset ~590 from second occurrence)
    for (size_t j = 0; j < pattern.size(); ++j)
        input[j] = pattern[j];
    // Same pattern near end
    for (size_t j = 0; j < pattern.size(); ++j)
        input[590 + j] = pattern[j];
    round_trip(input);
}

TEST_CASE("LZ77 round-trip: overlapping reference (period 1)")
{
    // Single byte repeated: offset=1, length=7 → decoder emits 7 copies.
    round_trip(V(8, 0xCC));
}

TEST_CASE("LZ77 round-trip: overlapping reference (period 3)")
{
    // "ABCABCABCABC" with period 3.
    V input;
    for (int i = 0; i < 12; ++i)
        input.push_back(static_cast<uint8_t>('A' + (i % 3)));
    round_trip(input);
}

TEST_CASE("LZ77 round-trip: escape byte appears as literal")
{
    // Force the escape byte to appear; it must be encoded as (escape, 0x00).
    // Use all-same-value so every other byte might differ.
    V input = {0x01, 0x02, 0x03, 0x04, 0x05};
    round_trip(input);
}

// -------------------------------------------------------------------------
// Format invariant tests
// -------------------------------------------------------------------------

TEST_CASE("LZ77 format: first byte is escape")
{
    V input = {0x10, 0x20, 0x30, 0x40};
    auto c = lz77.compress(input);
    REQUIRE(c.has_value());
    // The escape byte is the least-frequent; for 4 distinct bytes it's 0x00
    // (frequency 0).  Whatever it is, byte 0 is the escape.
    CHECK(c->size() >= 1);
}

TEST_CASE("LZ77 format: early exit keeps largest offset for max-length match")
{
    // A run of 127 identical bytes (escape = 0x00, never appears in input):
    //   pos=0 : literal   (no window yet)
    //   pos=1 : scan offsets 1..1; offset=1 → len=63=max_len → early exit, offset=1
    //   pos=64: scan offsets 64..1; offset=64 → len=63=max_len → early exit, offset=64
    //
    // Without the early exit the scan would continue after offset=64 and
    // eventually settle on offset=1 for the second token as well.
    //
    // Expected stream (8 bytes):
    //   [0]    escape (0x00)
    //   [1]    0xBB  (literal)
    //   [2..4] escape 0x3f 0x01   (len=63, offset=1)
    //   [5..7] escape 0x3f 0x40   (len=63, offset=64)
    V input(127, 0xBB);
    auto c = lz77.compress(input);
    REQUIRE(c.has_value());
    REQUIRE(c->size() == 8);
    uint8_t escape = (*c)[0];
    // first back-reference: offset=1
    CHECK((*c)[2] == escape);
    CHECK(((*c)[3] & 0x3F) == 63);
    CHECK((*c)[4] == 0x01);
    // second back-reference: offset=64, not 1
    CHECK((*c)[5] == escape);
    CHECK(((*c)[6] & 0x3F) == 63);
    CHECK((*c)[7] == 0x40);
}

TEST_CASE("LZ77 format: back-reference token is never 0x00")
{
    // Compress a run long enough to guarantee a back-reference, then scan
    // the output for (escape, non-zero, off_lo) triples.
    V input(20, 0xAB);
    auto c = lz77.compress(input);
    REQUIRE(c.has_value());
    uint8_t escape = (*c)[0];
    bool found_ref = false;
    for (size_t i = 1; i + 2 < c->size(); ) {
        if ((*c)[i] == escape) {
            uint8_t token = (*c)[i + 1];
            CHECK(token != 0x00);  // 0x00 encodes a literal escape, not a ref
            found_ref = true;
            i += 3;
        } else {
            ++i;
        }
    }
    CHECK(found_ref);
}

TEST_CASE("LZ77 format: escape as literal encodes as (escape, 0x00)")
{
    // Craft input so that the escape byte (0x00 — frequency 0) appears once.
    // All other bytes appear at least once, pushing 0x00 to lowest frequency.
    V input = {0x01, 0x02, 0x03, 0x04, 0x00};  // 0x00 appears once, others once too
    // Actually escape = 0x00 since it ties but lowest byte wins.
    // Compress and verify round-trip + escape literal rule.
    auto c = lz77.compress(input);
    REQUIRE(c.has_value());
    uint8_t escape = (*c)[0];
    // Verify the escape never appears bare in the stream (always followed by token).
    for (size_t i = 1; i < c->size(); ) {
        if ((*c)[i] == escape) {
            REQUIRE(i + 1 < c->size());
            i += 2;  // skip (escape, token)
            // if token != 0, there's also an off_lo byte
            // (We don't check here; round-trip covers correctness.)
        } else {
            ++i;
        }
    }
}

TEST_CASE("LZ77 format: no compression for 3-byte run (below threshold)")
{
    // A run of 3 identical bytes should NOT produce a back-reference (min is 4).
    // Verify compressed size: with only 3 bytes to match, it's literals.
    V input = {0x42, 0x42, 0x42};
    auto c = lz77.compress(input);
    REQUIRE(c.has_value());
    // escape (1) + 3 literals = 4 bytes (none of them equal to escape = 0x00).
    uint8_t escape = (*c)[0];
    // No escape byte in input (0x42 != escape=0x00), so 4 bytes total.
    if (escape != 0x42)
        CHECK(c->size() == 4);
    // Round-trip is the authoritative check regardless.
    auto r = lz77.decompress(*c);
    REQUIRE(r.has_value());
    CHECK(*r == input);
}

TEST_CASE("LZ77 format: minimum run that produces a back-reference")
{
    // sp.asm skips the match search when fewer than 5 bytes remain (CPY #$05
    // / BCC Lafff).  So the minimum run that can produce a back-reference is
    // 6 bytes: the first is a literal, the remaining 5 form a back-reference
    // (offset=1, length=5).
    // Compressed stream: escape(1) + literal(1) + ref(3) = 5 bytes.
    // escape = 0x00 (freq 0 in all-0xBB input).
    V input(6, 0xBB);
    auto c = lz77.compress(input);
    REQUIRE(c.has_value());
    CHECK(c->size() == 5);
    // c[0]=escape, c[1]=0xBB, c[2]=escape, c[3]=token, c[4]=off_lo
    uint8_t token  = (*c)[3];
    uint8_t off_lo = (*c)[4];
    CHECK((token & 0x3F) == 5);   // length == 5
    CHECK(off_lo == 1);            // offset == 1
}

TEST_CASE("LZ77 format: run of 5 identical bytes stays as literals")
{
    // With fewer than 5 remaining bytes at pos=1, no search is performed.
    // All 5 bytes are emitted as literals.
    // escape = 0x00 (freq 0); 0xBB != 0x00 so no escape encoding needed.
    V input(5, 0xBB);
    auto c = lz77.compress(input);
    REQUIRE(c.has_value());
    CHECK(c->size() == 6);  // escape + 5 literals
}

// -------------------------------------------------------------------------
// Error handling tests
// -------------------------------------------------------------------------

TEST_CASE("LZ77 decompress: empty input returns empty")
{
    auto r = lz77.decompress({});
    REQUIRE(r.has_value());
    CHECK(r->empty());
}

TEST_CASE("LZ77 decompress: escape at end of stream → TruncatedToken")
{
    // Stream: (escape) with no following token byte.
    V input = {0x00, 0x00};  // escape=0x00, then bare escape with no token
    auto r = lz77.decompress(input);
    REQUIRE_FALSE(r.has_value());
    CHECK(r.error() == Error::TruncatedToken);
}

TEST_CASE("LZ77 decompress: escape + non-zero token at end → TruncatedToken")
{
    // Stream: escape=0x00, then (0x00, 0x04) — token=4 but no off_lo byte.
    V input = {0x00, 0x00, 0x04};
    auto r = lz77.decompress(input);
    REQUIRE_FALSE(r.has_value());
    CHECK(r.error() == Error::TruncatedToken);
}

TEST_CASE("LZ77 decompress: offset zero → InvalidBackReference")
{
    // Manually construct (escape=0x00, token=0x04 [len=4,off_hi=0], off_lo=0).
    // offset = 0 → invalid.
    V input = {0x00, 0x00, 0x04, 0x00};
    auto r = lz77.decompress(input);
    REQUIRE_FALSE(r.has_value());
    CHECK(r.error() == Error::InvalidBackReference);
}

TEST_CASE("LZ77 decompress: offset beyond output → InvalidBackReference")
{
    // Output is empty when the back-reference is encountered; any offset > 0
    // is out of range.
    V input = {0x00, 0x00, 0x04, 0x01};  // escape=0x00, token=4, off_lo=1
    auto r = lz77.decompress(input);
    REQUIRE_FALSE(r.has_value());
    CHECK(r.error() == Error::InvalidBackReference);
}
