/**	(Written in D programming language)

	Functions for compression and decompression of Atari XL/XE
	binary executables using FlashPack format.

	Author: Adrian Matoga epi@atari8.info
	Includes FlashPack depacking routines by Piotr Fusik.

	Poetic License:

	This work 'as-is' we provide.
	No warranty express or implied.
	We've done our best,
	to debug and test.
	Liability for damages denied.

	Permission is granted hereby,
	to copy, share, and modify.
	Use as is fit,
	free or for profit.
	These rights, on this notice, rely.
*/

module xebin.flashpack;

import std.stdio;
import std.exception;
import std.string;
import std.algorithm;
import std.range;
import std.typecons;

import xebin.binary;
import xebin.xasm;

enum CompressionMethod
{
	NONE,
	FLASHPACK_10,
	FLASHPACK_21,
	FLASHPACK_21_OS_DISABLED,
}

class FlashPackException : Exception
{
	this(string m)
	{
		super(m);
	}
}

BinaryBlock[] flashPack(BinaryBlock[] blocks, bool disableOs = false, ushort addr = 0xffff, bool endaddr = false)
{
	BinaryBlock[] result;

	size_t j = 0;
	foreach (i, ref blk; blocks)
	{
		if (blk.isRun || blk.isInit)
		{
			if (j - i > 0)
				result ~= packBlock(blocks[j .. i], disableOs, addr, endaddr);
			result ~= blk;
			j = i + 1;
		}
	}
	// blocks at the end without init / run
	if (j - blocks.length > 0)
		result ~= packBlock(blocks[j .. blocks.length], disableOs, addr, endaddr);

	return result;
}

BinaryBlock[] flashUnpack(BinaryBlock[] blocks)
{
	BinaryBlock[] result;
	while (blocks.length)
	{
		switch (detectCompressionMethod(blocks))
		{
		case CompressionMethod.FLASHPACK_10:
			result ~= unpackBlock(blocks[0], true);
			blocks = blocks[2 .. $];
			break;
		case CompressionMethod.FLASHPACK_21:
		case CompressionMethod.FLASHPACK_21_OS_DISABLED:
			result ~= unpackBlock(blocks[0], false);
			blocks = blocks[2 .. $];
			break;
		default:
			result ~= blocks[0];
			blocks = blocks[1 .. $];
		}
	}
	return result;
}

CompressionMethod detectCompressionMethod(BinaryBlock[] blocks)
{
	if (blocks.length < 2)
		return CompressionMethod.NONE;
	if (blocks[1].addr != 0x2e2 && blocks[1].addr != 0x2e0 || blocks[1].length != 2)
		return CompressionMethod.NONE;

	auto runAddr = toUshort(blocks[1].data[0 .. 2]);
	auto blk = blocks[0];
	if (blk.addr == runAddr)
	{
		auto xasm = new Xasm;
		xasm.defineLabel("ADDRESS", blk.addr + DepackerLength.FLASHPACK_10);
		xasm.defineLabel("CODEADDR", blk.addr);
		xasm.assemblyString(depackerSrc10);
		if (xasm.result[] == blk.data[0 .. xasm.result.length])
			return CompressionMethod.FLASHPACK_10;
	}
	if (blk.addr <= runAddr && runAddr < blk.addr + blk.length)
	{
		if (blk.length > DepackerLength.FLASHPACK_21)
		{
			auto xasm = new Xasm;
			xasm.defineLabel("ADDRESS", blk.addr);
			xasm.defineLabel("CODEADDR", cast(int) (blk.addr + blk.length - DepackerLength.FLASHPACK_21));
			xasm.defineLabel("OS_DISABLED", 0);
			xasm.assemblyString(depackerSrc21);
			if (xasm.result[] == blk.data[blk.length - DepackerLength.FLASHPACK_21 .. $])
				return CompressionMethod.FLASHPACK_21;
		}
		
		if (blk.length > DepackerLength.FLASHPACK_21_OS_DISABLED)
		{
			auto xasm = new Xasm;
			xasm.defineLabel("ADDRESS", blk.addr);
			xasm.defineLabel("CODEADDR", cast(int) (blk.addr + blk.length - DepackerLength.FLASHPACK_21_OS_DISABLED));
			xasm.defineLabel("OS_DISABLED", 1);
			xasm.assemblyString(depackerSrc21);
			if (xasm.result[] == blk.data[blk.length - DepackerLength.FLASHPACK_21_OS_DISABLED .. $])
				return CompressionMethod.FLASHPACK_21_OS_DISABLED;
		}
	}
	return CompressionMethod.NONE;
}

