/** Runs SingleStepTests/65x02 against xebin CPU emulation.

	---
	git clone https://github.com/SingleStepTests/65x02 ext/65x02
	dub run :singlestep
	---

	Author: Adrian Matoga adrian@matoga.info

	zlib License:

	This software is provided 'as-is', without any express or implied
	warranty. In no event will the authors be held liable for any damages
	arising from the use of this software.

	Permission is granted to anyone to use this software for any purpose,
	including commercial applications, and to alter it and redistribute it
	freely, subject to the following restrictions:

	1. The origin of this software must not be misrepresented; you must not
	   claim that you wrote the original software. If you use this software
	   in a product, an acknowledgment in the product documentation would be
	   appreciated but is not required.
	2. Altered source versions must be plainly marked as such, and must not
	   be misrepresented as being the original software.
	3. This notice may not be removed or altered from any source
	   distribution.
*/

import std.algorithm : canFind, filter, map;
import std.array : appender;
import std.conv : to;
import std.file : exists, read;
import std.format;
import std.getopt;
import std.parallelism : parallel;
import std.path : buildPath;
import std.range : array, iota, split;
import std.stdio;
import std.string : strip;
import std.traits : EnumMembers;

import stdx.data.json;
import xebin.emu;

/*	Emits `TaggedAlgebraic.opEquals` into this object file.

	We never build a DOM, but importing the parser drags `JSONValue`'s TypeInfo
	in, and under separate compilation nobody instantiates the comparison it
	refers to -- so the link fails. Naming it here fixes that; without this,
	the subpackage only builds with `dub --combined`.
*/
private bool forceJSONValueOpEquals(const JSONValue a, const JSONValue b)
{
	return a == b;
}

struct Access
{
	ushort addr;
	ubyte value;
	bool write;

	string toString() const
	{
		return format("%s %04x %02x", write ? "W" : "R", addr, value);
	}
}

struct State
{
	ushort pc;
	ubyte sp, a, x, y, p;

	string toString() const
	{
		return format("pc=%04x s=%02x a=%02x x=%02x y=%02x p=%02x",
			pc, sp, a, x, y, p);
	}
}

struct Cell
{
	ushort addr;
	ubyte value;
}

struct TestCase
{
	string name;
	State initial, expected;
	Cell[] initialRam, expectedRam;
	Access[] cycles;
}

TestCase[] parseTests(string text)
{
	auto json = parseJSONStream(text);
	auto tests = appender!(TestCase[]);
	TestCase t;

	void readState(ref State s, ref Cell[] ram)
	{
		json.readObject((string key) {
			switch (key)
			{
			case "pc": s.pc = cast(ushort) json.readDouble(); break;
			case "s":  s.sp = cast(ubyte) json.readDouble(); break;
			case "a":  s.a = cast(ubyte) json.readDouble(); break;
			case "x":  s.x = cast(ubyte) json.readDouble(); break;
			case "y":  s.y = cast(ubyte) json.readDouble(); break;
			case "p":  s.p = cast(ubyte) json.readDouble() & ~0x10; break; // ignore p.b as it isn't stored in CPU
			case "ram":
				json.readArray({
					Cell c;
					size_t i;
					json.readArray({
						const n = cast(uint) json.readDouble();
						if (i++ == 0)
							c.addr = cast(ushort) n;
						else
							c.value = cast(ubyte) n;
					});
					ram ~= c;
				});
				break;
			default: json.skipValue(); break;
			}
		});
	}

	json.readArray({
		t = TestCase.init;
		json.readObject((string key) {
			switch (key)
			{
			case "name": t.name = json.readString(); break;
			case "initial": readState(t.initial, t.initialRam); break;
			case "final": readState(t.expected, t.expectedRam); break;
			case "cycles":
				json.readArray({
					Access acc;
					size_t i;
					json.readArray({
						switch (i++)
						{
						case 0: acc.addr = cast(ushort) json.readDouble(); break;
						case 1: acc.value = cast(ubyte) json.readDouble(); break;
						default: acc.write = json.readString() == "write"; break;
						}
					});
					t.cycles ~= acc;
				});
				break;
			default: json.skipValue(); break;
			}
		});
		tests ~= t;
	});
	return tests.data;
}

