/*	(Written in D programming language)

	Structs for handling Atari XL/XE binary loadable files.

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

module xebin.binary;

import std.array : join;
import std.conv;
import std.exception;
import std.stdio;
import std.string;

/// RUNAD. DOS jumps through it once the whole file has been loaded.
enum ushort runAd = 0x02E0;

/// INITAD. DOS calls through it as soon as the block that wrote it is loaded.
enum ushort initAd = 0x02E2;

ushort toUshort(in ubyte[] tab) pure nothrow @safe => cast(ushort) (tab[0] | (tab[1] << 8));

ubyte[] toBytes(ushort sh) pure nothrow @safe => [ cast(ubyte) (sh & 0xFF), sh >>> 8 ];

BinaryBlock makeInitBlock(ushort addr)
{
	return BinaryBlock(initAd, toBytes(addr));
}

BinaryBlock makeRunBlock(ushort addr)
{
	return BinaryBlock(runAd, toBytes(addr));
}

struct BinaryBlock
{
	ushort addr;
	ubyte[] data;

	ushort end() const
	{
		return cast(ushort) (addr + data.length - 1);
	}

	bool isValid() const
	{
		return data.length > 0 && addr + data.length <= 0xffff;
	}

	/// True if any byte of the two-byte vector at `vector` falls inside the block.
	bool touches(ushort vector) const
	{
		return data.length > 0
			&& addr <= vector + 1 && addr + data.length > vector;
	}

	/// True if the block supplies both bytes of the vector at `vector`.
	bool contains(ushort vector) const
	{
		return addr <= vector && addr + data.length >= vector + 2;
	}

	bool isRun() const
	{
		return touches(runAd);
	}

	bool isInit() const
	{
		return touches(initAd);
	}

	size_t length() const
	{
		return data.length;
	}

	BinaryBlock dup() const
	{
		return BinaryBlock(addr, data.dup);
	}

	ushort vectorAddress(ushort vector) const
	{
		if (!contains(vector))
			throw new Exception(format("Block does not contain the whole vector at %04X", vector));
		return toUshort(data[vector - addr .. vector - addr + 2]);
	}

	ushort initAddress() const
	{
		return vectorAddress(initAd);
	}

	ushort runAddress() const
	{
		return vectorAddress(runAd);
	}

	private string vectorString(ushort vector) const
	{
		string hexByte(uint a)
		{
			return a >= addr && a < addr + data.length
				? format("%02X", data[a - addr]) : "??";
		}
		return "$" ~ hexByte(vector + 1) ~ hexByte(vector);
	}

	string toString() const
	{
		auto s = format("%04X-%04X (%04X)%s", addr, addr + data.length - 1,
			data.length, isValid ? "" : " (Invalid!)");
		string[] notes;
		if (isInit)
			notes ~= "INIT " ~ vectorString(initAd);
		if (isRun)
			notes ~= "RUN " ~ vectorString(runAd);
		return notes.length ? s ~ "  ; " ~ notes.join(", ") : s;
	}

	bool opEquals(ref const(BinaryBlock) b) const
	{
		return addr == b.addr && data == b.data;
	}

	ubyte[] addrBytes(bool header = false) const
	{
		if (!isValid)
			throw new Exception("Invalid block");
		return cast(ubyte[])(header ? [ 0xFF, 0xFF ] : []) ~ .toBytes(addr) ~ .toBytes(cast(ushort) (addr + data.length - 1));
	}

	ubyte[] toBytes(bool header = false) const
	{
		if (!isValid)
			throw new Exception("Invalid block");
		return addrBytes(header) ~ data;
	}

	unittest
	{
		debug writeln("unittest BinaryBlock");
		auto run = BinaryBlock(0x2E0, [ 0x34, 0x12 ]);
		assert(run.isRun);
		assert(!run.isInit);
		assert(run.runAddress == 0x1234);
		assert(run.toBytes(true) == [ 0xFF, 0xFF, 0xE0, 0x02, 0xE1, 0x02, 0x34, 0x12 ]);
		assert(run.toString() == "02E0-02E1 (0002)  ; RUN $1234");

		auto ini = BinaryBlock(0x2E2, [ 0xCD, 0xAB ]);
		assert(ini.isInit);
		assert(!ini.isRun);
		assert(ini.initAddress == 0xABCD);
		assert(ini.toBytes(false) == [ 0xE2, 0x02, 0xE3, 0x02, 0xCD, 0xAB ]);
		assert(ini.toString() == "02E2-02E3 (0002)  ; INIT $ABCD");

		auto runini = BinaryBlock(0x2E0, [ 0xEF, 0x34, 0x56, 0x78 ]);
		assert(runini.isInit);
		assert(runini.isRun);
		assert(runini.toBytes(true) == [ 0xFF, 0xFF, 0xE0, 0x02, 0xE3, 0x02, 0xEF, 0x34, 0x56, 0x78 ]);
		assert(runini.toString() == "02E0-02E3 (0004)  ; INIT $7856, RUN $34EF");

		auto spanning = BinaryBlock(0x2DE, [ 0, 0, 0x00, 0x20, 0x00, 0x40, 0 ]);
		assert(spanning.isRun);
		assert(spanning.isInit);
		assert(spanning.runAddress == 0x2000);
		assert(spanning.initAddress == 0x4000);
		assert(spanning.toString() == "02DE-02E4 (0007)  ; INIT $4000, RUN $2000");

		auto partial = BinaryBlock(0x2E1, [ 0x99 ]);
		assert(partial.isRun);
		assert(!partial.isInit);
		assert(!partial.contains(runAd));
		assert(partial.toString() == "02E1-02E1 (0001)  ; RUN $99??");

		auto plain = BinaryBlock(0x2000, [ 0x60, 0x60 ]);
		assert(!plain.isRun);
		assert(!plain.isInit);
		assert(plain.toString() == "2000-2001 (0002)");

		assert(!BinaryBlock(0x2DE, [ 0, 0 ]).isRun);
		assert(!BinaryBlock(0x2E2, [ 0, 0 ]).isRun);
		assert(!BinaryBlock(0x2E4, [ 0, 0 ]).isInit);
	}
}

struct BinaryFileReader
{
	this(File f)
	{
		foreach (ubyte[] buf; f.byChunk(8192))
		{
			data_ ~= buf;
		}
	}

	this(string filename)
	{
		this(File(filename, "rb"));
	}

	BinaryBlock readBlock()
	{
		ushort start = 0xffff;
		ushort end = 0xffff;

		for (;;)
		{
			if (data_.length < 2)
				throw new Exception("Unexpected end of file");
			if (start == 0xffff)
			{
				start = toUshort(data_[0 .. 2]);
				data_ = data_[2 .. $];
			}
			else if (end == 0xffff)
			{
				end = toUshort(data_[0 .. 2]);
				data_ = data_[2 .. $];
				break;
			}
		}

		auto result = BinaryBlock(start);
		enforce(end >= start, "End address lesser than start address");
		auto l = end - start + 1;
		enforce(data_.length >= l, "Unexpected end of file");
		result.data = data_[0 .. l];
		data_ = data_[l .. $];
		return result;
	}

	BinaryBlock[] readFile()
	{
		BinaryBlock[] result;
		try
		{
			while (data_.length)
				result ~= readBlock();
		}
		catch (Exception e)
		{
			throw new Exception(e.msg ~ " (at block #" ~ to!string(result.length + 1) ~ ")");
		}
		return result;
	}

protected:
	ubyte[] data_;
}

struct BinaryFileWriter
{
	this(File f)
	{
		file_ = f;
	}

	this(string filename)
	{
		file_ = File(filename, "wb");
	}

	void writeHeader()
	{
		static ubyte[2] data = [ 0xff, 0xff ];
		file_.rawWrite(data);
	}

	void writeBlock(BinaryBlock block)
	{
		file_.rawWrite(block.addrBytes);
		file_.rawWrite(block.data);
	}

	void writeBlock(ushort addr, ubyte[] data)
	{
		writeBlock(BinaryBlock(addr, data));
	}

	void writeBlocks(BinaryBlock[] blocks)
	{
		foreach (block; blocks)
			if (block.length)
				writeBlock(block);
	}

	void writeFile(BinaryBlock block)
	{
		writeHeader();
		writeBlock(block);
	}

	void writeFile(BinaryBlock[] blocks)
	{
		writeHeader();
		writeBlocks(blocks);
	}

private:
	File file_;
}
