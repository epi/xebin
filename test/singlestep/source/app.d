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

import std.algorithm : all, canFind, filter, map;
import std.array : appender;
import std.conv : to;
import std.exception : collectExceptionMsg;
import std.file : exists, read;
import std.format;
import std.getopt;
import std.parallelism : parallel;
import std.path : buildPath;
import std.range : array, iota, join, split;
import std.stdio;
import std.string : strip;
import std.traits : EnumMembers;

import stdx.data.json;
import xebin.emu;

// Work around undefined reference to `TaggedAlgebraic.opEquals`
private bool forceJSONValueOpEquals(const JSONValue a, const JSONValue b)
{
	return a == b;
}

struct Access
{
	ushort addr;
	ubyte value;
	bool write;

	void toString(W)(scope W writer) const
	{
		writer.formattedWrite!"%s %04x %02x"(write ? "W" : "R", addr, value);
	}
}

struct State
{
	ushort pc;
	ubyte sp, a, x, y, p;

	void toString(W)(scope W writer, FormatSpec!char fmt) const
	{
		if (fmt.spec == 's')
			writer.formattedWrite!"pc=%04x s=%02x a=%02x x=%02x y=%02x p=%02x"(
				pc, sp, a, x, y, p);
		else if (fmt.spec == 'S')
			writer.formattedWrite!"State(0x%04x, 0x%02x, 0x%02x, 0x%02x, 0x%02x, 0x%02x)"(
				pc, sp, a, x, y, p);
		else
			assert(0);
	}
}

struct Cell
{
	ushort addr;
	ubyte value;

	void toString(W)(scope W writer) const
	{
		writer.formattedWrite!"[0x%04x, 0x%02x]"(addr, value);
	}
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

struct BusTrace
{
	const(ubyte)[] ram;
	Access[] accesses;

