/*	(Written in D programming language)

	xebin - Atari XL/XE Binary File Utility
	Command line interface for modules binary and flashpack.

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
import std.ascii;
import std.conv;
import std.getopt;

import xebin.binary;
import xebin.flashpack;
import xebin.disasm;
import xebin.emu;

int address = 0xffff;
int position;
bool verbose;
string outputFile;
bool disableOs;
bool removeHeader;

immutable VERSION_STRING = "1.1.0";

File openOutputFile()
{
	if (outputFile.length)
		return File(outputFile, "wb");
	return stdout;
}

struct InputFiles
{
	string[] args;

	this(string[] args)
	{
		this.args = args[2 .. $];
		if (!this.args.length)
			this.args ~= "";
	}

	@property bool empty() { return !args.length; }
	@property File front() { auto q = args[0].length ? File(args[0], "rb") : stdin; return q; }
	void popFront() { args = args[1 .. $]; }
}

void list(string[] args)
{
	auto of = openOutputFile();
	foreach (file; InputFiles(args))
	{
		if (args.length > 3)
			of.writefln("\n%s:", file.name);
		auto blocks = BinaryFileReader(file).readFile();
		foreach (i, blk; blocks)
		{
			of.writef("%3d. %s", i, blk);
			with (CompressionMethod)
			{
				auto cm = detectCompressionMethod(blocks[i .. $]);
				switch (cm)
				{
				case FLASHPACK_10:
					of.writeln(" (FlashPack 1.0)");
					break;
				case FLASHPACK_21:
					of.writeln(" (FlashPack 2.1)");
					break;
				case FLASHPACK_21_OS_DISABLED:
					of.writeln(" (FlashPack 2.1, OS ROM disabled)");
					break;
				default:
					of.writeln();
				}
				if (verbose && (cm == FLASHPACK_10 || cm == FLASHPACK_21 || cm == FLASHPACK_21_OS_DISABLED))
				{
					auto unp = flashUnpack(blocks[i .. i + 2]);
					foreach (j, ublk; unp)
					{
						writefln("    %3d. %s", j, ublk);
					}
				}
			}
		}
			
	}
}

void listAndSaveResult(BinaryBlock[] blocks)
{
	if (verbose && outputFile.length)
	{
		writeln(outputFile, ":");
		foreach (i, blk; blocks)
			writefln("%3d. %s", i, blk);
	}
	BinaryFileWriter(openOutputFile()).writeFile(blocks);
}

void merge(string[] args)
{
	BinaryBlock[] result;
	foreach (file; InputFiles(args))
		result ~= BinaryFileReader(file).readFile();
	listAndSaveResult(result);
}

void extract(string[] args)
{
	BinaryBlock[] blocks;
	foreach (file; InputFiles(args))
	{
		uint bn = 0;
		blocks = BinaryFileReader(file).readFile();
		while (position > 0 && bn < blocks.length)
		{
			bn++;
			position--;
		}
		if (bn >= blocks.length)
			continue;
		
		if (verbose && outputFile.length)
		{
			writeln(file.name, ":");
			writefln("%3d. %s", bn, blocks[bn]);
		}
		auto of = openOutputFile();
		if (removeHeader)
			of.rawWrite(blocks[bn].data);
		else
			BinaryFileWriter(of).writeFile(blocks[bn]);
		return;
	}
	throw new Exception("Nothing to extract");
}

void unpack(string[] args)
{
	BinaryBlock[] result;
	foreach (file; InputFiles(args))
		result ~= flashUnpack(BinaryFileReader(file).readFile());
	listAndSaveResult(result);
}

long getSize(BinaryBlock[] blocks)
{
	long result = 2; // FFFF header
	foreach (blk; blocks)
		result += 4 + blk.length;
	return result;
}

void pack(string[] args)
{
	BinaryBlock[] result;
	long unpackedSize;
	foreach (file; InputFiles(args))
	{
		auto inblocks = BinaryFileReader(file).readFile();
		unpackedSize += inblocks.getSize();
		result ~= flashPack(inblocks, disableOs, cast(ushort) (address < 0 ? -address : address), address < 0);
	}
	listAndSaveResult(result);
	long packedSize = result.getSize();
	if (verbose && outputFile.length)
	{
		writefln("\nInput:  %12d bytes", unpackedSize);
		writefln(  "Packed: %12d bytes", packedSize);
		writefln(  "Gain:   %12d %%", 100 - (packedSize * 100 / unpackedSize));
	}
}

void disassembly(string[] args)
{
	auto of = openOutputFile();
	foreach (file; InputFiles(args))
	{
		if (args.length > 3)
			of.writeln("; ", file.name, ":");

		foreach (line; BinaryFileReader(file).readFile().disassemble)
		{
			of.writeln(line);
		}
	}
}

void run(string[] args)
{
	auto blocks = BinaryFileReader(InputFiles(args).front).readFile();
	auto emu = new Emulator();
	emu.ioTrace = ioTrace;
	emu.cpuTrace = cpuTrace;
	emu.loadAndRun(blocks);
}

void printHelp(string[] args)
{
	write(
		"Atari XL/XE binary file utility " ~ VERSION_STRING ~ "\n" ~
		"\nUsage:\n" ~
		args[0] ~ " command [options] [input_file ...]\n" ~
		"\nThe following commands are available:\n" ~
		" l[ist]                                list blocks inside file\n" ~
		" m[erge]   [-o=fn] [-v]                merge input files into single file\n" ~
		" e[xtract] [-n=pos] [-r] [-o=fn] [-v]  extract block\n" ~
/+ TODO:
		" r[emove]  [-n=pos] [-o=fn] [-v]       remove block from file\n" ~
		" i[nsert]  [-n=pos] [-a=ad] [-o=fn] [-v]  insert block into file\n" ~ 
		" o[ptimize] [-o=fn] [-i]               optimize file\n +/
		" d[isasm]  [-o=fn]                     disassemble blocks\n" ~
		" r[un]                                 run in a simple emulator\n" ~
		" p[ack]    [-a=ad] [-s] [-o=fn] [-v]   pack using FlashPack algorithm\n" ~
		" u[npack]  [-o=fn] [-v]                unpack FlashPack'd file\n" ~
		" h[elp]                                print this message\n" ~
		"\nOptions:\n" ~
		" -o|--output=fn           set output file name to fn (defaults to stdout)\n" ~
//		" -a|--address=[-]ad       set packed/boxed data address to ad\n" ~
		" -a|--address=[-]ad       set packed data address to ad\n" ~
		"                          (use '-' for end address)\n" ~
		" -n|--position=pos        which block to extract (indexed from 0)\n" ~
		" -r|--raw                 remove header from extracted block\n" ~
//		" -i|--ignore-order        do not preserve order of block if it makes\n" ~
//		"                          optimized file shorter\n" ~
//		" -n|--position=pos        set block position for extract, delete, insert\n" ~
//		"                          (indexed from 0)\n" ~
		" -s|--disable-os          make depacker running with OS ROM disabled\n" ~
		" -v|--verbose             emit some junk to stdout (requires output file\n" ~
		"                          to be specified)\n" ~
		"\nIf input file is not specified, stdin is used as input.\n" ~
		"\n'=' character between option name and its parameter may be skipped.\n"
		);
}

int parseInt(string n)
{
	bool minus;
	uint base = 10;
	int result;

	if (n.startsWith('-'))
	{
		n = n[1 .. $];
		minus = true;
	}
	if (n.startsWith('$'))
	{
		n = n[1 .. $];
		base = 16;
	}
	else if (n.startsWith("0x") || n.startsWith("0X"))
	{
		n = n[2 .. $];
		base = 16;
	}
	
	foreach (k; n.toUpper())
	{
		uint digit = uint.max;
		char c = to!char(k);
		if (c >= '0' && c <= '9')
			digit = c - '0';
		else if (c >= 'A' && c <= 'Z')
			digit = c - ('A' - 10);
		if (digit >= base)
			throw new Exception("Invalid number");
		
		result = result * base + digit;
	}
	
	return minus ? -result : result;
}

bool cpuTrace;
bool ioTrace;

int main(string[] args)
{
	version(unittest) { return 0; }
	else
	{
		try
		{
			string strAddr;

			getopt(args,
				config.caseSensitive,
				config.noBundling,
				"s|disable-os", &disableOs,
				"trace-cpu", &cpuTrace,
				"trace-cio", &ioTrace,
				"a|address", &strAddr,
				"n|position", &position,
				"r|raw", &removeHeader,
				"v|verbose", &verbose,
				"o|output", &outputFile);

			if (strAddr !is null)
				address = parseInt(strAddr);

			if (args.length >= 2)
			{
				auto funcs = [
					"help":&printHelp,
					"list":&list,
					"extract":&extract,
					"merge":&merge,
					"unpack":&unpack,
					"pack":&pack,
					"disasm":&disassembly,
					"run":&run
					];
				foreach (cmd, fun; funcs)
				{
					if (cmd.startsWith(args[1]))
					{
						fun(args);
						return 0;
					}
				}
			}
		}
		catch (Exception e)
		{
			writeln("Error: ", e.msg);
			return 1;
		}
		printHelp(args);
		return 1;
	}
}