private:

struct Item
{
	bool special;
	ubyte[] data;
}

Item[] toItems(BinaryBlock[] blocks)
{
	Item[] items;

	void addItem(bool special, ubyte[] bytes ...)
	{
		items ~= Item(special, bytes.dup);
	}

	void addRaw(ubyte b)					{ addItem(false, b); }
	void setAddr(ushort addr, ubyte first)	{ addItem(true, 0, (addr - 0x80) & 0xff, ((addr - 0x80) >>> 8) & 0xff, first); }
	void addDup(size_t count)				{ addItem(true, 1, cast(ubyte) (count - 2)); }
	void addCopy(uint dist, bool three)		{ addItem(true, cast(ubyte) ((0x80 - dist) << 1) | three); }

	foreach (block; blocks)
	{
		if (block.isInit || block.isRun)
			throw new FlashPackException("Cannot pack " ~ (block.isInit ? "Init" : "Run") ~ " block");
	}

	foreach (block; blocks)
	{
		const src = block.data;
		const srclen = cast(uint) src.length;

		auto dict = iota(srclen - 2)
			.array
			.sort!((i, j) => src[i .. i + 2] < src[j .. j + 2]);

		setAddr(block.addr, src[0]);

		for (uint i = 1; i < srclen; )
		{
			// a byte repeated 3 or more times
			ubyte prevb = src[i - 1];
			const cnt = src[i .. $].take(256).until!"a != b"(prevb).count;
			if (cnt > 3)
			{
				addDup(cast(uint) cnt);
				i += cnt;
				continue;
			}

			// same sequence of 2 or 3 bytes found up to 127 bytes behind
			size_t maxlen = 0;
			uint dist;
			if (srclen - i >= 2)
			{
				foreach (j, len; dict.equalRange(i)
					.filter!(j => i - j <= 127 && i != j)
					.map!(j => tuple(j, commonPrefix(src[i .. $].take(3), src[j .. $]).length)))
				{
					if (len > maxlen)
					{
						maxlen = len;
						dist = i - j;
						if (len == 3)
							break;
					}
				}
			}
            if (maxlen >= 2)
			{
				addCopy(dist, maxlen == 3);
				i += maxlen;
				continue;
			}

			// nothing to squeeze
			addRaw(src[i++]);
		}
	}

	// mark end of packed data
	addItem(true, 1, 0);

	return items;
}

ubyte[] toBytes(Item[] items)
{
	ubyte[] result;
	immutable itemsLength = items.length;
	for (size_t i = 0; i < itemsLength; i += 64)
	{
		ubyte outerFlags;
		ubyte[] outerData;
		auto outerChunk = items[i .. min(i + 64, itemsLength)];
		immutable outerChunkLength = outerChunk.length;
		for (size_t j = 0; j < outerChunkLength; j += 8)
		{
			ubyte innerFlags;
			auto innerChunk = outerChunk[j .. min(j + 8, outerChunkLength)];
			foreach (k; 0 .. innerChunk.length)
				if (innerChunk[k].special)
					innerFlags |= (0x80 >>> k);
			if (innerFlags)
			{
				outerData ~= innerFlags;
				outerFlags |= (0x80 >>> (j / 8));
			}
			foreach (k; 0 .. innerChunk.length)
				outerData ~= innerChunk[k].data;
		}
		result ~= outerFlags;
		result ~= outerData;
	}
	return result;
}

BinaryBlock[] packBlock(BinaryBlock[] blocks, bool disableOs = false, ushort addr = 0xffff, bool endaddr = false)
{
	// pack
	auto result = BinaryBlock(0, blocks.toItems().toBytes());
	size_t packedLength = result.length + (disableOs ? DepackerLength.FLASHPACK_21_OS_DISABLED : DepackerLength.FLASHPACK_21);
	
	// auto set addr
	if (addr == 0xffff)
	{
		auto b = BinaryBlock(0xbc20);
		b.data ~= 0;
		auto sblocks = blocks ~ b;
		b = BinaryBlock(0x1000);
		b.data ~= 0;
		sblocks ~= b;
		sort!"a.addr > b.addr"(sblocks);
		foreach (i, ref blk; sblocks[1 .. $])
		{
			if (blk.addr + blk.length + packedLength <= sblocks[i].addr && sblocks[i].addr - packedLength >= 0x400)
			{
				addr = cast(ushort) (sblocks[i].addr - 1);
				endaddr = true;
				break;
			}
		}
	}
	if (addr == 0xffff)
		throw new FlashPackException("Cannot automatically set packed data address");

	// set address
	if (endaddr)
		addr = cast(ushort) (addr - packedLength + 1);
	result.addr = addr;

	// append depacker
	auto xasm = new Xasm;
	xasm.defineLabel("ADDRESS", result.addr);
	xasm.defineLabel("CODEADDR", cast(int) (result.addr + result.length));
	xasm.defineLabel("OS_DISABLED", disableOs ? 1 : 0);
	xasm.assemblyString(depackerSrc21);
	result.data ~= xasm.result;

	return [ result, makeInitBlock(cast(ushort) (xasm.labels["START"].value)) ];
}

