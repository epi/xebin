/*	(Written in D programming language)

	Functions for compression and decompression of Atari XL/XE
	binary executables using FlashPack format.

	Author: Adrian Matoga epi@atari8.info
	
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

import std.stdio;
import std.stream;
import std.contracts;
import std.string;
import std.algorithm;
import std.range;
import std.typecons;

import fp21depktab;
import binary;

private
{
	static assert (Labels.fp21depk.START == Labels.fp21depk_noint.START);
	static assert (Labels.fp21depk.DEP1 == Labels.fp21depk_noint.DEP1);

	immutable depacker = cast(immutable(ubyte[])) import("fp21depk.obx");
	immutable depackerNoInt = cast(immutable(ubyte[])) import("fp21depk_noint.obx");

	immutable ushort[] depackerReloc = [
		Labels.fp21depk.RELOC_1, Labels.fp21depk.RELOC_2, Labels.fp21depk.RELOC_3, Labels.fp21depk.RELOC_4, 
		Labels.fp21depk.RELOC_5, Labels.fp21depk.RELOC_6, Labels.fp21depk.RELOC_7, Labels.fp21depk.RELOC_8, Labels.fp21depk.RELOC_9
	];

	immutable ushort[] depackerNoIntReloc = [
		Labels.fp21depk_noint.RELOC_1, Labels.fp21depk_noint.RELOC_2, Labels.fp21depk_noint.RELOC_3, Labels.fp21depk_noint.RELOC_4, 
		Labels.fp21depk_noint.RELOC_5, Labels.fp21depk_noint.RELOC_6, Labels.fp21depk_noint.RELOC_7, Labels.fp21depk_noint.RELOC_8, Labels.fp21depk_noint.RELOC_9
	];
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

	int j = 0;
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
	if (j - blocks.length > 0)
		result ~= packBlock(blocks[j .. blocks.length], disableOs, addr, endaddr);
	
	return result;
}

BinaryBlock[] flashUnpack(BinaryBlock[] blocks)
{
	BinaryBlock[] result;
	while (blocks.length >= 2)
	{
		if (blocks[1].addr != 0x2e2 && blocks[1].addr != 0x2e0 || blocks[1].length != 2)
		{
			result ~= blocks[0];
			blocks = blocks[1 .. $];
			continue;
		}
		auto runAddr = toUshort(blocks[1].data[0 .. 2]);
		auto blk = blocks[0];
		if (blk.addr <= runAddr && runAddr <= blk.addr + blk.length)
		{
			auto possibleDepacker = blk.data[runAddr - (Labels.fp21depk.START - Labels.fp21depk.DEP1) - blk.addr .. $];
			if ((possibleDepacker.length == depacker.length && depacker[0] == possibleDepacker[0])
				|| (possibleDepacker.length == depackerNoInt.length && depackerNoInt[0] == possibleDepacker[0]))
			{
				result ~= unpackBlock(blk);
				blocks = blocks[2 .. $];
				continue;
			}
		}
		result ~= blocks[0];
		blocks = blocks[1 .. $];
	}
	result ~= blocks;
	return result;
}

private
{
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
		void addDup(uint count)					{ addItem(true, 1, cast(ubyte) (count - 2)); }
		void addCopy(uint dist, bool three)		{ addItem(true, cast(ubyte) ((0x80 - dist) << 1) | three); }

		// identify packed items
		foreach (block; blocks)
		{
			if (block.isInit || block.isRun)
				throw new FlashPackException("Cannot pack " ~ (block.isInit ? "Init" : "Run") ~ " block");
			setAddr(block.addr, block.data[0]);
			ubyte[] src = block.data;

			int[uint] seqs;
			auto srcLength = src.length;
			
			struct SeqSearchResult { int dist; bool three; }

			SeqSearchResult sequencesAt(int i)
			{
				if (i <= srcLength - 2)
				{
					uint duple = src[i] | (src[i + 1] << 8);
					int dist;
					bool three;
					if (i <= srcLength - 3)
					{
						uint triple = 0x10000000U | duple | (src[i + 2] << 16);
						dist = i - seqs.get(triple, i);
						seqs[triple] = i;
					}
					if (!dist || dist > 127)
						dist = i - seqs.get(duple, i);
					else
						three = true;
					seqs[duple]	= i;
					return SeqSearchResult(dist, three);
				}
				return SeqSearchResult(0, false);
			}

			sequencesAt(0);
			foreach (int i; 1 .. srcLength)
			{
				// >=3 duplicate bytes
				uint cnt = min(256, srcLength - i);
				ubyte prevb = src[i - 1];
				foreach (int j; i .. i + cnt)
				{
					if (src[j] != prevb)
					{
						cnt = j - i;
						break;
					}
				}
				if (cnt > 3)
				{
					addDup(cnt);
					i += cnt - 1;
					sequencesAt(i);
					sequencesAt(i - 1);
					sequencesAt(i - 2);
					sequencesAt(i - 3);
					continue;
				}

				// repeated sequence of 2 or 3 bytes
				auto s = sequencesAt(i);
				if (s.dist && s.dist <= 127)
				{
					addCopy(s.dist, s.three);
					sequencesAt(++i);
					if (s.three)
						sequencesAt(++i);
					continue;
				}
				
				// nothing to squeeze
				addRaw(src[i]);
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
		auto result = BinaryBlock(0, blocks.toItems().toBytes());
		
		// auto set addr
		auto depk = disableOs ? depackerNoInt : depacker;
		int packedLength = result.length + depk.length;
		if (addr == 0xffff)
		{
			auto sblocks = remove!"a.addr > 0xbc20"(blocks.dup) ~ [ BinaryBlock(0xbc00) ];
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
		if (endaddr)
			addr = cast(ushort) (addr - packedLength + 1);
		result.addr = addr;

		// apend depacker
		auto dataLength = result.data.length;
		auto codeAddr = cast(ushort) (addr + dataLength);
		result.data ~= depk;
		auto depkView = result.data[dataLength .. $];
		auto dataAddrOffset = cast(ushort) ((disableOs ? Labels.fp21depk_noint.SRC_ADDR : Labels.fp21depk.SRC_ADDR) - Labels.fp21depk.DEP1);
		auto relocAddrs = disableOs ? depackerNoIntReloc : depackerReloc;

		depkView[dataAddrOffset .. dataAddrOffset + 2] = binary.toBytes(addr);
		foreach(ad; relocAddrs)
		{
			int a = ad - Labels.fp21depk.DEP1;
			depkView[a .. a + 2] = binary.toBytes(cast(ushort) (toUshort(depkView[a .. a + 2]) + codeAddr - Labels.fp21depk.DEP1)).dup;
		}
		
		return [ result, BinaryBlock(0x2e2, binary.toBytes(cast(ushort) (Labels.fp21depk_noint.START - Labels.fp21depk.DEP1 + codeAddr))) ];
	}

	BinaryBlock[] unpackBlock(BinaryBlock input)
	{
		BinaryBlock[] result;

		ubyte y;
		ushort ad;
		ushort dout = 0x8080;
		ushort din = input.addr;
		ubyte[] mem = new ubyte[65536];
		with (input)
			mem[addr .. addr + data.length] = data;
		result ~= BinaryBlock(dout);

		ubyte get() { return mem[din++]; }
		void setAdL(ubyte a) { ad = cast(ushort) ((ad & 0xff00u) | a); }
		void setAdH(ubyte a) { ad = cast(ushort) ((ad & 0xffu) | (a << 8)); }

		void setBlockAddr()
		{
			if (result[$ - 1].length == 0)
				result[$ - 1].addr = cast(ushort) (dout + y);
			else
				result ~= BinaryBlock(cast(ushort) (dout + y));
		}
		
		void setPutH(ubyte a)
		{
			dout = cast(ushort) ((dout & 0xffu) | (a << 8));
			setBlockAddr();
		}

		void put(ubyte a)
		{
			mem[dout + y] = a;
			result[$ - 1].data ~= a;
			++y;
			if (y == 0)
			{
				ad += 0x100;
				dout += 0x100;
			}
		}

		static struct Bits
		{
			ubyte f;
			int l = 8;
			@property bool empty() { return !l; }
			@property bool front() { return !!(f & 0x80); }
			void popFront() { --l; f <<= 1; }
		}

		for (;;)
		{
			foreach (ff; Bits(get()))
			{
				foreach (c; Bits(ff ? get() : 0))
				{
					ubyte a = get();
					if (!c)
						put(a);
					else if (!a)
					{
						y = get();
						setBlockAddr();
						a = get();
						setAdH(a);
						setPutH(a);
						put(get());
					}
					else
					{
						int x;
						if (a & 0xfe)
						{
							x = 2 + (a & 1);
							setAdL(a >>> 1);
						}
						else
						{
							x = get() + 2;
							if (x == 2)
								return result;
							setAdL(0x7f);
						}
						enforce(x >= 2 && x <= 256);
						do
						{
							put(mem[ad + y]);
						} while (--x);
					}
				}
			}
		}
	}
}

unittest
{
	auto blks1i = [ BinaryBlock(0x8000, cast(ubyte[]) x"80 80 80 80 80 80") ];
	auto blks1o = packBlock(blks1i, false, 0x2000);
	assert(blks1o[0].addr == 0x2000 && blks1o[0].data.startsWith(x"80 e0 00807f80 0103 0100"));
	auto blks1u = unpackBlock(blks1o[0]);
	assert(blks1i == blks1u);
}

unittest
{
	auto bb = BinaryBlock(0x3000);
	foreach_reverse (int i; 253 .. 258)
	{
		foreach (int j; 0 .. i + 1)
			bb.data ~= cast(ubyte) (257 - i);
	}
	assert(packBlock([ bb ])[0].data.startsWith(x"c0 ca 00802f00 01fe 00 01 01fe 02 01fd 03"));
}

unittest
{
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
	assert(packBlock([ bb ])[0].data.startsWith(x"80 8e 00807fab cd ef 80 0179 03 0100"));

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
	assert(packBlock([ bb ])[0].data.startsWith(x"c0 88 00807fab cd ef 80 017a ab cd ef 80 0100"));
}

unittest
{
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