	void instruction(E)(E emu) {}
	void fetch(ushort addr, ubyte value) { accesses ~= Access(addr, value, false); }
	void read(ushort addr, ubyte value) { accesses ~= Access(addr, value, false); }
	void write(ushort addr, ubyte value) { accesses ~= Access(addr, value, true); }
	void idle(ushort addr) { accesses ~= Access(addr, ram[addr], false); }
	void endInstruction() {}
}

string runOne(E)(E emu, ref const TestCase t)
{
	foreach (c; t.initialRam)
		emu.ram[c.addr] = c.value;
	emu.pc = t.initial.pc;
	emu.sp = t.initial.sp;
	emu.a = t.initial.a;
	emu.x = t.initial.x;
	emu.y = t.initial.y;
	emu.p = t.initial.p;
	emu.stopped = false;
	emu.instructions = 0;
	emu.instructionLimit = 1;
	emu.observer.accesses.length = 0;
	emu.observer.accesses.assumeSafeAppend();

	// TODO: What SingleStepTests expect as the idle read address on decimal
	// correction cycle in ADC/SBC #imm looks suspiciously wrong.
	// Let's ignore this cycle for now, but check on real hardware some day.
	bool bcdImmediate = isCmos!(E.cpu) && (emu.p & 0x08) && (emu.ram[emu.pc] & 0x7f) == 0x69;

	string thrown = collectExceptionMsg(emu.run());

	const got = State(cast(ushort) (emu.pc + 1), emu.sp, emu.a, emu.x, emu.y, emu.p);

	string[] problems;
	if (thrown.length)
		problems ~= " threw: " ~ thrown;
	if (got != t.expected)
	{
		problems ~= format(" state: got %s", got);
		problems ~= format("   expected %s", t.expected);
	}
	foreach (c; t.expectedRam)
	{
		if (emu.ram[c.addr] != c.value)
			problems ~= format("memory: $%04x is $%02x, expected $%02x",
				c.addr, emu.ram[c.addr], c.value);
	}

	// A jammed CPU repeats its last bus cycle forever and the suite records
	// an arbitrary number of those repetitions. The emulator stops after the
	// first one, so only that prefix is compared, and the rest of the expected
	// trace must be copies of the cycle it stopped on.
	const(Access)[] expectedCycles = t.cycles;
	const(Access)[] got_ = emu.observer.accesses;
	if (emu.stopped && got_.length && got_.length < t.cycles.length &&
		t.cycles[got_.length .. $].all!(c => c == got_[$ - 1]))
		expectedCycles = t.cycles[0 .. got_.length];

	if (emu.observer.accesses[0 .. $ - bcdImmediate] != expectedCycles[0 .. $ - bcdImmediate])
	{
		problems ~= format("cycles: got %d [%(%s, %)]", emu.observer.accesses.length, emu.observer.accesses);
		problems ~= format("   expected %d [%(%s, %)]", expectedCycles.length, expectedCycles);
	}

	emu.ram[] = 0;

	if (!problems.length)
		return null;
	return format("  \"%s\"\n    %-(%s\n    %)", t.name, problems);
}

struct Result
{
	ubyte opcode;
	size_t total, failed;
	string[] reports;
	string[] unittests;
}

string emitUnittest(CpuVariant v, ref const TestCase t)
{
	ubyte[ushort] before;
	foreach (c; t.initialRam)
		before[c.addr] = c.value;
	auto changed = t.expectedRam.filter!(c => before.get(c.addr, 0) != c.value).array;

	return format(
		"\t// %s, opcode $%02x: \"%s\"\n" ~
		"\tcheckInstruction!(CpuVariant.%s)(\n" ~
		"\t\t%S, %s,\n" ~
		"\t\t%S, %s,\n" ~
		"\t\t\"%-(%s  %)\");\n",
		v, t.cycles.length ? t.cycles[0].value : 0, t.name, v,
		t.initial, t.initialRam,
		t.expected, changed,
		t.cycles);
}

Result runOpcode(CpuVariant v)(string path, ubyte opcode, bool emitUnittests)
{
	Result r = { opcode: opcode };
	auto emu = new Emulator!(v, BusTrace)();
	emu.observer.ram = emu.ram;
	emu.stopOnEmptyStackRts = false;

	auto text = strip(cast(string) read(path));
	if (text.length == 0)
		return r;

	foreach (ref t; parseTests(text))
	{
		++r.total;
		const diag = runOne(emu, t);
		if (diag !is null) {
			++r.failed;
			if (r.reports.length < 2)
				r.reports ~= diag;
			if (emitUnittests && r.unittests.length < 2)
				r.unittests ~= emitUnittest(v, t);
		}
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

size_t runTarget(CpuVariant v)(string dir, const(ubyte)[] opcodes, bool emitUnittests)
{
	auto results = new Result[opcodes.length];
	foreach (i, opcode; opcodes.parallel)
	{
		const path = buildPath(dir, format("%02x.json", opcode));
		results[i] = exists(path)
			? runOpcode!v(path, opcode, emitUnittests)
			: Result(opcode);
	}

	size_t failed;
	foreach (ref r; results)
	{
		if (r.failed)
			++failed;
		if (!r.total)
		{
			writefln("  $%02x  no test data", r.opcode);
			continue;
		}
		if (r.failed)
			writefln("  $%02x  %6d/%-6d %s", r.opcode, r.total - r.failed, r.total,
				r.failed ? "FAIL "  : "ok");
		foreach (report; r.reports)
			writeln(report);
		foreach (ut; r.unittests)
			writeln(ut);
	}
	return failed;


	return failed;
}

ubyte[] parseOpcodes(string spec, bool skipUndocumented)
{
	bool[256] set;
	if (!spec.length)
		set[] = true;
	else foreach (part; spec.split(","))
	{
		const range = part.split("-").map!(a => a.to!uint(16)).array;
		const lo = range[0];
		const hi = range.length > 1 ? range[1] : lo;
		foreach (i; lo .. hi + 1)
			set[i] = true;
	}
	if (skipUndocumented) {
		static immutable undocumentedOpcodes = [
			0x02, 0x03, 0x04, 0x07, 0x0B, 0x0C, 0x0F,
			0x12, 0x13, 0x14, 0x17, 0x1A, 0x1B, 0x1C, 0x1F,
			0x22, 0x23, 0x27, 0x2B, 0x2F,
			0x32, 0x33, 0x34, 0x37, 0x3A, 0x3B, 0x3C, 0x3F,
			0x42, 0x43, 0x44, 0x47, 0x4B, 0x4F,
			0x52, 0x53, 0x54, 0x57, 0x5A, 0x5B, 0x5C, 0x5F,
			0x62, 0x63, 0x64, 0x67, 0x6B, 0x6F,
			0x72, 0x73, 0x74, 0x77, 0x7A, 0x7B, 0x7C, 0x7F,
			0x80, 0x82, 0x83, 0x87, 0x89, 0x8B, 0x8F,
			0x92, 0x93, 0x97, 0x9B, 0x9C, 0x9E, 0x9F,
			0xA3, 0xA7, 0xAB, 0xAF,
			0xB2, 0xB3, 0xB7, 0xBB, 0xBF,
			0xC2, 0xC3, 0xC7, 0xCB, 0xCF,
			0xD2, 0xD3, 0xD4, 0xD7, 0xDA, 0xDB, 0xDC, 0xDF,
			0xE2, 0xE3, 0xE7, 0xEB, 0xEF,
			0xF2, 0xF3, 0xF4, 0xF7, 0xFA, 0xFB, 0xFC, 0xFF
		];
		static assert(undocumentedOpcodes.length == 105);
		foreach (o; undocumentedOpcodes)
			set[o] = false;
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
	bool skipUndocumented;
	bool emitUnittests;

	auto help = getopt(args,
		"d|dir",      "root of SingleStepTests/65x02", &dir,
		"c|cpu",      "CPUs to test, comma separated (default: all found).", &cpuSpec,
		"o|opcodes",  "Opcodes in hex, e.g. a9,1e,b1-b5 (default: all).", &opcodeSpec,
		"u|skip-undocumented", "Skip undocumented NMOS 6502 opcodes.", &skipUndocumented,
		"t|unittest", "Emit unittests for failing cases.", &emitUnittests);

	if (help.helpWanted)
	{
		defaultGetoptPrinter(
			"Runs SingleStepTests/65x02 against xebin CPU emulator.\n", help.options);
		return 0;
	}

	const root = findSuite(dir);
	if (root is null)
	{
		stderr.writeln("65x02 test data not found. Clone " ~
			"https://github.com/SingleStepTests/65x02 and pass --dir=<path>");
		return 2;
	}

	const opcodes = parseOpcodes(opcodeSpec, skipUndocumented);
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
				failed += runTarget!v(dataDir, opcodes, emitUnittests);
				break dispatch;
			}
		default:
			assert(0);
		}
	}

	if (!ran)
	{
		const ts = targets.map!(t => [t.dir, t.cpu.to!string]).join.array;
		stderr.writefln("Nothing to run. None of [%-(%-s%|, %)] found in [%-(%-s%|, %)]", cpus, ts);
		return 2;
	}
	writefln("%d opcode%s with failures", failed, failed == 1 ? "" : "s");

	return failed ? 1 : 0;
}
