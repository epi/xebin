/*	Simple 65(c)02 disassembler.

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

module xebin.disasm;

import std.algorithm : any, equal, sort, uniq;
import std.array : array, appender;
import std.format : format, formattedWrite;
import std.range : assumeSorted, SortedRange;
import std.traits : EnumMembers;

import xebin.binary;
public import xebin.cpu : Cpu;
import xebin.cpu : isCmos, hasBitOps, hasWaiStp;

///	Disassembles the instruction at `addr`, advancing `addr` past it.
string disassembleOne(const(ubyte[]) memory, ref ushort addr,
	Cpu cpu = Cpu.mos_6502)
{
	auto app = appender!string;
	const op = opcodes(cpu)[memory[addr]];
	const len = instructionLength(op.mode);
	app.formattedWrite("%04X  ", addr);
	foreach (i; 0 .. len)
		app.formattedWrite("%02X ", memory[(addr + i) & 0xffff]);
	foreach (i; len .. 3)
		app.put("   ");
	app.put("  ");
	app.put(op.mnem);
	const b1 = memory[(addr + 1) & 0xffff];
	const b2 = memory[(addr + 2) & 0xffff];
	final switch (op.mode) with (Mode)
	{
	case implied:
		break;
	case accumulator:
		app.put(" @");
		break;
	case immediate:
		app.formattedWrite(" #$%02X", b1);
		break;
	case zeroPage:
		app.formattedWrite(" $%02X", b1);
		break;
	case zeroPageX:
		app.formattedWrite(" $%02X,X", b1);
		break;
	case zeroPageY:
		app.formattedWrite(" $%02X,Y", b1);
		break;
	case indirectX:
		app.formattedWrite(" ($%02X,X)", b1);
		break;
	case indirectY:
		app.formattedWrite(" ($%02X),Y", b1);
		break;
	case zeroPageIndirect:
		app.formattedWrite(" ($%02X)", b1);
		break;
	case absolute:
		app.formattedWrite(" $%04X", b1 | (b2 << 8));
		break;
	case absoluteX:
		app.formattedWrite(" $%04X,X", b1 | (b2 << 8));
		break;
	case absoluteY:
		app.formattedWrite(" $%04X,Y", b1 | (b2 << 8));
		break;
	case indirect:
		app.formattedWrite(" ($%04X)", b1 | (b2 << 8));
		break;
	case absoluteIndirectX:
		app.formattedWrite(" ($%04X,X)", b1 | (b2 << 8));
		break;
	case relative:
		app.formattedWrite(" $%04X", (addr + 2 + cast(byte) b1) & 0xffff);
		break;
	case zeroPageRelative:
		app.formattedWrite(" $%02X,$%04X", b1,
			(addr + 3 + cast(byte) b2) & 0xffff);
		break;
	}
	addr += len;
	return app.data;
}

unittest
{
	ushort addr = 0xFFFD;
	ubyte[0x10000] memory;
	memory[0xFFFD .. $] = [ 0xa9, 0x42, 0x8d ];
	memory[0 .. 6] = [ 0xad, 0xde, 0xd0, 0xfb, 0x60, 0x02 ];
	assert(disassembleOne(memory, addr) == "FFFD  A9 42      LDA #$42");
	assert(disassembleOne(memory, addr) == "FFFF  8D AD DE   STA $DEAD");
	assert(disassembleOne(memory, addr) == "0002  D0 FB      BNE $FFFF");
	assert(disassembleOne(memory, addr) == "0004  60         RTS");
	assert(disassembleOne(memory, addr) == "0005  02         JAM");
}

unittest
{
	// NMOS undocumented instructions come out under their common names
	ushort addr = 0x1000;
	ubyte[0x10000] memory;
	memory[0x1000 .. 0x1005] = [ 0x07, 0x12, 0xbf, 0x34, 0x12 ];
	assert(disassembleOne(memory, addr) == "1000  07 12      SLO $12");
	assert(disassembleOne(memory, addr) == "1002  BF 34 12   LAX $1234,Y");
}

unittest
{
	// 65C02
	ushort addr = 0x2000;
	ubyte[0x10000] memory;
	memory[0x2000 .. 0x200c] =
		[ 0x64, 0x12, 0xb2, 0x80, 0x7c, 0x00, 0x30, 0x80, 0xf7, 0x1a, 0xcb, 0xcb ];
	with (Cpu)
	{
		assert(disassembleOne(memory, addr, wdc_65c02) == "2000  64 12      STZ $12");
		assert(disassembleOne(memory, addr, wdc_65c02) == "2002  B2 80      LDA ($80)");
		assert(disassembleOne(memory, addr, wdc_65c02) == "2004  7C 00 30   JMP ($3000,X)");
		assert(disassembleOne(memory, addr, wdc_65c02) == "2007  80 F7      BRA $2000");
		assert(disassembleOne(memory, addr, wdc_65c02) == "2009  1A         INC @");
		// WAI exists on the W65C02S only; elsewhere its slot is a NOP
		assert(disassembleOne(memory, addr, wdc_65c02) == "200A  CB         NOP");
		assert(disassembleOne(memory, addr, wdc_w65c02s) == "200B  CB         WAI");
	}
}

unittest
{
	// Rockwell bit instructions: zp + relative in one operand
	ushort addr = 0x2000;
	ubyte[0x10000] memory;
	memory[0x2000 .. 0x2005] = [ 0x87, 0x12, 0x2f, 0x12, 0xfb ];
	with (Cpu)
	{
		assert(disassembleOne(memory, addr, rockwell_r65c02) == "2000  87 12      SMB0 $12");
		assert(disassembleOne(memory, addr, rockwell_r65c02) == "2002  2F 12 FB   BBR2 $12,$2000");
		// NOPs on plain 65C02
		addr = 0x2000;
		assert(disassembleOne(memory, addr, wdc_65c02) == "2000  87 12      NOP $12");
		assert(disassembleOne(memory, addr, wdc_65c02) == "2002  2F 12 FB   NOP $FB12");
	}
}

/// Returns an `opApply` iterator that emits disassembly one line at a time as `const(char)[]`.
auto disassemble(in BinaryBlock[] blocks, Cpu cpu = Cpu.mos_6502)
{
	return Disassembler(blocks, cpu);
}

private version(unittest)
string[] disassembleToStrings(in BinaryBlock[] blocks, Cpu cpu = Cpu.mos_6502)
{
	auto app = appender!(string[]);
	foreach (l; blocks.disassemble(cpu))
	{
		app.put(l.idup);
	}
	return app.data;
}

unittest
{
	// label from run/init address
	auto bb = [
		BinaryBlock(0x2000, cast(ubyte[]) x"90 02 a9 20 20 ad de"),
		BinaryBlock(0x02e0, cast(ubyte[]) x"00 20 00 40")
	];
	assert(bb.disassembleToStrings.equal([
			"L4000\tEQU $4000",
			"LDEAD\tEQU $DEAD",
			"\tORG $2000",
			"L2000\tBCC L2004",
			"\tLDA #$20",
			"L2004\tJSR LDEAD",
			"\tORG $02E0",
			"\tDTA A(L2000)",
			"\tDTA A(L4000)"
		]));
}

unittest
{
	// reference to mid-instruction, unfinished instruction
	auto bb = [
		BinaryBlock(0x2100, cast(ubyte[]) x"8d 04 21 4c 00 21 0d"),
	];
	assert(bb.disassembleToStrings.equal([
			"\tORG $2100",
			"L2100\tSTA L2103+1",
			"L2103\tJMP L2100",
			"\tDTA $0D"
		]));
}

unittest
{
	// zero page
	auto bb = [
		BinaryBlock(0x2100, cast(ubyte[]) x"85 85 8d 8d 00"),
	];
	assert(bb.disassembleToStrings.equal([
			"L0085\tEQU $0085",
			"L008D\tEQU $008D",
			"\tORG $2100",
			"\tSTA L0085",
			"\tSTA A:L008D"
		]));
}

unittest
{
	// 65C02 with labels in both operands of BBRn
	auto bb = [
		BinaryBlock(0x3000, cast(ubyte[]) x"80 02 64 12 0f 12 fb 7c 00 30"),
	];
	assert(bb.disassembleToStrings(Cpu.rockwell_r65c02).equal([
			"L0012\tEQU $0012",
			"\tORG $3000",
			"L3000\tBRA L3004",
			"L3002\tSTZ L0012",
			"L3004\tBBR0 L0012,L3002",
			"\tJMP (L3000,X)"
		]));
	// $0f becomes data on other chips
	assert(bb.disassembleToStrings(Cpu.wdc_65c02).equal([
			"L0012\tEQU $0012",
			"L00FB\tEQU $00FB",
			"\tORG $3000",
			"L3000\tBRA L3004",
			"\tSTZ L0012",
			"L3004\tDTA $0F",
			"\tORA (L00FB)",
			"\tJMP (L3000,X)"
		]));
}

private:

struct Disassembler
{
	this(in BinaryBlock[] blocks, Cpu cpu)
	{
		m_blocks = blocks;
		m_cpu = cpu;
		m_instrSpans = {
			auto app = appender!(Span[]);
			foreach (block; blocks)
			{
				foreach (addr, kind, bytes; instructionSplitter(block, cpu))
					app.put(Span(addr, cast(ushort) (addr + bytes.length - 1)));
			}
			return app.data.sort;
		}();
		m_labeledAddresses = {
			auto app = appender!(ushort[]);
			void put(ushort addr)
			{
				app.put(alignToInstr(addr));
			}
			foreach (block; blocks)
			{
				if (block.contains(runAd))
					put(block.runAddress);
				if (block.contains(initAd))
					put(block.initAddress);
				foreach (addr, kind, const bytes; instructionSplitter(block, cpu))
				{
					switch (kind) with (ItemKind)
					{
					case dataAddr:
						put(bytes[].peek!ushort);
						break;
					case code:
						final switch (opcodes(cpu)[bytes[0]].mode) with (Mode)
						{
						case relative:
							put(cast(ushort) (addr + 2 + cast(byte) bytes[1]));
							break;
						case zeroPage: case zeroPageX: case zeroPageY:
						case indirectX: case indirectY: case zeroPageIndirect:
							put(bytes[1]);
							break;
						case absolute: case absoluteX: case absoluteY:
						case indirect: case absoluteIndirectX:
							put(bytes[1 .. $].peek!ushort);
							break;
						case zeroPageRelative:
							put(bytes[1]);
							put(cast(ushort) (addr + 3 + cast(byte) bytes[2]));
							break;
						case implied: case accumulator: case immediate:
							break;
						}
						break;
					default:
					}
				}
			}
			return app.data.sort.uniq.array.assumeSorted;
		}();
	}

	@disable this(this);
	@disable void opAssign(Disassembler);

	int opApply(scope int delegate(const(char)[] line) dg)
	{
		uint[ushort] labels;

		auto app = appender!(char[]);

		int put(A...)(auto ref A a)
		{
			app.formattedWrite(a);
			int res = dg(app.data);
			if (!res)
				app.clear();
			return res;
		}

		void declareLabel(ushort addr)
		{
			const cnt = labels[addr]++;
			app.formattedWrite("L%04X", addr);
			if (cnt)
				app.formattedWrite("_%d", cnt);
			app.put('\t');
		}

		void putAddr(ushort addr)
		{
			const a = alignToInstr(addr);
			auto r = m_labeledAddresses.equalRange(a);
			if (r.empty)
				app.formattedWrite("$%04X", addr);
			else if (a == addr)
				app.formattedWrite("L%04X", addr);
			else
				app.formattedWrite("L%04X+%d", a, addr - a);
		}

		void putAbsolute(ushort addr)
		{
			if (addr < 0x100)
				app.put("A:");
			putAddr(addr);
		}

		foreach (la; m_labeledAddresses)
		{
			if (!m_blocks.any!(b => Span(b.addr, b.end).overlaps(Span(la, la))))
			{
				declareLabel(la);
				if (auto res = put("EQU $%04X", la, la))
					return res;
			}
		}

		foreach (block; m_blocks)
		{
			if (auto res = put("\tORG $%04X", block.addr))
				return res;
			foreach (addr, kind, bytes; instructionSplitter(block, m_cpu))
			{
				auto r = m_labeledAddresses.equalRange(addr);
				if (!r.empty)
					app.formattedWrite("L%04X", addr);
				app.put('\t');
				if (kind == ItemKind.dataAddr)
				{
					app.put("DTA A(");
					putAddr(bytes[].peek!ushort);
					app.put(')');
				}
				else if (kind == ItemKind.data)
				{
					app.formattedWrite("DTA $%02X", bytes[0]);
				}
				else
				{
					const op = opcodes(m_cpu)[bytes[0]];
					app.put(op.mnem);
					final switch (op.mode) with (Mode)
					{
					case implied:
						break;
					case accumulator:
						app.put(" @");
						break;
					case immediate:
						app.formattedWrite(" #$%02X", bytes[1]);
						break;
					case zeroPage:
						app.put(' ');
						putAddr(bytes[1]);
						break;
					case zeroPageX:
						app.put(' ');
						putAddr(bytes[1]);
						app.put(",X");
						break;
					case zeroPageY:
						app.put(' ');
						putAddr(bytes[1]);
						app.put(",Y");
						break;
					case indirectX:
						app.put(" (");
						putAddr(bytes[1]);
						app.put(",X)");
						break;
					case indirectY:
						app.put(" (");
						putAddr(bytes[1]);
						app.put("),Y");
						break;
					case zeroPageIndirect:
						app.put(" (");
						putAddr(bytes[1]);
						app.put(')');
						break;
					case absolute: case absoluteX: case absoluteY:
						app.put(' ');
						putAbsolute(bytes[1 .. $].peek!ushort);
						if (op.mode == absoluteX)
							app.put(",X");
						else if (op.mode == absoluteY)
							app.put(",Y");
						break;
					case indirect:
						app.put(" (");
						putAddr(bytes[1 .. $].peek!ushort);
						app.put(')');
						break;
					case absoluteIndirectX:
						app.put(" (");
						putAddr(bytes[1 .. $].peek!ushort);
						app.put(",X)");
						break;
					case relative:
						app.put(' ');
						putAddr(cast(ushort) (addr + 2 + cast(byte) bytes[1]));
						break;
					case zeroPageRelative:
						app.put(' ');
						putAddr(bytes[1]);
						app.put(',');
						putAddr(cast(ushort) (addr + 3 + cast(byte) bytes[2]));
						break;
					}
				}
				if (auto res = dg(app.data))
					return res;
				app.clear();
			}
		}

		return 0;
	}

private:
	const(BinaryBlock)[] m_blocks;
	Cpu m_cpu;
	SortedRange!(Span[]) m_instrSpans;
	SortedRange!(ushort[]) m_labeledAddresses;

	static struct Span
	{
		ushort begin;
		ushort end;
		int opCmp(Span rhs) pure nothrow const @safe
		{
			if (begin <= rhs.end && rhs.begin <= end)
				return 0;
			if (begin < rhs.begin)
				return -1;
			return 1;
		}
		bool overlaps(Span rhs) const pure nothrow @safe
		{
			return this.opCmp(rhs) == 0;
		}
	}

	ushort alignToInstr(ushort addr)
	{
		auto r = m_instrSpans.equalRange(Span(addr, addr));
		if (r.empty)
			return addr;
		return r.front.begin;
	}
}

T peek(T, R)(auto ref R r)
{
	import std.bitmanip : stdpeek = peek;
	import std.system : Endian;
	return stdpeek!(T, Endian.littleEndian, R)(r);
}

enum Mode : ubyte
{
	implied,
	accumulator,
	immediate,
	zeroPage,
	zeroPageX,
	zeroPageY,
	indirectX,
	indirectY,
	zeroPageIndirect,
	absolute,
	absoluteX,
	absoluteY,
	indirect, // JMP
	absoluteIndirectX, // JMP ($1234,X)
	relative,
	zeroPageRelative, // BBRn/BBSn $12,$3456
}

uint instructionLength(Mode mode) @safe pure nothrow @nogc
{
	final switch (mode) with (Mode)
	{
	case implied: case accumulator:
		return 1;
	case immediate: case zeroPage: case zeroPageX: case zeroPageY:
	case indirectX: case indirectY: case zeroPageIndirect: case relative:
		return 2;
	case absolute: case absoluteX: case absoluteY: case indirect:
	case absoluteIndirectX: case zeroPageRelative:
		return 3;
	}
}

struct Op
{
	string mnem = "JAM";
	Mode mode = Mode.implied;
	// code in trace, data in block disassembly
	bool documented = false;
}

Op[256] buildOpcodes(Cpu cpu)() @safe pure
{
	Op[256] t;
	bool[256] used;

	void def(int opcode, string mnem, Mode mode = Mode.implied, bool documented = true)
	{
		assert(!used[opcode], format!"opcode %02X defined twice"(opcode));
		used[opcode] = true;
		t[opcode] = Op(mnem, mode, documented);
	}

	foreach (i, m; ["ORA", "AND", "EOR", "ADC", "STA", "LDA", "CMP", "SBC"])
	{
		const b = cast(int) i * 0x20;
		def(b + 0x01, m, Mode.indirectX);
		def(b + 0x05, m, Mode.zeroPage);
		if (m != "STA")
			def(b + 0x09, m, Mode.immediate);
		def(b + 0x0d, m, Mode.absolute);
		def(b + 0x11, m, Mode.indirectY);
		def(b + 0x15, m, Mode.zeroPageX);
		def(b + 0x19, m, Mode.absoluteY);
		def(b + 0x1d, m, Mode.absoluteX);
		static if (isCmos!cpu)
			def(b + 0x12, m, Mode.zeroPageIndirect);
	}

	foreach (i, m; ["ASL", "ROL", "LSR", "ROR"])
	{
		const b = cast(int) i * 0x20;
		def(b + 0x06, m, Mode.zeroPage);
		def(b + 0x0a, m, Mode.accumulator);
		def(b + 0x0e, m, Mode.absolute);
		def(b + 0x16, m, Mode.zeroPageX);
		def(b + 0x1e, m, Mode.absoluteX);
	}
	def(0xc6, "DEC", Mode.zeroPage);
	def(0xd6, "DEC", Mode.zeroPageX);
	def(0xce, "DEC", Mode.absolute);
	def(0xde, "DEC", Mode.absoluteX);
	def(0xe6, "INC", Mode.zeroPage);
	def(0xf6, "INC", Mode.zeroPageX);
	def(0xee, "INC", Mode.absolute);
	def(0xfe, "INC", Mode.absoluteX);

	foreach (i, m; ["BPL", "BMI", "BVC", "BVS", "BCC", "BCS", "BNE", "BEQ"])
		def(cast(int) i * 0x20 + 0x10, m, Mode.relative);

	def(0xa2, "LDX", Mode.immediate);
	def(0xa6, "LDX", Mode.zeroPage);
	def(0xb6, "LDX", Mode.zeroPageY);
	def(0xae, "LDX", Mode.absolute);
	def(0xbe, "LDX", Mode.absoluteY);
	def(0xa0, "LDY", Mode.immediate);
	def(0xa4, "LDY", Mode.zeroPage);
	def(0xb4, "LDY", Mode.zeroPageX);
	def(0xac, "LDY", Mode.absolute);
	def(0xbc, "LDY", Mode.absoluteX);
	def(0x86, "STX", Mode.zeroPage);
	def(0x96, "STX", Mode.zeroPageY);
	def(0x8e, "STX", Mode.absolute);
	def(0x84, "STY", Mode.zeroPage);
	def(0x94, "STY", Mode.zeroPageX);
	def(0x8c, "STY", Mode.absolute);
	def(0xe0, "CPX", Mode.immediate);
	def(0xe4, "CPX", Mode.zeroPage);
	def(0xec, "CPX", Mode.absolute);
	def(0xc0, "CPY", Mode.immediate);
	def(0xc4, "CPY", Mode.zeroPage);
	def(0xcc, "CPY", Mode.absolute);

	def(0x24, "BIT", Mode.zeroPage);
	def(0x2c, "BIT", Mode.absolute);

	def(0x00, "BRK");
	def(0x20, "JSR", Mode.absolute);
	def(0x40, "RTI");
	def(0x4c, "JMP", Mode.absolute);
	def(0x60, "RTS");
	def(0x6c, "JMP", Mode.indirect);

	def(0x08, "PHP");
	def(0x28, "PLP");
	def(0x48, "PHA");
	def(0x68, "PLA");
	def(0x18, "CLC");
	def(0x38, "SEC");
	def(0x58, "CLI");
	def(0x78, "SEI");
	def(0xb8, "CLV");
	def(0xd8, "CLD");
	def(0xf8, "SED");
	def(0x88, "DEY");
	def(0xc8, "INY");
	def(0xca, "DEX");
	def(0xe8, "INX");
	def(0x8a, "TXA");
	def(0xaa, "TAX");
	def(0x98, "TYA");
	def(0xa8, "TAY");
	def(0x9a, "TXS");
	def(0xba, "TSX");
	def(0xea, "NOP");

	static if (!isCmos!cpu)
	{
		foreach (i, m; ["SLO", "RLA", "SRE", "RRA", "", "", "DCP", "ISC"])
		{
			if (!m.length)
				continue;
			const b = cast(int) i * 0x20;
			def(b + 0x03, m, Mode.indirectX, false);
			def(b + 0x07, m, Mode.zeroPage, false);
			def(b + 0x0f, m, Mode.absolute, false);
			def(b + 0x13, m, Mode.indirectY, false);
			def(b + 0x17, m, Mode.zeroPageX, false);
			def(b + 0x1b, m, Mode.absoluteY, false);
			def(b + 0x1f, m, Mode.absoluteX, false);
		}
		def(0x83, "SAX", Mode.indirectX, false);
		def(0x87, "SAX", Mode.zeroPage, false);
		def(0x8f, "SAX", Mode.absolute, false);
		def(0x97, "SAX", Mode.zeroPageY, false);
		def(0x93, "SHA", Mode.indirectY, false);
		def(0x9f, "SHA", Mode.absoluteY, false);
		def(0x9b, "TAS", Mode.absoluteY, false);
		def(0x9c, "SHY", Mode.absoluteX, false);
		def(0x9e, "SHX", Mode.absoluteY, false);
		def(0xa3, "LAX", Mode.indirectX, false);
		def(0xa7, "LAX", Mode.zeroPage, false);
		def(0xaf, "LAX", Mode.absolute, false);
		def(0xb3, "LAX", Mode.indirectY, false);
		def(0xb7, "LAX", Mode.zeroPageY, false);
		def(0xbf, "LAX", Mode.absoluteY, false);
		def(0xab, "LXA", Mode.immediate, false);
		def(0xbb, "LAS", Mode.absoluteY, false);
		def(0x0b, "ANC", Mode.immediate, false);
		def(0x2b, "ANC", Mode.immediate, false);
		def(0x4b, "ALR", Mode.immediate, false);
		def(0x6b, "ARR", Mode.immediate, false);
		def(0x8b, "ANE", Mode.immediate, false);
		def(0xcb, "SBX", Mode.immediate, false);
		def(0xeb, "SBC", Mode.immediate, false);
		foreach (op; [0x1a, 0x3a, 0x5a, 0x7a, 0xda, 0xfa])
			def(op, "NOP", Mode.implied, false);
		foreach (op; [0x80, 0x82, 0x89, 0xc2, 0xe2])
			def(op, "NOP", Mode.immediate, false);
		foreach (op; [0x04, 0x44, 0x64])
			def(op, "NOP", Mode.zeroPage, false);
		foreach (op; [0x14, 0x34, 0x54, 0x74, 0xd4, 0xf4])
			def(op, "NOP", Mode.zeroPageX, false);
		def(0x0c, "NOP", Mode.absolute, false);
		foreach (op; [0x1c, 0x3c, 0x5c, 0x7c, 0xdc, 0xfc])
			def(op, "NOP", Mode.absoluteX, false);
		foreach (op; [0x02, 0x12, 0x22, 0x32, 0x42, 0x52, 0x62, 0x72,
			0x92, 0xb2, 0xd2, 0xf2])
			def(op, "JAM", Mode.implied, false);
	}
	else
	{
		def(0x1a, "INC", Mode.accumulator);
		def(0x3a, "DEC", Mode.accumulator);
		def(0x5a, "PHY");
		def(0x7a, "PLY");
		def(0xda, "PHX");
		def(0xfa, "PLX");
		def(0x80, "BRA", Mode.relative);
		def(0x89, "BIT", Mode.immediate);
		def(0x34, "BIT", Mode.zeroPageX);
		def(0x3c, "BIT", Mode.absoluteX);
		def(0x04, "TSB", Mode.zeroPage);
		def(0x0c, "TSB", Mode.absolute);
		def(0x14, "TRB", Mode.zeroPage);
		def(0x1c, "TRB", Mode.absolute);
		def(0x64, "STZ", Mode.zeroPage);
		def(0x74, "STZ", Mode.zeroPageX);
		def(0x9c, "STZ", Mode.absolute);
		def(0x9e, "STZ", Mode.absoluteX);
		def(0x7c, "JMP", Mode.absoluteIndirectX);

		foreach (n; 0 .. 8)
		{
			const digit = cast(char) ('0' + n);
			static if (hasBitOps!cpu)
			{
				def(0x07 + n * 0x10, "RMB" ~ digit, Mode.zeroPage);
				def(0x87 + n * 0x10, "SMB" ~ digit, Mode.zeroPage);
				def(0x0f + n * 0x10, "BBR" ~ digit, Mode.zeroPageRelative);
				def(0x8f + n * 0x10, "BBS" ~ digit, Mode.zeroPageRelative);
			}
			else
			{
				const zmode = n % 2 ? Mode.zeroPageX : Mode.zeroPage;
				const amode = n % 2 ? Mode.absoluteX : Mode.absolute;
				def(0x07 + n * 0x10, "NOP", zmode, false);
				def(0x87 + n * 0x10, "NOP", zmode, false);
				def(0x0f + n * 0x10, "NOP", amode, false);
				def(0x8f + n * 0x10, "NOP", amode, false);
			}
		}

		static if (hasWaiStp!cpu)
		{
			def(0xcb, "WAI");
			def(0xdb, "STP");
		}
		else
		{
			def(0xcb, "NOP", Mode.implied, false);
			def(0xdb, "NOP", Mode.zeroPageX, false);
		}

		foreach (op; [0x03, 0x13, 0x23, 0x33, 0x43, 0x53, 0x63, 0x73,
			0x83, 0x93, 0xa3, 0xb3, 0xc3, 0xd3, 0xe3, 0xf3,
			0x0b, 0x1b, 0x2b, 0x3b, 0x4b, 0x5b, 0x6b, 0x7b,
			0x8b, 0x9b, 0xab, 0xbb, 0xeb, 0xfb])
			def(op, "NOP", Mode.implied, false);
		foreach (op; [0x02, 0x22, 0x42, 0x62, 0x82, 0xc2, 0xe2])
			def(op, "NOP", Mode.immediate, false);
		def(0x44, "NOP", Mode.zeroPage, false);
		foreach (op; [0x54, 0xd4, 0xf4])
			def(op, "NOP", Mode.zeroPageX, false);
		foreach (op; [0x5c, 0xdc, 0xfc])
			def(op, "NOP", Mode.absolute, false);
	}

	foreach (op, u; used)
		assert(u, format!"opcode %02X not defined"(op));

	return t;
}

template opcodeTable(Cpu cpu)
{
	static immutable Op[256] opcodeTable = buildOpcodes!cpu();
}

ref immutable(Op[256]) opcodes(Cpu cpu) @safe pure nothrow @nogc
{
	final switch (cpu)
	{
		static foreach (v; EnumMembers!Cpu)
		{
		case v:
			return opcodeTable!v;
		}
	}
}

static assert(opcodeTable!(Cpu.mos_6502)[0xad] == Op("LDA", Mode.absolute, true));
static assert(opcodeTable!(Cpu.mos_6502)[0x6b] == Op("ARR", Mode.immediate, false));
static assert(opcodeTable!(Cpu.wdc_65c02)[0x64] == Op("STZ", Mode.zeroPage, true));
static assert(opcodeTable!(Cpu.wdc_65c02)[0x0f] == Op("NOP", Mode.absolute, false));
static assert(opcodeTable!(Cpu.rockwell_r65c02)[0x0f] == Op("BBR0", Mode.zeroPageRelative, true));
static assert(opcodeTable!(Cpu.rockwell_r65c02)[0xcb] == Op("NOP", Mode.implied, false));
static assert(opcodeTable!(Cpu.wdc_w65c02s)[0xcb] == Op("WAI", Mode.implied, true));

unittest
{
	import std.algorithm : canFind;
	import xebin.emu : Emulator;

	static foreach (v; EnumMembers!Cpu)
	{
		import std.stdio;
		foreach (op; 0 .. 256)
		{
			const entry = opcodes(v)[op];
			// anything that redirects pc cannot be measured this way
			if (entry.mode == Mode.relative || entry.mode == Mode.zeroPageRelative
				|| ["JMP", "JSR", "RTS", "RTI", "BRK", "WAI", "STP"].canFind(entry.mnem))
				continue;
			auto emu = new Emulator!v();
			emu.ram[0x8000 .. 0x8003] = [cast(ubyte) op, 0x34, 0x12];
			emu.pc = 0x8000;
			emu.instructionLimit = 1;
			emu.run();
			assert(emu.pc == 0x8000 + instructionLength(entry.mode) - 1,
				format!"%s: opcode %02X"(v, op));
		}
	}
}

enum ItemKind
{
	code,     // documented instruction
	data,     // reserved opcode or truncated instruction (1 byte)
	dataAddr, // run/init vector (2 bytes)
}

auto instructionSplitter(const BinaryBlock block, Cpu cpu)
{
	static struct Splitter
	{
		const BinaryBlock block;
		Cpu cpu;
		int opApply(scope int delegate(ushort addr, ItemKind kind, const(ubyte)[] bytes) dg) const
		{
			ushort addr = block.addr;
			const(ubyte)[] data = block.data;
			while (data.length)
			{
				if ((addr == runAd || addr == initAd) && data.length >= 2)
				{
					if (auto res = dg(addr, ItemKind.dataAddr, data[0 .. 2]))
						return res;
					addr += 2;
					data = data[2 .. $];
					continue;
				}

				const op = opcodes(cpu)[data[0]];
				const len = instructionLength(op.mode);
				if (op.documented && len <= data.length)
				{
					if (auto res = dg(addr, ItemKind.code, data[0 .. len]))
						return res;
					addr += len;
					data = data[len .. $];
					continue;
				}

				if (auto res = dg(addr, ItemKind.data, data[0 .. 1]))
					return res;
				addr += 1;
				data = data[1 .. $];
			}
			return 0;
		}
	}
	return Splitter(block, cpu);
}