struct Bits
{
	ubyte f;
	int l = 8;
	@property bool empty() { return !l; }
	@property bool front() { return !!(f & 0x80); }
	void popFront() { --l; f <<= 1; }
}

BinaryBlock[] unpackBlock(BinaryBlock input, bool oldFormat = false)
{
	BinaryBlock[] result;

	ushort din = cast(ushort) (oldFormat ? input.addr + 0x5e : input.addr);
	ushort dinEnd = cast(ushort) (input.addr + input.length);
	ushort dout;
	ubyte[] mem = new ubyte[65536];
	with (input)
		mem[addr .. addr + data.length] = data;

	ubyte get()
	{
		if (din >= dinEnd)
			throw new FlashPackException("Error in packed data");
		return mem[din++];
	}

	void put(ubyte a)
	{
		if (result.length == 0)
			throw new FlashPackException("Error in packed data");
		result[$ - 1].data ~= a;
		mem[dout + 0x80] = a;
		dout++;
	}

	for (;;)
	{
		auto k = get();
		foreach (fb; Bits(k))
		{
			ubyte g = fb ? get() : 0;
			foreach (fc; Bits(g))
			{
				auto a = get();
				if (!fc)
				{
					put(a);
				}
				else
				{
					if (a & 0xfe)
					{
						uint m = a >> 1;
						put(mem[dout + m]);
						put(mem[dout + m]);
						if (a & 1)
							put(mem[dout + m]);
					}
					else
					{
						auto b = get();
						if (a & 1)
						{
							if (!oldFormat)
							{
								if (!b)
									return result;
								b += 2;
							}
							auto dup = mem[dout + 0x7F];
							foreach (i; 0 .. b)
								put(dup);
						}
						else
						{
							dout = cast(ushort) (b + 256 * get());
							if (dout + 0x80 >= input.addr && dout + 0x80 < input.addr + 0x5e)
								return result;
							else
								result ~= BinaryBlock(cast(ushort) (dout + 0x80));
							put(get());
						}
					}
				}
			}
		}
	}
}

static immutable string depackerSrc21 = "

ff	equ	$fc
bt	equ	$fd
ad	equ	$fe

	opt h-
	org CODEADDR

dep1	tax
	beq	exit
	lda	#$7f
dep2	bcc	*+3
	inx
	inx
	sta	ad
dep3	lda	(ad),y
put	sta	$8080,y
	iny
	bne	dep4
	inc	ad+1
	inc	put+2
dep4	dex
	bne	dep3
	asl	bt
	bne	dep7
	asl	ff
	bne	dep5

start
	ift OS_DISABLED
	sei
	inc	$d40e
	lda #$fe
	sta $d301
	eif
	sec
	jsr	get
	rol	@
	sta	ff
dep5	lda	#1
	bcc	dep6
	jsr	get
	rol	@
dep6	sta	bt
dep7	jsr	get
	ldx	#1
	bcc	put
	lsr	@
	bne	dep2
	jsr	get
	bcs	dep1
	tay
	jsr	get
	sta	ad+1
	sta	put+2
	bcc	dep7 !

get	lda	ADDRESS
	inc	get+1
	bne	ret
	inc	get+2
ret
	ift !OS_DISABLED
exit rts
	els
	rts
exit inc $d301
	lsr	$d40e
	cli
	rts
	eif
	";

static immutable string depackerSrc10 = "

	opt h-
	org CODEADDR

	ldy #$80
	sty $FB
	sty	$FC

loop
	asl $FC
	bne do
	asl $FB
	bne sblk

	jsr get
	rol @
	sta $FB

sblk
	lda #$01
	bcc rblk
	jsr get
	rol @
rblk
	sta $FC

do	jsr get
	ldx #$01
	bcc raw
	lsr @
	beq setad

	bcc two
	inx
two	inx
copy
	sta $FD
cploop
	ldy $FD
	lda ($FE),y
	ldy #$80
raw	sta ($FE),y
	inc $FE
	sne:inc $FF
	dex
	bne cploop
	bpl loop

