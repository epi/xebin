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

import std.stdio;
import std.string;
import std.conv;

ushort toUshort(ubyte[] tab)
{
	return cast(ushort) (tab[0] | (tab[1] << 8));
}

ubyte[] toBytes(ushort sh)
{
	ubyte[] tab = new ubyte[2];
	tab[0] = sh & 0xFF;
	tab[1] = sh >>> 8;
	return tab;
}

struct BinaryBlock
{
	ushort addr;
	ubyte[] data;

	@property bool isValid()
	{
		return data.length > 0 && addr + data.length <= 0xffff;
	}

	@property bool isRun()
	{
		return addr == 0x2E0 && (data.length == 2 || data.length == 4);
	}
	
	@property bool isInit()
	{
		return (addr == 0x2E2 && data.length == 2) || (addr == 0x2E0 && data.length == 4);
	}

	@property size_t length()
	{
		return data.length;
	}

	@property BinaryBlock dup()
	{
		return BinaryBlock(addr, data.dup);
	}

	@property ushort initAddress()
	{
		if (!isInit)
			throw new Exception("Not an init block");
		return toUshort(data[0x2E2 - addr .. 0x2E2 - addr + 2]);
	}

	@property ushort runAddress()
	{
		if (!isRun)
			throw new Exception("Not a run block");
		return toUshort(data[0x2E0 - addr .. 0x2E0 - addr + 2]);
	}

	string toString()
	{
		if (isInit || isRun)
			return 
				(isInit ? format("Init %04X" ~ (isRun ? ", " : ""), initAddress) : "")
				~ (isRun ? format("Run %04X", runAddress) : "");
		return format("%04X-%04X (%04X)%s", addr, addr + data.length - 1, data.length, isValid ? "" : " (Invalid!)");
	}
	
	const bool opEquals(ref const(BinaryBlock) b)
	{
		return addr == b.addr && data == b.data;
	}

	ubyte[] addrBytes(bool header = false)
	{
		if (!isValid)
			throw new Exception("Invalid block");
		return cast(ubyte[])(header ? [ 0xFF, 0xFF ] : []) ~ .toBytes(addr) ~ .toBytes(cast(ushort) (addr + data.length - 1));
	}

	ubyte[] toBytes(bool header = false)
	{
		if (!isValid)
			throw new Exception("Invalid block");
		return addrBytes(header) ~ data;
	}

	unittest
	{
		auto run = BinaryBlock(0x2E0, [ 0x34, 0x12 ]);
		assert(run.isRun);
		assert(!run.isInit);
		assert(run.toBytes(true) == [ 0xFF, 0xFF, 0xE0, 0x02, 0xE1, 0x02, 0x34, 0x12 ]);
		assert(run.toString() == "Run 1234");
		
		auto ini = BinaryBlock(0x2E2, [ 0xCD, 0xAB ]);
		assert(ini.isInit);
		assert(!ini.isRun);
		assert(ini.toBytes(false) == [ 0xE2, 0x02, 0xE3, 0x02, 0xCD, 0xAB ]);
		assert(ini.toString() == "Init ABCD");
		
		auto runini = BinaryBlock(0x2E0, [ 0xEF, 0x34, 0x56, 0x78 ]);
		assert(runini.isInit);
		assert(runini.isRun);
		assert(runini.toBytes(true) == [ 0xFF, 0xFF, 0xE0, 0x02, 0xE3, 0x02, 0xEF, 0x34, 0x56, 0x78 ]);
		assert(runini.toString() == "Init 7856, Run 34EF");
	}
}

struct BinaryFileReader
{
	this(File f)
	{
		file_ = f;
		auto pos = file_.tell();
		file_.seek(0, SEEK_END);
		length_ = file_.tell();
		file_.seek(pos);
	}

	this(string filename)
	{
		this(File(filename, "rb"));
	}

	BinaryBlock readBlock()
	{
		ubyte[2] data;
		ushort start = 0xffff;
		ushort end = 0xffff;

		for (;;)
		{
			if (file_.rawRead(data).length != 2)
				throw new Exception("Unexpected  end of file");
			if (start == 0xffff)
				start = toUshort(data);
			else if (end == 0xffff)
			{
				end = toUshort(data);
				break;
			}
		}
		
		auto result = BinaryBlock(start);
		if (end - start + 1 > 0)
			result.data.length = end - start + 1;
		else
			throw new Exception("End address lesser than start address");
		
		if (file_.rawRead(result.data).length != result.data.length)
			throw new Exception("Unexpected end of file");

		return result;
	}
	
	BinaryBlock[] readFile()
	{
		BinaryBlock[] result;
		try
		{
			while (file_.tell() < length_)
				result ~= readBlock();
		}
		catch (Exception e)
		{
			throw new Exception(e.msg ~ " (at block #" ~ to!string(result.length + 1) ~ ")");
		}
		return result;
	}

protected:
	File file_;
	ulong length_;
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

	void writePoke(ushort addr, ubyte value)
	{
		writeBlock(addr, [ value ]);
	}

	void writeDPoke(ushort addr, ushort value)
	{
		writeBlock(addr, .toBytes(value));
	}

	void writeRun(ushort addr)
	{
		writeDPoke(0x2e0, addr);
	}
	
	void writeInit(ushort addr)
	{
		writeDPoke(0x2e1, addr);
	}

private:
	File file_;
}
