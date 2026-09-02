/**	Instruction tracing for `xebin.emu.Emulator`.

	Plugged in as the emulator's tracing policy -- a template parameter, not a
	runtime flag -- so a build that does not want tracing carries none of this
	code and pays nothing for it. See `xebin.emu.NoTrace`.

	One line is emitted per instruction: the register file as it stood before
	the instruction ran, the disassembly, and then every memory access the
	instruction made, appended as it happens:

	----
	A=00 X=0A Y=00 S=FF P=--*-----  2006  65 80      ADC $80         R 0080 37
	----

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

module xebin.trace;

import std.array : Appender;
import std.format : formattedWrite;
import std.range : repeat, take;
import std.stdio;

version (unittest) import std.algorithm : canFind, startsWith;

import xebin.disasm;

/**	Tracing policy that prints one line per instruction.

	Use as `new Emulator!(CpuVariant.mos_6502, CpuTracer)`, then optionally
	point `tracer.sink` somewhere; it goes to stderr by default.
*/
struct CpuTracer
{
	/// Receives each finished line, without a terminator. Null means stderr.
	void delegate(const(char)[] line) sink;

	/// Column that memory accesses are aligned to, so they line up down the page.
	size_t accessColumn = 64;

	private Appender!(char[]) line;

	/// Called by the emulator once the opcode is fetched, pc still on it.
	void instruction(E)(E emu)
	{
		line.formattedWrite("A=%02X X=%02X Y=%02X S=%02X P=%s%s*-%s%s%s%s  ",
			emu.a, emu.x, emu.y, emu.sp,
			emu.nflag ? "N" : "-",
			emu.vflag ? "V" : "-",
			emu.dflag ? "D" : "-",
			emu.iflag ? "I" : "-",
			emu.zflag ? "Z" : "-",
			emu.cflag ? "C" : "-");
		ushort addr = emu.pc;
		line.put(disassembleOne(emu.ram, addr));
	}

	/**	Opcode and operand fetches are not shown: the disassembly on the same
		line already accounts for those bytes, so printing them again would
		bury the data accesses that are the interesting part.
	*/
	void fetch(ushort addr, ubyte value) {}

	/// Internal cycles carry no operand, so there is nothing to show.
	void idle(ushort addr) {}

	/// Called from `Emulator.ld`.
	void read(ushort addr, ubyte value)
	{
		pad();
		line.formattedWrite("R %04X %02X  ", addr, value);
	}

	/// Called from `Emulator.st`.
	void write(ushort addr, ubyte value)
	{
		pad();
		line.formattedWrite("W %04X %02X  ", addr, value);
	}

	/// Called once the instruction is complete; emits the accumulated line.
	void endInstruction()
	{
		if (!line.data.length)
			return;
		if (sink !is null)
			sink(line.data);
		else
			stderr.writeln(line.data);
		line.clear();
	}

	private void pad()
	{
		if (line.data.length < accessColumn)
			line.put(' '.repeat.take(accessColumn - line.data.length));
	}
}

unittest
{
	import xebin.emu;

	debug writeln("unittest CpuTracer");

	auto emu = new Emulator!(CpuVariant.mos_6502, CpuTracer)();
	string[] lines;
	emu.observer.sink = delegate void(const(char)[] l) { lines ~= l.idup; };

	// lda #$42 ; sta $80
	emu.ram[0x2000 .. 0x2005] = [ubyte(0xa9), 0x42, 0x85, 0x80, 0x00];
	emu.pc = 0x2000;
	emu.instructionLimit = 2;
	emu.run();

	assert(lines.length == 2, "one line per instruction");
	// registers as they were *before* each instruction, then the disassembly
	assert(lines[0].startsWith("A=00 X=00 Y=00 S=FF"));
	assert(lines[0].canFind("LDA #$42"));
	assert(lines[1].startsWith("A=42"), "second line sees the load's effect");
	assert(lines[1].canFind("STA $80"));
	// the store is reported as an access on the instruction that made it
	assert(lines[1].canFind("W 0080 42"));
	assert(!lines[0].canFind("W "), "no access on an immediate load");
}