setad
	jsr get
	tax
	lda #$7F
	bcs copy
	jsr get
	stx $FE
	sta $FF
	bcc do
		
get	lda ADDRESS
	inc get+1
	sne:inc get+2
ret	rts
	";

enum DepackerLength
{
	FLASHPACK_10 = 0x5e,
	FLASHPACK_21 = 0x5a,
	FLASHPACK_21_OS_DISABLED = 0x6b,
}

unittest
{
	debug writeln("unittest DepackerLength.FLASHPACK_21");
	auto xasm = new Xasm();
	xasm.defineLabel("ADDRESS", 0x805a);
	xasm.defineLabel("CODEADDR", 0x8000);
	xasm.defineLabel("OS_DISABLED", 0);
	xasm.assemblyString(depackerSrc21);
	assert(xasm.result.length == DepackerLength.FLASHPACK_21);
}

unittest
{
	debug writeln("unittest DepackerLength.FLASHPACK_21_OS_DISABLED");
	auto xasm = new Xasm();
	xasm.defineLabel("ADDRESS", 0x806b);
	xasm.defineLabel("CODEADDR", 0x8000);
	xasm.defineLabel("OS_DISABLED", 1);
	xasm.assemblyString(depackerSrc21);
	assert(xasm.result.length == DepackerLength.FLASHPACK_21_OS_DISABLED);
}

unittest
{
	debug writeln("unittest DepackerLength.FLASHPACK_10");
	auto xasm = new Xasm();
	xasm.defineLabel("ADDRESS", 0x805e);
	xasm.defineLabel("CODEADDR", 0x8000);
	xasm.assemblyString(depackerSrc10);
	assert(xasm.result.length == DepackerLength.FLASHPACK_10);
}

unittest
{
	debug writeln("unittest packBlock/unpackBlock");
	auto blks1i = [ BinaryBlock(0x8000, cast(ubyte[]) x"80 80 80 80 80 80") ];
	auto blks1o = packBlock(blks1i, false, 0x2000);
	assert(blks1o[0].addr == 0x2000 && blks1o[0].data.startsWith(cast(ubyte[]) x"80 e0 00807f80 0103 0100"));
	auto blks1u = unpackBlock(blks1o[0]);
	assert(blks1i == blks1u);
}

unittest
{
	debug writeln("unittest packBlock dup");
	auto bb = BinaryBlock(0x3000);
	foreach_reverse (int i; 253 .. 258)
	{
		foreach (int j; 0 .. i + 1)
			bb.data ~= cast(ubyte) (257 - i);
	}
	assert(packBlock([ bb ])[0].data.startsWith(cast(ubyte[]) x"c0 ca 00802f00 01fe 00 01 01fe 02 01fd 03"));
}

unittest
{
	debug writeln("unittest packBlock copy");

	auto bb = BinaryBlock(0x8000, cast(ubyte[])
		(x"abcdef808080808080808080808080" ~
		x"80808080808080808080808080808080" ~
		x"80808080808080808080808080808080" ~
		x"80808080808080808080808080808080" ~
		x"80808080808080808080808080808080" ~
		x"80808080808080808080808080808080" ~
		x"80808080808080808080808080808080" ~
		x"80808080808080808080808080808080" ~
		x"abcdef"));
	assert(packBlock([ bb ])[0].data.startsWith(cast(ubyte[]) x"80 8e 00807fab cd ef 80 0179 03 0100"));

	bb = BinaryBlock(0x8000, cast(ubyte[])
		(x"abcdef80808080808080808080808080" ~
		x"80808080808080808080808080808080" ~
		x"80808080808080808080808080808080" ~
		x"80808080808080808080808080808080" ~
		x"80808080808080808080808080808080" ~
		x"80808080808080808080808080808080" ~
		x"80808080808080808080808080808080" ~
		x"80808080808080808080808080808080" ~
		x"abcdef"));
	assert(packBlock([ bb ])[0].data.startsWith(cast(ubyte[]) x"c0 88 00807fab cd ef 80 017a ab cd ef 80 0100"));
}

unittest
{
	debug writeln("unittest flashPack/flashUnpack");

	auto bb = BinaryBlock(0x2000);
	foreach (ubyte i; 0 .. 200)
	{
		bb.data ~= i | 0x80;
		foreach (ubyte j; 0 .. i)
			bb.data ~= i;
		bb.data ~= i & 1 ? x"abcd" : x"abefcd";
	}
	auto packed = flashPack([ bb ]);
	auto unpacked = flashUnpack(packed);
	assert(unpacked == [ bb ]);
}

