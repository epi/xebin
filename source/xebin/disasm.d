/*
Simple disassembler

Copyright (C) 2010-2014, 2017, 2023 Adrian Matoga

This file is part of xebin.

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <https://www.gnu.org/licenses/>.
*/
module xebin.disasm;

import std.algorithm : map, sort, uniq, equal;
import std.array : array, appender;
import std.format : formattedWrite;
import std.range : chunks, assumeSorted, SortedRange;
import std.string;

import std.conv : hexString;

import xebin.objectfile;
import xebin.utils;

///
string disassembleOne(const(ubyte[]) memory, ref ushort addr)
{
	auto app = appender!string;
	string instr = instructions[memory[addr]];
	const len = opLengths[memory[addr]];
	app.formattedWrite("%04X  ", addr);
	foreach (i; 0 .. len)
		app.formattedWrite("%02X ", memory[(addr + i) & 0xffff]);
	foreach (i; len .. 3)
		app.put("   ");
	if (instr[0] == '@')
		instr = instr[1 .. $];
	app.put("  ");
	foreach (char c; instr)
	{
		if (c == '0')
			app.formattedWrite("$%04X",
				(addr + 2 + cast(byte) memory[(addr + 1) & 0xffff]) & 0xffff);
		else if (c == '1')
			app.formattedWrite("$%02X", memory[(addr + 1) & 0xffff]);
		else if (c == '2')
			app.formattedWrite("$%04X", memory[(addr + 1) & 0xffff] |
				(memory[(addr + 2) & 0xffff] << 8));
		else
			app.put(c);
	}
	addr += len;
	return app.data;
}

unittest
{
	import std.stdio;
	ushort addr = 0xFFFD;
	ubyte[0x10000] memory;
	memory[0xFFFD .. $] = [ 0xa9, 0x42, 0x8d ];
	memory[0 .. 6] = [ 0xad, 0xde, 0xd0, 0xfb, 0x60, 0x02 ];
	assert(disassembleOne(memory, addr) == "FFFD  A9 42      LDA #$42");
	assert(disassembleOne(memory, addr) == "FFFF  8D AD DE   STA $DEAD");
	assert(disassembleOne(memory, addr) == "0002  D0 FB      BNE $FFFF");
	assert(disassembleOne(memory, addr) == "0004  60         RTS");
	assert(disassembleOne(memory, addr) == "0005  02         CIM");
}

///
auto disassemble(CompositeSegment top)
{
	return Disassembler(top);
}

