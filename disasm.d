/*	(Written in D programming language)

	Simple 6502 disassembler.

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

import std.regex;
import std.string;
import std.conv;
import std.exception;

import binary;

struct AsmLine
{
	ushort addr;
	ubyte[] bytes;
	ushort arg;
	ubyte argSize;
	bool argIsAddr;
	private Disassembler disasm_;

	this(ushort addr, ubyte[] bytes)
	{
		this(null, addr, bytes);
	}

	this(Disassembler disasm, ushort addr, ubyte[] bytes)
	{
		this.disasm_ = disasm;
		this.addr = addr;
		ubyte opc = bytes[0];
		string opcStr = opcodes_[opc];
		bool imm;
		if (!opcStr.startsWith('@'))
		{
			foreach (k; opcStr)
			{
				if (k == '#')
					imm = true;
				else if (k == '0')
				{
					this.bytes = bytes[0 .. 2];
					this.arg = cast(ushort) (addr + 2 + (bytes[1] >= 0x80 ? bytes[1] - 256 : bytes[1]));
					this.argIsAddr = true;
				}
				else if (k == '1')
				{
					if (!imm)
						this.argIsAddr = true;
					this.arg = bytes[1];
					this.bytes = bytes[0 .. 2];
				}
				else if (k == '2')
				{
					this.argIsAddr = true;
					this.arg = bytes[1] | (bytes[2] << 8);
					this.bytes = bytes[0 .. 3];
				}
			}
		}
		if (!this.bytes)
			this.bytes = bytes[0 .. 1];
	}

	string hex()
	{
		auto result = "        ".dup;
		foreach (i, b; bytes)
			result[i * 3 .. i * 3 + 2] = format("%02x", b);
		return assumeUnique(result);
	}

	string label()
	{
		return disasm_ ? disasm_.labels_.get(addr, null) : "";
	}

	string instr()
	{
		ubyte opc = bytes[0];
		string opcStr = opcodes_[opc];
		if (opcStr.startsWith('@'))
			return format("DTA $%02x", bytes[0]);
		if (bytes.length == 1)
			return opcStr;
		char[] result;
		foreach (k; opcStr)
		{
			if (disasm_ && k >= '0' && k <= '2' && argIsAddr)
			{
				auto s = disasm_.labels_.get(arg, null);
				if (s)
				{
					result ~= s;
					continue;
				}
			}
			if (k == '0' || k == '2')
				result ~= format("$%04x", arg);
			else if (k == '1')
				result ~= format("$%02x", arg);
			else
				result ~= k;
		}
		return result.idup;
	}
	
private:
	static immutable(string[]) opcodes_ =
	[
		// shamelessly stolen from Atari800

		"BRK", "ORA (1,X)", "@CIM", "@ASO (1,X)", "@NOP 1", "ORA 1", "ASL 1", "@ASO 1",
		"PHP", "ORA #1", "ASL", "@ANC #1", "@NOP 2", "ORA 2", "ASL 2", "@ASO 2",

		"BPL 0", "ORA (1),Y", "@CIM", "@ASO (1),Y", "@NOP 1,X", "ORA 1,X", "ASL 1,X", "@ASO 1,X",
		"CLC", "ORA 2,Y", "@NOP !", "@ASO 2,Y", "@NOP 2,X", "ORA 2,X", "ASL 2,X", "@ASO 2,X",

		"JSR 2", "AND (1,X)", "@CIM", "@RLA (1,X)", "BIT 1", "AND 1", "ROL 1", "@RLA 1",
		"PLP", "AND #1", "ROL", "@ANC #1", "BIT 2", "AND 2", "ROL 2", "@RLA 2",

		"BMI 0", "AND (1),Y", "@CIM", "@RLA (1),Y", "@NOP 1,X", "AND 1,X", "ROL 1,X", "@RLA 1,X",
		"SEC", "AND 2,Y", "@NOP !", "@RLA 2,Y", "@NOP 2,X", "AND 2,X", "ROL 2,X", "@RLA 2,X",


		"RTI", "EOR (1,X)", "@CIM", "@LSE (1,X)", "@NOP 1", "EOR 1", "LSR 1", "@LSE 1",
		"PHA", "EOR #1", "LSR", "@ALR #1", "JMP 2", "EOR 2", "LSR 2", "@LSE 2",

		"BVC 0", "EOR (1),Y", "@CIM", "@LSE (1),Y", "@NOP 1,X", "EOR 1,X", "LSR 1,X", "@LSE 1,X",
		"CLI", "EOR 2,Y", "@NOP !", "@LSE 2,Y", "@NOP 2,X", "EOR 2,X", "LSR 2,X", "@LSE 2,X",

		"RTS", "ADC (1,X)", "@CIM", "@RRA (1,X)", "@NOP 1", "ADC 1", "ROR 1", "@RRA 1",
		"PLA", "ADC #1", "ROR", "@ARR #1", "JMP (2)", "ADC 2", "ROR 2", "@RRA 2",

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
}

class Disassembler
{
	private string[ushort] labels_;
	private BinaryBlock[] blocks_;

	this(BinaryBlock[] blocks)
	{
		blocks_ = blocks;
		foreach (lines; this[])
		{
			foreach (ln; lines)
			{
				if (ln.argIsAddr)
				{
					foreach (blk; blocks_)
					{
						if (ln.arg >= blk.addr
						 && ln.arg < blk.addr + blk.length
						 && !labels_.get(ln.arg, null))
							labels_[ln.arg] = format("L%04x", ln.arg);
					}
				}
			}
		}
	}

	static struct BlockRange
	{
		private Disassembler disasm_;
		private BinaryBlock[] blocks_;

		@property bool empty() { return blocks_.length == 0; }

		@property LineRange front()
		{
			return LineRange(disasm_, blocks_[0].addr, blocks_[0].data);
		}

		@property void popFront() { blocks_ = blocks_[1 .. $]; }

		static struct LineRange
		{
			private AsmLine current_;
			private ushort addr_;
			private ubyte[] data_;
			private Disassembler disasm_;

			this(Disassembler disasm, ushort addr, ubyte[] data)
			{
				disasm_ = disasm;
				addr_ = addr;
				data_ = data;
				current_ = AsmLine(disasm_, addr_, data_);
			}

			@property bool empty()
			{
				return data_.length == 0;
			}

			@property AsmLine front()
			{
				return current_;
			}

			void popFront()
			{
				if (current_.bytes.length >= data_.length)
				{
					data_ = null;
					return;
				}
				data_ = data_[current_.bytes.length .. $];
				addr_ += current_.bytes.length;
				current_ = AsmLine(disasm_, addr_, data_);
			}
		}
	}

	BlockRange opSlice() { return BlockRange(this, blocks_); }
}
