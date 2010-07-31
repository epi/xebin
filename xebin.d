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
import std.conv;
import std.getopt;

import binary;
import flashpack;

int address = 0xffff;
int position;
bool verbose;
string outputFile;
bool disableOs;

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
	@property File front() { return args[0].length ? File(args[0]) : stdin; }
	void popFront() { args = args[1 .. $]; }
}

void list(string[] args)
{
	auto of = openOutputFile();
	foreach (file; InputFiles(args))
	{
		if (args.length > 3)
			of.writeln(file.name, ":");
		foreach (i, blk; BinaryFileReader(file).readFile())
			of.writefln("%3d. %s", i, blk);
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
	auto bfw = BinaryFileWriter(openOutputFile());
	bfw.writeFile(blocks);
}

void merge(string[] args)
{
	BinaryBlock[] result;
	foreach (file; InputFiles(args))
		result ~= BinaryFileReader(file).readFile();
	listAndSaveResult(result);
}

void unpack(string[] args)
{
	BinaryBlock[] result;
	foreach (file; InputFiles(args))
		result ~= flashUnpack(BinaryFileReader(file).readFile());
	listAndSaveResult(result);
}

void pack(string[] args)
{
	BinaryBlock[] result;
	foreach (file; InputFiles(args))
		result ~= flashPack(BinaryFileReader(file).readFile(), disableOs, cast(ushort) (address < 0 ? -address : address), address < 0);
	listAndSaveResult(result);
}

void printHelp(string[] args)
{
	debug {} else write(
		"Atari XL/XE binary file utility\n" ~
		"\nUsage:\n" ~
		args[0] ~ " command [options] [input_file ...]\n" ~
		"\nThe following commands are available:\n" ~
		" l[ist]                              list blocks inside file\n" ~
		" m[erge]                             merge input files into single file\n" ~
		" p[ack]   [-a ad] [-s] [-o fn] [-v]  pack using FlashPack algorithm\n" ~
		" u[npack] [-o fn]                    unpack FlashPack'd file\n" ~
		" h[elp]                              print this message\n" ~
		"\nOptions:\n" ~
		" -o|--output fn           set output file name to fn (defaults to stdout)\n" ~
		" -a|--address [-]ad       set packed/boxed data address to ad\n" ~
		"                          (use '-' for end address)\n" ~
		" -n|--position pos        set block position for extract, delete, insert\n" ~
		"                          (indexed from 0)\n" ~
		" -s|--disable-os          make depacker running with OS ROM disabled\n" ~
		" -v|--verbose             emit some junk to stdout (requires output file\n" ~
		"                          to be specified)\n"
		"\nIf input file is not specified, stdin is used as input\n"
		);
}

int main(string[] args)
{
	getopt(args,
		config.caseSensitive,
		config.bundling,
		"s|disable-os", &disableOs,
		"a|address", &address,
		"n|position", &position,
		"v|verbose", &verbose,
		"o|output", &outputFile);

	if (args.length > 2)
	{
		auto funcs = [
			"help":&printHelp,
			"list":&list,
			"merge":&merge,
			"unpack":&unpack,
			"pack":&pack
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
	printHelp(args);
	return 1;
}