private version(unittest) string[] disassembleToStrings(BinaryBlock[] blocks)
{
	auto app = appender!(string[]);
	foreach (l; blocks.disassemble)
	{
		app.put(l.idup);
	}
	return app.data;
}
unittest
{
	// label from run/init address
	auto bb = [
		BinaryBlock(0x2000, cast(ubyte[]) hexString!"90 02 a9 20 20 ad de"),
		BinaryBlock(0x02e0, cast(ubyte[]) hexString!"00 20 00 40")
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

struct Disassembler
{
	this(CompositeSegment top) {
		_top = top;
		_instrSpans = {
			auto app = appender!(Span[]);
			top.accept(new class DefaultSegmentVisitor {
				override bool visit(LoadableSegment seg) {
					foreach (addr, atype, bytes; instructionSplitter(seg))
						app.put(Span(addr, cast(uint) (addr + bytes.length - 1)));
					return true;
				}
			});
			return app.data.sort;
		}();
		_labeledAddresses = {
			auto app = appender!(uint[]);

			void put(uint addr) {
				 app.put(alignToInstr(addr));
			}

			top.accept(new class DefaultSegmentVisitor {
				override bool visit(LoadableSegment seg) {
					if (seg.isRun)
						put(seg.runAddr);
					if (seg.isInit)
						put(seg.initAddr);
					foreach (addr, atype, const bytes; instructionSplitter(seg)) {
						switch (atype) with(AddrType) {
						case relative:
							put(addr + 2 + cast(byte) bytes[1]);
							break;
						case zeropage:
							put(bytes[1]);
							break;
						case word:
							put(bytes[1 .. $].peekLE!ushort);
							break;
						case dta_a:
							put(bytes[].peekLE!ushort);
							break;
						default:
						}
					}
					return true;
				}
			});
			return app.data.sort.uniq.array.assumeSorted;
		}();
	}

	@disable this(this);
	@disable void opAssign(Disassembler);

	int opApply(scope int delegate(const(char)[] line) dg)
	{
		uint[uint] labels;

		auto app = appender!(char[]);

		int put(A...)(auto ref A a) {
			app.formattedWrite(a);
			int res = dg(app.data);
			if (!res)
				app.clear();
			return res;
		}

		void declareLabel(uint addr) {
			const cnt = labels[addr]++;
			app.formattedWrite("L%04X", addr);
			if (cnt)
				app.formattedWrite("_%d", cnt);
			app.put('\t');
		}

		void putAddr(uint addr) {
			const a = alignToInstr(addr);
			auto r = _labeledAddresses.equalRange(a);
			if (r.empty)
				app.formattedWrite("$%04X", addr);
			else if (a == addr)
				app.formattedWrite("L%04X", addr);
			else
				app.formattedWrite("L%04X+%d", a, addr - a);
		}

		foreach (l; _labeledAddresses) {
			auto sv = new class DefaultSegmentVisitor {
				bool inblock;
				override bool visit(LoadableSegment seg) {
					if (Span(seg.addr, seg.end).overlaps(Span(l, l))) {
						inblock = true;
						return false;
					}
					return true;
				}
			};
			_top.accept(sv);
			if (!sv.inblock)
			{
				declareLabel(l);
				if (auto res = put("EQU $%04X", l, l))
					return res;
			}
		}

		int res;
		_top.accept(new class DefaultSegmentVisitor {
			override bool visit(LoadableSegment seg) {
				if ((res = put("\tORG $%04X", seg.addr)) != 0)
					return false;
				foreach (addr, atype, bytes; instructionSplitter(seg)) {
					auto r = _labeledAddresses.equalRange(addr);
					if (!r.empty)
						app.formattedWrite("L%04X", addr);
					app.put('\t');
					if (atype == AddrType.dta_a) {
						app.put("DTA A(");
						putAddr(bytes[].peekLE!ushort);
						app.put(')');
					} else {
						const instr = instructions[bytes[0]];
						if (instr[0] == '@' || bytes.length < opLengths[bytes[0]]) {
							app.formattedWrite("DTA $%02X", bytes[0]);
						} else {
							foreach (char c; instr) {
								if (c == '0') {
									putAddr(cast(ushort) (addr + 2 + cast(byte) bytes[1]));
								} else if (c == '1') {
									if (atype == AddrType.immediate)
										app.formattedWrite("$%02X", bytes[1]);
									else
										putAddr(bytes[1]);
								} else if (c == '2') {
									const a = bytes[1 .. $].peekLE!ushort;
									if (a < 0x100 && app.data[$ - 1] == ' ')
										app.put("A:");
									putAddr(a);
								} else {
									app.put(c);
								}
							}
						}
					}
					if ((res = dg(app.data)) != 0)
						return false;
					app.clear();
				}
				return true;
			}
		});
		return res;
	}

private:
	CompositeSegment _top;
	SortedRange!(Span[]) _instrSpans;
	SortedRange!(uint[]) _labeledAddresses;

	static struct Span
	{
		uint begin;
		uint end;
		int opCmp(Span rhs) pure nothrow const @safe
		{
			if (begin <= rhs.end && rhs.begin <= end)
				return 0;
			if (begin < rhs.begin)
				return -1;
			return 1;
		}

		bool overlaps(Span rhs) const pure nothrow @safe => this.opCmp(rhs) == 0;
	}

	uint alignToInstr(uint addr) {
		auto r = _instrSpans.equalRange(Span(addr, addr));
		if (r.empty)
			return addr;
		return r.front.begin;
	}
}

private:


static immutable(string[256]) instructions =
[	// shamelessly stolen from Atari800
	"BRK", "ORA (1,X)", "@CIM", "@ASO (1,X)", "@NOP 1", "ORA 1", "ASL 1", "@ASO 1",
	"PHP", "ORA #1", "ASL @", "@ANC #1", "@NOP 2", "ORA 2", "ASL 2", "@ASO 2",

	"BPL 0", "ORA (1),Y", "@CIM", "@ASO (1),Y", "@NOP 1,X", "ORA 1,X", "ASL 1,X", "@ASO 1,X",
	"CLC", "ORA 2,Y", "@NOP !", "@ASO 2,Y", "@NOP 2,X", "ORA 2,X", "ASL 2,X", "@ASO 2,X",

	"JSR 2", "AND (1,X)", "@CIM", "@RLA (1,X)", "BIT 1", "AND 1", "ROL 1", "@RLA 1",
	"PLP", "AND #1", "ROL @", "@ANC #1", "BIT 2", "AND 2", "ROL 2", "@RLA 2",

	"BMI 0", "AND (1),Y", "@CIM", "@RLA (1),Y", "@NOP 1,X", "AND 1,X", "ROL 1,X", "@RLA 1,X",
	"SEC", "AND 2,Y", "@NOP !", "@RLA 2,Y", "@NOP 2,X", "AND 2,X", "ROL 2,X", "@RLA 2,X",


	"RTI", "EOR (1,X)", "@CIM", "@LSE (1,X)", "@NOP 1", "EOR 1", "LSR 1", "@LSE 1",
	"PHA", "EOR #1", "LSR @", "@ALR #1", "JMP 2", "EOR 2", "LSR 2", "@LSE 2",

	"BVC 0", "EOR (1),Y", "@CIM", "@LSE (1),Y", "@NOP 1,X", "EOR 1,X", "LSR 1,X", "@LSE 1,X",
	"CLI", "EOR 2,Y", "@NOP !", "@LSE 2,Y", "@NOP 2,X", "EOR 2,X", "LSR 2,X", "@LSE 2,X",

	"RTS", "ADC (1,X)", "@CIM", "@RRA (1,X)", "@NOP 1", "ADC 1", "ROR 1", "@RRA 1",
	"PLA", "ADC #1", "ROR @", "@ARR #1", "JMP (2)", "ADC 2", "ROR 2", "@RRA 2",

	"BVS 0", "ADC (1),Y", "@CIM", "@RRA (1),Y", "@NOP 1,X", "ADC 1,X", "ROR 1,X", "@RRA 1,X",
	"SEI", "ADC 2,Y", "@NOP !", "@RRA 2,Y", "@NOP 2,X", "ADC 2,X", "ROR 2,X", "@RRA 2,X",


	"@NOP #1", "STA (1,X)", "@NOP #1", "@SAX (1,X)", "STY 1", "STA 1", "STX 1", "@SAX 1",
	"DEY", "@NOP #1", "TXA", "@ANE #1", "STY 2", "STA 2", "STX 2", "@SAX 2",

	"BCC 0", "STA (1),Y", "@CIM", "@SHA (1),Y", "STY 1,X", "STA 1,X", "STX 1,Y", "@SAX 1,Y",
	"TYA", "STA 2,Y", "TXS", "@SHS 2,Y", "@SHY 2,X", "STA 2,X", "@SHX 2,Y", "@SHA 2,Y",

	"LDY #1", "LDA (1,X)", "LDX #1", "@LAX (1,X)", "LDY 1", "LDA 1", "LDX 1", "@LAX 1",
	"TAY", "LDA #1", "TAX", "@ANX #1", "LDY 2", "LDA 2", "LDX 2", "@LAX 2",

	"BCS 0", "LDA (1),Y", "@CIM", "@LAX (1),Y", "LDY 1,X", "LDA 1,X", "LDX 1,Y", "@LAX 1,X",
	"CLV", "LDA 2,Y", "TSX", "@LAS 2,Y", "LDY 2,X", "LDA 2,X", "LDX 2,Y", "@LAX 2,Y",


	"CPY #1", "CMP (1,X)", "@NOP #1", "@DCM (1,X)", "CPY 1", "CMP 1", "DEC 1", "@DCM 1",
	"INY", "CMP #1", "DEX", "@SBX #1", "CPY 2", "CMP 2", "DEC 2", "@DCM 2",

	"BNE 0", "CMP (1),Y", "@ESCRTS #1", "@DCM (1),Y", "NOP 1,X", "CMP 1,X", "DEC 1,X", "@DCM 1,X",
	"CLD", "CMP 2,Y", "@NOP !", "@DCM 2,Y", "@NOP 2,X", "CMP 2,X", "DEC 2,X", "@DCM 2,X",


	"CPX #1", "@SBC (1,X)", "@NOP #1", "@INS (1,X)", "CPX 1", "SBC 1", "INC 1", "@INS 1",
	"INX", "SBC #1", "NOP", "@SBC #1 !", "CPX 2", "SBC 2", "INC 2", "@INS 2",

	"BEQ 0", "@SBC (1),Y", "@ESCAPE #1", "@INS (1),Y", "@NOP 1,X", "SBC 1,X", "INC 1,X", "@INS 1,X",
	"SED", "SBC 2,Y", "@NOP !", "@INS 2,Y", "@NOP 2,X", "SBC 2,X", "INC 2,X", "@INS 2,X"
];

enum AddrType
{
	none,
	immediate,
	zeropage,
	word,
	relative,
	dta_a,
}

static immutable(AddrType[256]) addrTypes =
	instructions[].map!((instr)
		{
			foreach (char c; instr)
			{
				switch (c)
				{
				case '@':
					return AddrType.none;
				case '#':
					return AddrType.immediate;
				case '0':
					return AddrType.relative;
				case '1':
					return AddrType.zeropage;
				case '2':
					return AddrType.word;
				default:
				}
			}
			return AddrType.none;
		}).array;

static assert(addrTypes[0x0d] == AddrType.word);

static immutable(ubyte[256]) opLengths =
	addrTypes[].map!((atype)
		{
			final switch (atype) with (AddrType)
			{
				case none: return 1;
				case word: return 3;
				case immediate: case relative: case zeropage: case dta_a:
					return 2;
			}
		}).array;

auto instructionSplitter(LoadableSegment segment)
{
	static struct Splitter
	{
		LoadableSegment segment;
		int opApply(scope int delegate(uint addr, AddrType atype, const(ubyte)[] bytes) dg) const
		{
			uint addr = segment.addr;
			const(ubyte)[] data = segment.data;
			while (data.length)
			{
				if ((addr == 0x2e0 || addr == 0x2e2) && data.length >= 2)
				{
					if (auto res = dg(addr, AddrType.dta_a, data[0 .. 2]))
						return res;
					addr += 2;
					data = data[2 .. $];
					continue;
				}

				const opcode = data[0];
				const atype = addrTypes[opcode];
				const len = opLengths[opcode];
				if (len <= data.length)
				{
					if (auto res = dg(addr, atype, data[0 .. len]))
						return res;
					addr += len;
					data = data[len .. $];
					continue;
				}

				if (auto res = dg(addr, AddrType.none, data[0 .. 1]))
					return res;
				addr += 1;
				data = data[1 .. $];
			}
			return 0;
		}
	}
	return Splitter(segment);
}