unittest
{
	auto tests = parseTests(`[
		{ "name": "b1 28 b5",
		  "initial": { "pc": 59082, "s": 39, "a": 57, "x": 33, "y": 174, "p": 96,
		    "ram": [ [59082, 177], [40, 160]]},
		  "final": { "pc": 59084, "s": 39, "a": 119, "x": 33, "y": 174, "p": 96,
		    "ram": [ [40, 160]]},
		  "cycles": [ [59082, 177, "read"], [40, 160, "write"]] }
		]`);
	assert(tests.length == 1);
	assert(tests[0].name == "b1 28 b5");
	assert(tests[0].initial == State(59082, 39, 57, 33, 174, 96));
	assert(tests[0].expected.a == 119);
	assert(tests[0].initialRam == [Cell(59082, 177), Cell(40, 160)]);
	assert(tests[0].cycles == [Access(59082, 177, false), Access(40, 160, true)]);
}

struct Result
{
	ubyte opcode;
	size_t total, failed;
}

Result runOpcode(CpuVariant v)(string path, ubyte opcode)
{
	Result r = { opcode: opcode };

	foreach (ref t; parseTests(cast(string) read(path)))
	{
	}

	return r;
}

struct Target
{
	string dir;
	CpuVariant cpu;
}

immutable Target[] targets = [
	Target("6502",          CpuVariant.mos_6502),
	Target("synertek65c02", CpuVariant.wdc_65c02),
	Target("rockwell65c02", CpuVariant.rockwell_r65c02),
	Target("wdc65c02",      CpuVariant.wdc_w65c02s),
];

size_t runTarget(CpuVariant v)(string dir, const(ubyte)[] opcodes)
{
	auto results = new Result[opcodes.length];
	foreach (i, opcode; opcodes.parallel)
	{
		const path = buildPath(dir, format("%02x.json", opcode));
		results[i] = exists(path)
			? runOpcode!v(path, opcode)
			: Result(opcode);
	}

	size_t failed;
	return failed;
}

ubyte[] parseOpcodes(string spec)
{
	if (!spec.length)
		return iota(256).map!(i => cast(ubyte) i).array;
	bool[256] set;
	foreach (part; spec.split(","))
	{
		const range = part.split("-").map!(a => a.to!uint(16)).array;
		const lo = range[0];
		const hi = range.length > 1 ? range[1] : lo;
		foreach (i; lo .. hi + 1)
			set[i] = true;
	}
	return iota(256).filter!(i => set[i]).map!(i => cast(ubyte) i).array;
}

unittest
{
	assert(parseOpcodes("a9") == [0xa9]);
	assert(parseOpcodes("b1-b5,00") == [0x00, 0xb1, 0xb2, 0xb3, 0xb4, 0xb5]);
	assert(parseOpcodes("").length == 256);
}

string findSuite(string dir)
{
	if (dir.length)
		return dir;
	foreach (candidate; ["ext/65x02", "../65x02", "65x02"])
		if (exists(buildPath(candidate, "6502", "v1")))
			return candidate;
	return null;
}

int main(string[] args)
{
	string dir;
	string cpuSpec;
	string opcodeSpec;

	auto help = getopt(args,
		"d|dir",     "root of SingleStepTests/65x02", &dir,
		"c|cpu",     "CPUs to test, comma separated (default: all found).", &cpuSpec,
		"o|opcodes", "Opcodes in hex, e.g. a9,1e,b1-b5 (default: all).", &opcodeSpec);

	if (help.helpWanted)
	{
		defaultGetoptPrinter(
			"Runs SingleStepTests/65x02 against xebin CPU emulator.\n", help.options);
		return 0;
	}

	const root = findSuite(dir);
	if (root is null)
	{
		stderr.writeln("no 65x02 test data found -- clone " ~
			"https://github.com/SingleStepTests/65x02 and pass --dir=<path>");
		return 2;
	}

	const opcodes = parseOpcodes(opcodeSpec);
	const cpus = cpuSpec.length ? cpuSpec.split(",") : null;

	size_t failed;
	size_t ran;
	foreach (target; targets)
	{
		if (cpus !is null && !cpus.canFind(target.dir) &&
			!cpus.canFind(target.cpu.to!string))
			continue;
		const dataDir = buildPath(root, target.dir, "v1");
		if (!exists(dataDir))
			continue;
		++ran;
		writefln("%s (%s)", target.cpu, target.dir);
		stdout.flush();
		dispatch: switch (target.cpu)
		{
			static foreach (v; EnumMembers!CpuVariant)
			{
			case v:
				failed += runTarget!v(dataDir, opcodes);
				break dispatch;
			}
		default:
			assert(0);
		}
	}

	if (!ran)
	{
		stderr.writefln("nothing to run -- no family member under %s matched --cpu", root);
		return 2;
	}
	writefln("%d opcode%s with failures", failed, failed == 1 ? "" : "s");

	return 0;
}
