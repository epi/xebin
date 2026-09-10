/**	65(c)02 emulator.

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
module xebin.emu;

import std.string;

version(unittest)
{
	import std.stdio;
	import std.format : formattedWrite;
}

private ushort makeWord(uint b1, uint b0)
{
	return cast(ushort) ((b1 << 8) | b0);
}

enum bool readsOperand(string expr) = expr.indexOf("@r") >= 0;
enum bool writesOperand(string expr) = expr.indexOf("@w(") >= 0;
enum indexAlways = "@i;";
enum bool alwaysIndexed(string expr) = expr.indexOf(indexAlways) >= 0;

string substOperand(string expr, string read, string writeOpen, string modifyOpen, string idleRead)
{
	return expr
		.replace(indexAlways, "")
		.replace("@d", idleRead)
		.replace("@m(", modifyOpen)
		.replace("@w(", writeOpen)
		.replace("@r", read);
}

enum adc =
q{
	uint arg = @r;
	uint tmp = a + arg + cflag;
	if (!dflag)
	{
		cflag = tmp >= 0x100;
		vflag = (~(arg ^ a) & (a ^ tmp) & 0x80) != 0;
		setNZ(a = tmp & 0xff);
	}
	else
	{
		uint al = (a & 0x0f) + (arg & 0x0f) + cflag;
		if (al >= 0x0a)
			al = ((al + 0x06) & 0x0f) + 0x10;
		uint sum = (a & 0xf0) + (arg & 0xf0) + al;
		nflag = (sum & 0x80) != 0;
		vflag = (~(arg ^ a) & (a ^ sum) & 0x80) != 0;
		zflag = (tmp & 0xff) == 0;
		if (sum >= 0xa0)
			sum += 0x60;
		cflag = sum >= 0x100;
		a = cast(ubyte) sum;
		static if (isCmos!cpuVariant) {
			@d;
			setNZ(a);
		}
	}
};

enum sbc =
q{
	const ubyte operand = @r;
	const ubyte oa = a;
	const bool carryIn = cflag;
	const uint tmp = oa + cast(ubyte) ~operand + carryIn;
	const ubyte bin = tmp & 0xff;
	setNZ(bin);
	vflag = ((oa ^ operand) & (oa ^ bin) & 0x80) != 0;
	cflag = tmp >= 0x100;
	if (!dflag)
		a = bin;
	else
	{
		int al = (oa & 0x0f) - (operand & 0x0f) + carryIn - 1;
		static if (isCmos!cpuVariant)
		{
			@d;
			int res = oa - operand + carryIn - 1;
			if (res < 0)
				res -= 0x60;
			if (al < 0)
				res -= 0x06;
			setNZ(a = cast(ubyte) res);
		}
		else
		{
			if (al < 0)
				al = ((al - 0x06) & 0x0f) - 0x10;
			int res = (oa & 0xf0) - (operand & 0xf0) + al;
			if (res < 0)
				res -= 0x60;
			a = cast(ubyte) res;
		}
	}
};

enum cmp = q{ ubyte tmp = @r; setNZ(a - tmp); cflag = a >= tmp; };
enum cpx = q{ ubyte tmp = @r; setNZ(x - tmp); cflag = x >= tmp; };
enum cpy = q{ ubyte tmp = @r; setNZ(y - tmp); cflag = y >= tmp; };
enum lda = q{ setNZ(a = @r); };
enum ldx = q{ setNZ(x = @r); };
enum ldy = q{ setNZ(y = @r); };
enum ora = q{ setNZ(a |= @r); };
enum and = q{ setNZ(a &= @r); };
enum eor = q{ setNZ(a ^= @r); };
enum sta = q{ @w(a); };
enum stx = q{ @w(x); };
enum sty = q{ @w(y); };
enum stz = q{ @w(0); };
enum inc = indexAlways ~
q{
	ubyte tmp = @r;
	@m(tmp);
	setNZ(++tmp);
	@w(tmp);
};
enum dec = indexAlways ~
q{
	ubyte tmp = @r;
	@m(tmp);
	setNZ(--tmp);
	@w(tmp);
};
enum asl =
q{
	ubyte tmp = @r;
	@m(tmp);
	cflag = (tmp & 0x80) != 0;
	tmp <<= 1;
	setNZ(tmp);
	@w(tmp);
};
enum rol =
q{
	ubyte tmp = @r;
	@m(tmp);
	bool nc = (tmp & 0x80) != 0;
	tmp = cast(ubyte) ((tmp << 1) | cflag);
	cflag = nc;
	setNZ(tmp);
	@w(tmp);
};
enum lsr =
q{
	ubyte tmp = @r;
	@m(tmp);
	cflag = (tmp & 1) != 0;
	tmp >>>= 1;
	setNZ(tmp);
	@w(tmp);
};
enum ror =
q{
	ubyte tmp = @r;
	@m(tmp);
	bool nc = (tmp & 1) != 0;
	tmp = cast(ubyte) ((tmp >>> 1) | (cflag ? 0x80 : 0));
	cflag = nc;
	setNZ(tmp);
	@w(tmp);
};
enum bit =
q{
	ubyte tmp = @r;
	zflag = (a & tmp) == 0;
	nflag = (tmp & 0x80) != 0;
	vflag = (tmp & 0x40) != 0;
};
enum tsb = q{ ubyte tmp = @r; @m(tmp); zflag = (a & tmp) == 0; @w(cast(ubyte) (tmp | a)); };
enum trb = q{ ubyte tmp = @r; @m(tmp); zflag = (a & tmp) == 0; @w(cast(ubyte) (tmp & ~a)); };
enum nop = q{ ubyte discarded = @r; }; // NOPs with fancy addressing modes

enum lax = q{ setNZ(a = x = @r); };
enum sax = q{ @w(a & x); };
enum combo(string rmw, string alu) =
	rmw.replace("tmp", "modified") ~ alu.replace("@r", "modified");
enum slo = combo!(asl, ora);
enum rla = combo!(rol, and);
enum sre = combo!(lsr, eor);
enum rra = combo!(ror, adc);
enum dcp = combo!(dec, cmp);
enum isc = combo!(inc, sbc);
enum anc = q{ setNZ(a &= @r); cflag = nflag; };
enum alr = q{ a &= @r; cflag = (a & 1) != 0; setNZ(a >>>= 1); };
enum arr =
q{
	const ubyte anded = a & @r;
	const ubyte rotated = cast(ubyte) ((anded >>> 1) | (cflag ? 0x80 : 0));
	if (!dflag)
	{
		setNZ(rotated);
		cflag = (rotated & 0x40) != 0;
		vflag = ((rotated ^ (rotated << 1)) & 0x40) != 0;
		a = rotated;
	}
	else
	{
		nflag = cflag;
		zflag = rotated == 0;
		vflag = ((anded ^ rotated) & 0x40) != 0;
		uint fixed = rotated;
		if ((anded & 0x0f) + (anded & 0x01) > 0x05)
			fixed = (fixed & 0xf0) | ((fixed + 0x06) & 0x0f);
		cflag = (anded & 0xf0) + (anded & 0x10) > 0x50;
		if (cflag)
			fixed += 0x60;
		a = cast(ubyte) fixed;
	}
};
enum sbx = q{
	const ubyte tmp = @r;
	const ubyte ax = a & x;
	cflag = ax >= tmp;
	setNZ(x = cast(ubyte) (ax - tmp));
};
enum ane = q{ setNZ(a = (a | magicConstant) & x & @r); };
enum laxImmediate = q{ setNZ(a = x = (a | magicConstant) & @r); };
enum las = q{ setNZ(a = x = (sp &= @r)); };

///
enum CpuVariant {
	mos_6502,        /// NMOS
	wdc_65c02,       /// original CMOS (also Synertek, GTE, etc.), part of Lynx's Mikey
	rockwell_r65c02, /// Rockwell (bit ops)
	wdc_w65c02s,     /// modern W65C02S (bit ops + WAI/STP)}
}

/// Basic CMOS instruction set + BCD and JMP (abs) fixes.
enum bool isCmos(CpuVariant v) = v != CpuVariant.mos_6502;

/// Rockwell's RMBn/SMBn/BBRn/BBSn, carried over into the W65C02S.
enum bool hasBitOps(CpuVariant v) =
	v == CpuVariant.rockwell_r65c02 || v == CpuVariant.wdc_w65c02s;

/// WAI and STP, added by the W65C02S; NOPs everywhere else.
enum bool hasWaiStp(CpuVariant v) = v == CpuVariant.wdc_w65c02s;

/// Observer policy interface with no-op implementation.
struct NoObserver
{
	/// Called after the opcode is fetched, with pc still on the opcode.
	void instruction(E)(E emu) {}
	void fetch(ushort addr, ubyte value) {} /// Opcode or operand read via pc.
	void read(ushort addr, ubyte value) {}  /// Data read; from `ld`.
	void write(ushort addr, ubyte value) {} /// Data write; from `st`.
	void idle(ushort addr) {}               /// A cycle that carries no operand.
	/// Called once the instruction is done, to emit whatever accumulated.
	void endInstruction() {}
}

/// Forward every hook to all contained observers.
struct Compose(Observers...)
{
	Observers observers;

	/// The `n`th composed observer, for configuring or reading it back.
	ref auto get(size_t n)() { return observers[n]; }

	void instruction(E)(E emu) { foreach (ref o; observers) o.instruction(emu); }
	void fetch(ushort addr, ubyte value) { foreach (ref o; observers) o.fetch(addr, value); }
	void read(ushort addr, ubyte value) { foreach (ref o; observers) o.read(addr, value); }
	void write(ushort addr, ubyte value) { foreach (ref o; observers) o.write(addr, value); }
	void idle(ushort addr) { foreach (ref o; observers) o.idle(addr); }
	void endInstruction() { foreach (ref o; observers) o.endInstruction(); }
}

/// Counts every bus access as the same number of ticks.
struct UniformTicks
{
	long ticks;             /// Elapsed ticks.
	int ticksPerAccess = 1; /// Or 5 for Lynx nominal (no same-page optimization).

	void instruction(E)(E emu) {}
	void fetch(ushort addr, ubyte value) { ticks += ticksPerAccess; }
	void read(ushort addr, ubyte value) { ticks += ticksPerAccess; }
	void write(ushort addr, ubyte value) { ticks += ticksPerAccess; }
	void idle(ushort addr) { ticks += ticksPerAccess; }
	void endInstruction() {}
}

///
class Emulator(CpuVariant cpuVariant = CpuVariant.mos_6502, Observer = NoObserver)
{
	enum cpu = cpuVariant;

	/// Observer policy instance; configure it before running.
	Observer observer;

	private ubyte[] memory;
	private void delegate()[ubyte] traps;

	long instructions;
	long instructionLimit = -1;

	void installTrap(ubyte selector, void delegate() handler)
	{
		traps[selector] = handler;
	}

	@property ubyte[] ram() { return memory; }

	bool stopOnEmptyStackRts = true;

	bool stopped;
	/// For ANE and LAX #imm. $EE matches SingleStepTests and MOS 6510.
	ubyte magicConstant = 0xee;

	ubyte a;
	ubyte x;
	ubyte y;
	ushort pc;
	ubyte sp = 0xff;
	bool nflag;
	bool vflag;
	bool dflag;
	bool iflag;
	bool zflag;
	bool cflag;

	///	Flags, `NV1BDIZC`.
	@property ubyte p() const
	{
		return cast(ubyte) (
			(nflag ? 0x80 : 0) |
			(vflag ? 0x40 : 0) |
			0x20 |
			(dflag ? 0x08 : 0) |
			(iflag ? 0x04 : 0) |
			(zflag ? 0x02 : 0) |
			(cflag ? 0x01 : 0));
	}

	/// ditto
	@property void p(ubyte value)
	{
		nflag = (value & 0x80) != 0;
		vflag = (value & 0x40) != 0;
		dflag = (value & 0x08) != 0;
		iflag = (value & 0x04) != 0;
		zflag = (value & 0x02) != 0;
		cflag = (value & 0x01) != 0;
	}

	this()
	{
		memory = new ubyte[65536];
	}

	void dpoke(uint addr, uint val)
	{
		memory[addr] = val & 0xff;
		memory[addr + 1] = (val & 0xff00) >>> 8;
	}

	ushort dpeek(uint addr)
	{
		return makeWord(memory[(addr + 1) & 0xffff], memory[addr]);
	}

	void push(uint b)
	{
		const addr = cast(ushort) (0x100 + sp--);
		memory[addr] = cast(ubyte) b;
		observer.write(addr, cast(ubyte) b);
	}

	ubyte pop()
	{
		const addr = cast(ushort) (0x100 + ++sp);
		observer.read(addr, memory[addr]);
		return memory[addr];
	}

	ubyte fetchByte()
	{
		++pc;
		observer.fetch(pc, memory[pc]);
		return memory[pc];
	}

	ushort fetchWord()
	{
		const lo = fetchByte();
		const hi = fetchByte();
		return makeWord(hi, lo);
	}

	private void idleRead(int addr)
	{
		observer.idle(cast(ushort) addr);
	}

	private void idleFetch()
	{
		idleRead(pc + 1);
	}

	private void idlePop()
	{
		idleRead(0x100 + sp);
	}

	private void jam()
	{
		idleRead(0xffff);
		idleRead(0xfffe);
		idleRead(0xfffe);
		idleRead(0xffff);
		--pc;
		stopped = true;
		observer.endInstruction();
	}

	private void indexPenalty(string expr)(ushort base, ubyte index)
	{
		const ushort fixed = cast(ushort) (base + index);
		const bool crossed = (fixed & 0xff00) != (base & 0xff00);
		static if (isCmos!cpuVariant)
		{
			enum always = alwaysIndexed!expr ||             // INC/DEC
				(writesOperand!expr && !readsOperand!expr); // STA
			if (crossed || always)
				idleRead(pc);
		}
		else
		{
			if (crossed || writesOperand!expr)
				idleRead((base & 0xff00) | (fixed & 0xff));
		}
	}

	private ushort readWord(ushort addr, ushort hiAddr)
	{
		const lo = ld(addr);
		const hi = ld(hiAddr);
		return makeWord(hi, lo);
	}

	private void modifyCycle(ushort addr, ubyte value)
	{
		static if (isCmos!cpuVariant)
			ld(addr);
		else
			st(addr, value);
	}

	private static void noModify(ubyte value) {}

	void doAccumulator(string expr)()
	{
		idleFetch();
		mixin(substOperand(expr, "a", "a = (", "noModify(", ""));
	}

	void doImmediate(string expr)()
	{
		static assert(!writesOperand!expr);
		mixin(substOperand(expr, "fetchByte()", "", "noModify(", "idleFetch()"));
	}

	private void doAbsolute(string expr)()
	{
		const addr = fetchWord();
		mixin(substOperand(expr, "ld(addr)", "st(addr, ", "modifyCycle(addr, ", "idleRead(addr)"));
	}

	private void doAbsoluteIndexed(string expr)(ubyte index)
	{
		const base = fetchWord();
		indexPenalty!expr(base, index);
		const addr = cast(ushort) (base + index);
		mixin(substOperand(expr, "ld(addr)", "st(addr, ", "modifyCycle(addr, ", "idleRead(addr)"));
	}

	// SHA/SHX/SHY/TAS
	// TODO: revisit if RDY is implemented
	private void unstableStore(ushort base, ubyte index, uint value)
	{
		const ushort fixed = cast(ushort) (base + index);
		idleRead((base & 0xff00) | (fixed & 0xff));
		const ubyte data = cast(ubyte) (value & ((base >> 8) + 1));
		const bool crossed = (fixed & 0xff00) != (base & 0xff00);
		st(crossed ? cast(ushort) ((data << 8) | (fixed & 0xff)) : fixed, data);
	}

	private void doUnstableStoreAbsoluteIndexed(ubyte index, uint value)
	{
		unstableStore(fetchWord(), index, value);
	}

	private void doUnstableStoreIndirectY(uint value)
	{
		const ushort zp = fetchByte();
		unstableStore(readWord(zp, cast(ushort) ((zp + 1) & 0xff)), y, value);
	}

	private void doNopAbsolute(bool indexCycle)()
	{
		fetchWord();
		static if (indexCycle)
			idleRead(pc);
	}

	private void doZeroPage(string expr)()
	{
		const ubyte addr = fetchByte();
		mixin(substOperand(expr, "ld(addr)", "st(addr, ", "modifyCycle(addr, ", "idleRead(addr)"));
	}

	private void doZeroPageIndexed(string expr)(ubyte index)
	{
		const ubyte base = fetchByte();
		idleRead(base);
		const ubyte addr = cast(ubyte) (base + index);
		mixin(substOperand(expr, "ld(addr)", "st(addr, ", "modifyCycle(addr, ", "idleRead(addr)"));
	}

	void doIndirectY(string expr)()
	{
 		const ushort zp = fetchByte();
		const base = readWord(zp, cast(ushort) ((zp + 1) & 0xff));
		indexPenalty!expr(base, y);
		const addr = cast(ushort) (base + y);
		mixin(substOperand(expr, "ld(addr)", "st(addr, ", "modifyCycle(addr, ", "idleRead(addr)"));
	}

	void doIndirectX(string expr)()
	{
		const ushort zp = fetchByte();
		idleRead(zp);
		const ptr = (zp + x) & 0xff;
		const addr = readWord(cast(ushort) ptr, cast(ushort) ((ptr + 1) & 0xff));
		mixin(substOperand(expr, "ld(addr)", "st(addr, ", "modifyCycle(addr, ", "idleRead(addr)"));
	}

	static if (isCmos!cpuVariant)
	void doIndirectZP(string expr)()
	{
		const ushort zp = fetchByte();
		const addr = readWord(zp, cast(ushort) ((zp + 1) & 0xff));
		mixin(substOperand(expr, "ld(addr)", "st(addr, ", "modifyCycle(addr, ", "idleRead(addr)"));
	}

	static if (isCmos!cpuVariant)
	void doBitSetReset(ubyte mask, bool set)()
	{
		const ubyte addr = fetchByte();
		const ubyte value = ld(addr);
		modifyCycle(addr, value);
		static if (set)
			st(addr, value | mask);
		else
			st(addr, value & ~mask);
	}

	static if (hasBitOps!cpuVariant)
	void doBitBranch(ubyte mask, bool branchIfSet)()
	{
		const ubyte zp = fetchByte();
		const bool isSet = (ld(zp) & mask) != 0;
		idleRead(zp);
		const byte offs = fetchByte();
		if (isSet != branchIfSet)
			return;
		const next = cast(ushort) (pc + 1);
		idleRead(next);
		const target = cast(ushort) (next + offs);
		if ((target & 0xff00) != (next & 0xff00))
			idleRead(next);
		pc = cast(ushort) (target - 1);
	}

	void doBranch(string pred)()
	{
		byte offs = fetchByte();
		if (!mixin(pred))
			return;
		const next = cast(ushort) (pc + 1);
		idleRead(next);
		const target = cast(ushort) (next + offs);
		if ((target & 0xff00) != (next & 0xff00))
			idleRead((next & 0xff00) | (target & 0xff));
		pc = cast(ushort) (target - 1);
	}

	void setNZ(uint res)
	{
		zflag = res == 0;
		nflag = (res & 0x80) != 0;
	}

	ubyte ld(ushort addr)
	{
		observer.read(addr, memory[addr]);
		return memory[addr];
	}

	ubyte st(ushort addr, uint val)
	{
		memory[addr] = cast(ubyte) val;
		observer.write(addr, memory[addr]);
		return cast(ubyte) val;
	}

	void run()
	{
		--pc;
		execute();
	}

	void resume()
	{
		execute();
	}

	private void execute()
	{
		for (;;)
		{
			if (instructionLimit >= 0 && instructions >= instructionLimit)
				return;
			++instructions;
			ubyte instr = fetchByte();
			observer.instruction(this);

			dispatch: switch (instr)
			{
			case 0x00:
				fetchByte();
				push((pc + 1) >> 8);
				push((pc + 1) & 0xff);
				push(p | 0x10);
				iflag = true;
				static if (isCmos!cpuVariant)
					dflag = false;
				pc = cast(ushort) (readWord(0xfffe, 0xffff) - 1);
				break;
			// Host escape: $02 followed by a selector byte.
			// Two-byte encoding on all 6502 variants:
			// JAM on NMOS, a 2-byte NOP on the CMOS parts, and COP on the 65C816
			// (and COP's signature byte is the selector).
			// An unregistered selector falls back to silicon behavior.
			case 0x02:
				{
					const selector = fetchByte();
					if (auto trap = selector in traps)
						(*trap)();
					else
					{
						static if (isCmos!cpuVariant) {}
						else
						{
							jam();
							return;
						}
					}
				}
				break;
			case 0x01: doIndirectX!ora(); break;
			case 0x05: doZeroPage!ora(); break;
			case 0x06: doZeroPage!asl(); break;
			case 0x08: idleFetch(); push(p | 0x10); break;
			case 0x09: doImmediate!ora(); break;
			case 0x0a: doAccumulator!asl(); break;
			case 0x0d: doAbsolute!ora(); break;
			case 0x0e: doAbsolute!asl(); break;
			case 0x10: doBranch!"!nflag"(); break;
			case 0x11: doIndirectY!ora(); break;
			case 0x15: doZeroPageIndexed!ora(x); break;
			case 0x16: doZeroPageIndexed!asl(x); break;
			case 0x18: idleFetch(); cflag = false; break;
			case 0x19: doAbsoluteIndexed!ora(y); break;
			case 0x1d: doAbsoluteIndexed!ora(x); break;
			case 0x1e: doAbsoluteIndexed!asl(x); break;
			case 0x20:
				const lo = fetchByte();
				idlePop();
				push((pc + 1) >> 8);
				push((pc + 1) & 0xff);
				pc = cast(ushort) (makeWord(fetchByte(), lo) - 1);
				break;
			case 0x21: doIndirectX!and(); break;
			case 0x24: doZeroPage!bit(); break;
			case 0x25: doZeroPage!and(); break;
			case 0x26: doZeroPage!rol(); break;
			case 0x28: idleFetch(); idlePop(); p = pop(); break;
			case 0x29: doImmediate!and(); break;
			case 0x2a: doAccumulator!rol(); break;
			case 0x2c: doAbsolute!bit(); break;
			case 0x2d: doAbsolute!and(); break;
			case 0x2e: doAbsolute!rol(); break;
			case 0x30: doBranch!"nflag"(); break;
			case 0x31: doIndirectY!and(); break;
			case 0x35: doZeroPageIndexed!and(x); break;
			case 0x36: doZeroPageIndexed!rol(x); break;
			case 0x38: idleFetch(); cflag = true; break;
			case 0x39: doAbsoluteIndexed!and(y); break;
			case 0x3d: doAbsoluteIndexed!and(x); break;
			case 0x3e: doAbsoluteIndexed!rol(x); break;
			case 0x40:
				idleFetch();
				idlePop();
				p = pop();
				ushort rti = pop();
				rti |= cast(ushort) (pop() << 8);
				pc = cast(ushort) (rti - 1);
				break;
			case 0x41: doIndirectX!eor(); break;
			case 0x45: doZeroPage!eor(); break;
			case 0x46: doZeroPage!lsr(); break;
			case 0x48: idleFetch(); push(a); break;
			case 0x49: doImmediate!eor(); break;
			case 0x4a: doAccumulator!lsr(); break;
			case 0x4c:
				pc = fetchWord();
				--pc;
				break;
			case 0x4d: doAbsolute!eor(); break;
			case 0x4e: doAbsolute!lsr(); break;
			case 0x50: doBranch!"!vflag"(); break;
			case 0x51: doIndirectY!eor(); break;
			case 0x55: doZeroPageIndexed!eor(x); break;
			case 0x56: doZeroPageIndexed!lsr(x); break;
			case 0x58: idleFetch(); iflag = false; break;
			case 0x59: doAbsoluteIndexed!eor(y); break;
			case 0x5d: doAbsoluteIndexed!eor(x); break;
			case 0x5e: doAbsoluteIndexed!lsr(x); break;
			case 0x60:
				idleFetch();
				idlePop();
				ushort ad = pop();
				ad |= cast(ushort) (pop() << 8);
				idleRead(ad);
				if (stopOnEmptyStackRts && sp == 0xff)
				{
					observer.endInstruction();
					return;
				}
				pc = ad;
				break;
			case 0x61: doIndirectX!adc(); break;
			case 0x65: doZeroPage!adc(); break;
			case 0x66: doZeroPage!ror(); break;
			case 0x68: idleFetch(); idlePop(); setNZ(a = pop()); break;
			case 0x69: doImmediate!adc(); break;
			case 0x6a: doAccumulator!ror(); break;
			case 0x6c: {
					const ptr = fetchWord();
					const wrapped =
						cast(ushort) ((ptr & 0xff00) | ((ptr + 1) & 0xff));
					const lo = ld(ptr);
					static if (isCmos!cpuVariant)
					{
						idleRead(wrapped);
						pc = cast(ushort) (makeWord(
							ld(cast(ushort) (ptr + 1)), lo) - 1);
					}
					else
						pc = cast(ushort) (makeWord(ld(wrapped), lo) - 1);
				}
				break;
			case 0x6d: doAbsolute!adc(); break;
			case 0x6e: doAbsolute!ror(); break;
			case 0x70: doBranch!"vflag"(); break;
			case 0x71: doIndirectY!adc(); break;
			case 0x75: doZeroPageIndexed!adc(x); break;
			case 0x76: doZeroPageIndexed!ror(x); break;
			case 0x78: idleFetch(); iflag = true; break;
			case 0x79: doAbsoluteIndexed!adc(y); break;
			case 0x7d: doAbsoluteIndexed!adc(x); break;
			case 0x7e: doAbsoluteIndexed!ror(x); break;
			case 0x81: doIndirectX!sta(); break;
			case 0x84: doZeroPage!sty(); break;
			case 0x85: doZeroPage!sta(); break;
			case 0x86: doZeroPage!stx(); break;
			case 0x88: idleFetch(); setNZ(--y); break;
			case 0x8a: idleFetch(); setNZ(a = x); break;
			case 0x8c: doAbsolute!sty(); break;
			case 0x8d: doAbsolute!sta(); break;
			case 0x8e: doAbsolute!stx(); break;
			case 0x90: doBranch!"!cflag"(); break;
			case 0x91: doIndirectY!sta(); break;
			case 0x94: doZeroPageIndexed!sty(x); break;
			case 0x95: doZeroPageIndexed!sta(x); break;
			case 0x96: doZeroPageIndexed!stx(y); break;
			case 0x98: idleFetch(); setNZ(a = y); break;
			case 0x99: doAbsoluteIndexed!sta(y); break;
			case 0x9a: idleFetch(); sp = x; break;
			case 0x9d: doAbsoluteIndexed!sta(x); break;
			case 0xa0: doImmediate!ldy(); break;
			case 0xa1: doIndirectX!lda(); break;
			case 0xa2: doImmediate!ldx(); break;
			case 0xa4: doZeroPage!ldy(); break;
			case 0xa5: doZeroPage!lda(); break;
			case 0xa6: doZeroPage!ldx(); break;
			case 0xa8: idleFetch(); setNZ(y = a); break;
			case 0xa9: doImmediate!lda(); break;
			case 0xaa: idleFetch(); setNZ(x = a); break;
			case 0xac: doAbsolute!ldy(); break;
			case 0xad: doAbsolute!lda(); break;
			case 0xae: doAbsolute!ldx(); break;
			case 0xb0: doBranch!"cflag"(); break;
			case 0xb1: doIndirectY!lda(); break;
			case 0xb4: doZeroPageIndexed!ldy(x); break;
			case 0xb5: doZeroPageIndexed!lda(x); break;
			case 0xb6: doZeroPageIndexed!ldx(y); break;
			case 0xb8: idleFetch(); vflag = false; break;
			case 0xb9: doAbsoluteIndexed!lda(y); break;
			case 0xba: idleFetch(); setNZ(x = sp); break;
			case 0xbc: doAbsoluteIndexed!ldy(x); break;
			case 0xbd: doAbsoluteIndexed!lda(x); break;
			case 0xbe: doAbsoluteIndexed!ldx(y); break;
			case 0xc0: doImmediate!cpy(); break;
			case 0xc1: doIndirectX!cmp(); break;
			case 0xc4: doZeroPage!cpy(); break;
			case 0xc5: doZeroPage!cmp(); break;
			case 0xc6: doZeroPage!dec(); break;
			case 0xc8: idleFetch(); setNZ(++y); break;
			case 0xc9: doImmediate!cmp(); break;
			case 0xca: idleFetch(); setNZ(--x); break;
			case 0xcc: doAbsolute!cpy(); break;
			case 0xcd: doAbsolute!cmp(); break;
			case 0xce: doAbsolute!dec(); break;
			case 0xd0: doBranch!"!zflag"(); break;
			case 0xd1: doIndirectY!cmp(); break;
			case 0xd5: doZeroPageIndexed!cmp(x); break;
			case 0xd6: doZeroPageIndexed!dec(x); break;
			case 0xd8: idleFetch(); dflag = false; break;
			case 0xd9: doAbsoluteIndexed!cmp(y); break;
			case 0xdd: doAbsoluteIndexed!cmp(x); break;
			case 0xde: doAbsoluteIndexed!dec(x); break;
			case 0xe0: doImmediate!cpx(); break;
			case 0xe1: doIndirectX!sbc(); break;
			case 0xe4: doZeroPage!cpx(); break;
			case 0xe5: doZeroPage!sbc(); break;
			case 0xe6: doZeroPage!inc(); break;
			case 0xe8: idleFetch(); setNZ(++x); break;
			case 0xe9: doImmediate!sbc(); break;
			case 0xea: idleFetch(); break;
			case 0xed: doAbsolute!sbc(); break;
			case 0xec: doAbsolute!cpx(); break;
			case 0xee: doAbsolute!inc(); break;
			case 0xf0: doBranch!"zflag"(); break;
			case 0xf1: doIndirectY!sbc(); break;
			case 0xf5: doZeroPageIndexed!sbc(x); break;
			case 0xf6: doZeroPageIndexed!inc(x); break;
			case 0xf8: idleFetch(); dflag = true; break;
			case 0xf9: doAbsoluteIndexed!sbc(y); break;
			case 0xfd: doAbsoluteIndexed!sbc(x); break;
			case 0xfe: doAbsoluteIndexed!inc(x); break;
			static if (isCmos!cpuVariant) {
			case 0x1a: idleFetch(); setNZ(a = cast(ubyte) (a + 1)); break;
			case 0x3a: idleFetch(); setNZ(a = cast(ubyte) (a - 1)); break;
			case 0x5a: idleFetch(); push(y); break;
			case 0x7a: idleFetch(); idlePop(); setNZ(y = pop()); break;
			case 0xda: idleFetch(); push(x); break;
			case 0xfa: idleFetch(); idlePop(); setNZ(x = pop()); break;
			case 0x80: doBranch!"true"(); break;
			case 0x89: zflag = (a & fetchByte()) == 0; break;
			case 0x64: doZeroPage!stz(); break;
			case 0x74: doZeroPageIndexed!stz(x); break;
			case 0x9c: doAbsolute!stz(); break;
			case 0x9e: doAbsoluteIndexed!stz(x); break;
			case 0x12: doIndirectZP!ora(); break;
			case 0x32: doIndirectZP!and(); break;
			case 0x52: doIndirectZP!eor(); break;
			case 0x72: doIndirectZP!adc(); break;
			case 0x92: doIndirectZP!sta(); break;
			case 0xb2: doIndirectZP!lda(); break;
			case 0xd2: doIndirectZP!cmp(); break;
			case 0xf2: doIndirectZP!sbc(); break;
			case 0x04: doZeroPage!tsb(); break;
			case 0x0c: doAbsolute!tsb(); break;
			case 0x14: doZeroPage!trb(); break;
			case 0x1c: doAbsolute!trb(); break;
			case 0x34: doZeroPageIndexed!bit(x); break;
			case 0x3c: doAbsoluteIndexed!bit(x); break;
			case 0x7c: {
				const base = fetchWord();
				idleRead(pc - 1);
				const ptr = cast(ushort) (base + x);
				pc = cast(ushort) (readWord(ptr, cast(ushort) (ptr + 1)) - 1);
				break;
			}
			static foreach (n; 0 .. 8)
			{
				static if (hasBitOps!cpuVariant)
				{
			case 0x07 + n * 0x10: doBitSetReset!(1 << n, false)(); break dispatch;
			case 0x87 + n * 0x10: doBitSetReset!(1 << n, true)(); break dispatch;
			case 0x0f + n * 0x10: doBitBranch!(1 << n, false)(); break dispatch;
			case 0x8f + n * 0x10: doBitBranch!(1 << n, true)(); break dispatch;
				}
				else static if (n & 1)
				{
			case 0x07 + n * 0x10:
			case 0x87 + n * 0x10: doZeroPageIndexed!nop(x); break dispatch;
			case 0x0f + n * 0x10:
			case 0x8f + n * 0x10: doNopAbsolute!true(); break dispatch;
				}
				else
				{
			case 0x07 + n * 0x10:
			case 0x87 + n * 0x10: doZeroPage!nop(); break dispatch;
			case 0x0f + n * 0x10:
			case 0x8f + n * 0x10: doNopAbsolute!false(); break dispatch;
				}
			}
			case 0xcb: // TODO: interrupts
				static if (hasWaiStp!cpuVariant)
				{
					stopped = true;
					observer.endInstruction();
					return;
				}
				else
				{
					idleFetch();
					break;
				}
			case 0xdb:
				static if (hasWaiStp!cpuVariant)
				{
					stopped = true;
					observer.endInstruction();
					return;
				}
				else
				{
					doZeroPageIndexed!nop(x);
					break;
				}
			case 0x03: case 0x13: case 0x23: case 0x33:
			case 0x43: case 0x53: case 0x63: case 0x73:
			case 0x83: case 0x93: case 0xa3: case 0xb3:
			case 0xc3: case 0xd3: case 0xe3: case 0xf3:
			case 0x0b: case 0x1b: case 0x2b: case 0x3b:
			case 0x4b: case 0x5b: case 0x6b: case 0x7b:
			case 0x8b: case 0x9b: case 0xab: case 0xbb:
			case 0xeb: case 0xfb:
				break;
			case 0x22: case 0x42: case 0x62: case 0x82:
			case 0xc2: case 0xe2:
				fetchByte(); break;
			case 0x44:
				doZeroPage!nop(); break;
			case 0x54: case 0xd4: case 0xf4:
				doZeroPageIndexed!nop(x); break;
			case 0x5c: case 0xdc: case 0xfc:
				doNopAbsolute!true(); break;
			}
			else // NMOS
			{
			case 0x83: doIndirectX!sax(); break;
			case 0x87: doZeroPage!sax(); break;
			case 0x8f: doAbsolute!sax(); break;
			case 0x97: doZeroPageIndexed!sax(y); break;
			case 0xa3: doIndirectX!lax(); break;
			case 0xa7: doZeroPage!lax(); break;
			case 0xaf: doAbsolute!lax(); break;
			case 0xb3: doIndirectY!lax(); break;
			case 0xb7: doZeroPageIndexed!lax(y); break;
			case 0xbf: doAbsoluteIndexed!lax(y); break;
			case 0x1a: case 0x3a: case 0x5a: case 0x7a: case 0xda: case 0xfa:
				idleFetch(); break;
			case 0x80: case 0x82: case 0x89: case 0xc2: case 0xe2:
				doImmediate!nop(); break;
			case 0x04: case 0x44: case 0x64:
				doZeroPage!nop(); break;
			case 0x14: case 0x34: case 0x54: case 0x74: case 0xd4: case 0xf4:
				doZeroPageIndexed!nop(x); break;
			case 0x0c:
				doAbsolute!nop(); break;
			case 0x1c: case 0x3c: case 0x5c: case 0x7c: case 0xdc: case 0xfc:
				doAbsoluteIndexed!nop(x); break;
			case 0x12: case 0x22: case 0x32: case 0x42: case 0x52: case 0x62:
			case 0x72: case 0x92: case 0xb2: case 0xd2: case 0xf2:
				fetchByte();
				jam();
				return;
			case 0x8b: doImmediate!ane(); break;
			case 0xab: doImmediate!laxImmediate(); break;
			case 0x9f: doUnstableStoreAbsoluteIndexed(y, a & x); break;
			case 0x93: doUnstableStoreIndirectY(a & x); break;
			case 0x9e: doUnstableStoreAbsoluteIndexed(y, x); break;
			case 0x9c: doUnstableStoreAbsoluteIndexed(x, y); break;
			case 0x9b: sp = a & x; doUnstableStoreAbsoluteIndexed(y, sp); break;
			case 0xbb: doAbsoluteIndexed!las(y); break;
			case 0x0b: case 0x2b: doImmediate!anc(); break;
			case 0x4b: doImmediate!alr(); break;
			case 0x6b: doImmediate!arr(); break;
			case 0xcb: doImmediate!sbx(); break;
			case 0xeb: doImmediate!sbc(); break;
			case 0x03: doIndirectX!slo(); break;
			case 0x07: doZeroPage!slo(); break;
			case 0x0f: doAbsolute!slo(); break;
			case 0x13: doIndirectY!slo(); break;
			case 0x17: doZeroPageIndexed!slo(x); break;
			case 0x1b: doAbsoluteIndexed!slo(y); break;
			case 0x1f: doAbsoluteIndexed!slo(x); break;
			case 0x23: doIndirectX!rla(); break;
			case 0x27: doZeroPage!rla(); break;
			case 0x2f: doAbsolute!rla(); break;
			case 0x33: doIndirectY!rla(); break;
			case 0x37: doZeroPageIndexed!rla(x); break;
			case 0x3b: doAbsoluteIndexed!rla(y); break;
			case 0x3f: doAbsoluteIndexed!rla(x); break;
			case 0x43: doIndirectX!sre(); break;
			case 0x47: doZeroPage!sre(); break;
			case 0x4f: doAbsolute!sre(); break;
			case 0x53: doIndirectY!sre(); break;
			case 0x57: doZeroPageIndexed!sre(x); break;
			case 0x5b: doAbsoluteIndexed!sre(y); break;
			case 0x5f: doAbsoluteIndexed!sre(x); break;
			case 0x63: doIndirectX!rra(); break;
			case 0x67: doZeroPage!rra(); break;
			case 0x6f: doAbsolute!rra(); break;
			case 0x73: doIndirectY!rra(); break;
			case 0x77: doZeroPageIndexed!rra(x); break;
			case 0x7b: doAbsoluteIndexed!rra(y); break;
			case 0x7f: doAbsoluteIndexed!rra(x); break;
			case 0xc3: doIndirectX!dcp(); break;
			case 0xc7: doZeroPage!dcp(); break;
			case 0xcf: doAbsolute!dcp(); break;
			case 0xd3: doIndirectY!dcp(); break;
			case 0xd7: doZeroPageIndexed!dcp(x); break;
			case 0xdb: doAbsoluteIndexed!dcp(y); break;
			case 0xdf: doAbsoluteIndexed!dcp(x); break;
			case 0xe3: doIndirectX!isc(); break;
			case 0xe7: doZeroPage!isc(); break;
			case 0xef: doAbsolute!isc(); break;
			case 0xf3: doIndirectY!isc(); break;
			case 0xf7: doZeroPageIndexed!isc(x); break;
			case 0xfb: doAbsoluteIndexed!isc(y); break;
			case 0xff: doAbsoluteIndexed!isc(x); break;
			}
			default:
				throw new Exception(
					format("Unimplemented instruction %02X", instr));
			}
			observer.endInstruction();
		}
	}

	void jsr(ushort addr)
	{
		push(0xff);
		push(0xff);
		pc = addr;
		run();
	}
}

unittest
{
	debug writeln("unittest host escape");

	static void load(E)(E emu, ushort addr, const(ubyte)[] bytes)
	{
		emu.ram[addr .. addr + bytes.length] = bytes;
		emu.pc = addr;
	}

	// A registered handler runs, may drive the machine, and execution carries
	// on after the two-byte escape.
	{
		auto emu = new Emulator!();
		int fired;
		emu.installTrap(0x37, delegate void() { fired++; emu.a = 0x5a; });
		load(emu, 0x1000, [ubyte(0x02), 0x37, 0xe8]);   // $02 $37 ; inx
		emu.instructionLimit = 2;
		emu.run();
		assert(fired == 1);
		assert(emu.a == 0x5a);      // the handler wrote through to the CPU
		assert(emu.x == 1);         // selector consumed, so inx was next
		assert(!emu.stopped);
	}

	// The selector byte picks the handler, and selector 0 is a valid choice.
	{
		auto emu = new Emulator!();
		ubyte[] seen;
		emu.installTrap(0, delegate void() { seen ~= 0; });
		emu.installTrap(1, delegate void() { seen ~= 1; });
		load(emu, 0x1000, [ubyte(0x02), 0x01, 0x02, 0x00]);
		emu.instructionLimit = 2;
		emu.run();
		assert(seen == [1, 0]);
	}

	// With no handler the escape falls back to what the silicon would do:
	// NMOS jams, reporting the address of the $02 rather than the selector.
	{
		auto emu = new Emulator!(CpuVariant.mos_6502)();
		load(emu, 0x1000, [ubyte(0x02), 0x37, 0xe8]);
		emu.instructionLimit = 2;
		emu.run();
		assert(emu.stopped);
		assert(emu.pc == 0x1000);
		assert(emu.x == 0);         // never got past the jam
	}

	// ... while the CMOS parts see it as an ordinary two-byte NOP.
	static foreach (v; [CpuVariant.wdc_65c02, CpuVariant.rockwell_r65c02, CpuVariant.wdc_w65c02s])
	{{
		auto emu = new Emulator!v();
		load(emu, 0x1000, [ubyte(0x02), 0x37, 0xe8]);
		emu.instructionLimit = 2;
		emu.run();
		assert(!emu.stopped, v.stringof);
		assert(emu.x == 1, v.stringof);   // both bytes skipped, inx ran
	}}
}

unittest
{
	debug writeln("unittest magic constant");

	// ANE #$FF with A = 0 and X = $FF leaves exactly the leaked bits in A.
	static ubyte ane(ubyte magic)
	{
		auto emu = new Emulator!(CpuVariant.mos_6502)();
		emu.magicConstant = magic;
		emu.ram[0x1000 .. 0x1002] = [ubyte(0x8b), 0xff];
		emu.pc = 0x1000;
		emu.a = 0;
		emu.x = 0xff;
		emu.instructionLimit = 1;
		emu.run();
		return emu.a;
	}
	assert(ane(0xee) == 0xee);
	assert(ane(0xff) == 0xff);
	assert(ane(0x00) == 0x00);
}

private version(unittest):

// TODO: build tests from source and extract the values from there
enum ushort entryPoint = 0x0400;
enum ushort testCaseVar = 0x0200;

enum long instructionsChunk = 1_000_000;
enum long instructionsLimit = 500_000_000;

bool isStuckSelfLoop(E)(E emu, ushort address)
{
	const opcode = emu.ld(address);
	if (opcode == 0x4c)                                  // jmp *
		return emu.dpeek(address + 1) == address;
	if (emu.ld(cast(ushort) (address + 1)) != 0xfe)      // not a branch to self
		return false;
	switch (opcode)
	{
	case 0x10: return !emu.nflag; // bpl
	case 0x30: return emu.nflag;  // bmi
	case 0x50: return !emu.vflag; // bvc
	case 0x70: return emu.vflag;  // bvs
	case 0x90: return !emu.cflag; // bcc
	case 0xb0: return emu.cflag;  // bcs
	case 0xd0: return !emu.zflag; // bne
	case 0xf0: return emu.zflag;  // beq
	case 0x80: return true;       // bra (65C02)
	default:   return false;
	}
}

ushort runToSelfLoop(E)(E emu, immutable(ubyte)[] image)
{
	foreach (i, b; image)
		emu.st(cast(ushort) i, b);
	emu.sp = 0xff;
	emu.pc = entryPoint;
	emu.instructions = 0;
	emu.stopOnEmptyStackRts = false;

	bool started;
	while (emu.instructions < instructionsLimit)
	{
		emu.instructionLimit = emu.instructions + instructionsChunk;
		if (started)
			emu.resume();
		else
		{
			emu.run();
			started = true;
		}
		foreach (ushort candidate; [cast(ushort) (emu.pc + 1), emu.pc])
			if (emu.isStuckSelfLoop(candidate))
				return candidate;
	}
	throw new Exception(format(
		"did not settle within %d instructions (pc=$%04X, test_case=%d)",
		instructionsLimit, emu.pc, emu.ld(testCaseVar)));
}

bool check(E)(E emu, string what, immutable(ubyte)[] image,
	ushort successAddress)
{
	writef("%-34s ", what ~ ":");
	stdout.flush();
	try
	{
		const trap = runToSelfLoop(emu, image);
		if (trap == successAddress)
		{
			writefln("PASS (success trap $%04X, %d instructions)", trap, emu.instructions);
			return true;
		}
		writefln("FAIL: stopped at $%04X, expected $%04X, test_case=%d",
			trap, successAddress, emu.ld(testCaseVar));
		writeln("       look the address up in the suite's .lst to identify the check");
	}
	catch (Exception e)
		writefln("FAIL: %s", e.msg);
	return false;
}

unittest
{
	import std.file : read;

	debug writeln("unittest emu");

	bool ok = true;

	// TODO: build tests from source instead of getting a magic address
	// manually from listings.
	ok &= check(new Emulator!(),
		"6502 functional test",
		cast(immutable(ubyte)[]) read("ext/6502_65C02_functional_tests/bin_files/6502_functional_test.bin"),
		0x3469);

	// Built with wdc_op=1 (WAI/STP skipped), rkwl_wdc_op=1 (BBR/BBS/RMB/SMB
	// fully tested) and skip_nop=0 (every undefined opcode tested as a NOP).
	ok &= check(new Emulator!(CpuVariant.wdc_w65c02s),
		"65C02 extended opcodes test",
		cast(immutable(ubyte)[]) read("ext/6502_65C02_functional_tests/bin_files/65C02_extended_opcodes_test.bin"),
		0x24f1);

	writeln(ok ? "all CPU tests passed" : "CPU TESTS FAILED");
	assert(ok);
}

struct State
{
	ushort pc;
	ubyte sp, a, x, y, p;

	void toString(W)(scope W writer) const
	{
		writer.formattedWrite!"pc=%04x s=%02x a=%02x x=%02x y=%02x p=%02x"(
			pc, sp, a, x, y, p);
	}
}

struct BusTrace
{
	const(ubyte)[] ram;
	string[] cycles;

	void instruction(E)(E emu) {}
	void fetch(ushort addr, ubyte value) { note('R', addr, value); }
	void read(ushort addr, ubyte value) { note('R', addr, value); }
	void write(ushort addr, ubyte value) { note('W', addr, value); }
	void idle(ushort addr) { note('R', addr, ram[addr]); }
	void endInstruction() {}

	private void note(char kind, ushort addr, ubyte value)
	{
		cycles ~= format("%s %04x %02x", kind, addr, value);
	}
}

void checkInstruction(CpuVariant v)(State initial, const(int[2])[] ram,
	State expected, const(int[2])[] changed, string trace,
	string file = __FILE__, size_t line = __LINE__)
{
	import std.algorithm : joiner;
	import std.array : join, split;

	assert((expected.p & 0x10) == 0);

	auto emu = new Emulator!(v, BusTrace)();
	emu.observer.ram = emu.ram;
	emu.stopOnEmptyStackRts = false;

	ubyte[ushort] want;
	foreach (cell; ram)
	{
		emu.ram[cell[0]] = cast(ubyte) cell[1];
		want[cast(ushort) cell[0]] = cast(ubyte) cell[1];
	}
	foreach (cell; changed)
		want[cast(ushort) cell[0]] = cast(ubyte) cell[1];

	emu.pc = initial.pc;
	emu.sp = initial.sp;
	emu.a = initial.a;
	emu.x = initial.x;
	emu.y = initial.y;
	emu.p = initial.p;
	emu.instructionLimit = 1;

	const opcode = emu.ram[initial.pc];
	emu.run();

	const where = format("%s(%d): %s $%02x", file, line, v, opcode);
	const got = State(cast(ushort) (emu.pc + 1), emu.sp, emu.a, emu.x, emu.y, emu.p);

	assert(got == expected, format("%s: state\n  got      %s\n  expected %s", where, got, expected));
	foreach (addr, value; want)
		assert(emu.ram[addr] == value, format("%s: $%04x is $%02x, expected $%02x",
			where, addr, emu.ram[addr], value));

	const gotTrace = emu.observer.cycles.join(" ");
	const expectedTrace = trace.split().join(" ");
	assert(gotTrace == expectedTrace,
		format("%s: %d cycles, expected %d\n  got      %s\n  expected %s", where,
			emu.observer.cycles.length, expectedTrace.split().length / 3,
			gotTrace, expectedTrace));
}

unittest
{
	debug writeln("unittest emu singlestep");

	// mos_6502, opcode $00: "00 3f f7"
	checkInstruction!(CpuVariant.mos_6502)(
		State(0x8b82, 0x51, 0xcb, 0x75, 0xa2, 0x6a), [[0x8b82, 0x00], [0x8b83, 0x3f], [0x8b84, 0xf7], [0xfffe, 0xd4], [0xffff, 0x25], [0x25d4, 0xed]],
		State(0x25d4, 0x4e, 0xcb, 0x75, 0xa2, 0x6e), [[0x014f, 0x7a], [0x0150, 0x84], [0x0151, 0x8b]],
		"R 8b82 00  R 8b83 3f  W 0151 8b  W 0150 84  W 014f 7a  R fffe d4  R ffff 25");

	// mos_6502, opcode $01: "01 bd b0"
	checkInstruction!(CpuVariant.mos_6502)(
		State(0xd5c4, 0x61, 0xa7, 0xf7, 0xf8, 0x28), [[0xd5c4, 0x01], [0xd5c5, 0xbd], [0xd5c6, 0xb0], [0x00bd, 0x58], [0x00b4, 0x81], [0x00b5, 0xeb], [0xeb81, 0x13]],
		State(0xd5c6, 0x61, 0xb7, 0xf7, 0xf8, 0xa8), [],
		"R d5c4 01  R d5c5 bd  R 00bd 58  R 00b4 81  R 00b5 eb  R eb81 13");

	// mos_6502, opcode $06: "06 89 7c"
	checkInstruction!(CpuVariant.mos_6502)(
		State(0xec81, 0x56, 0xaa, 0xdd, 0xba, 0x29), [[0xec81, 0x06], [0xec82, 0x89], [0xec83, 0x7c], [0x0089, 0x42]],
		State(0xec83, 0x56, 0xaa, 0xdd, 0xba, 0xa8), [[0x0089, 0x84]],
		"R ec81 06  R ec82 89  R 0089 42  W 0089 42  W 0089 84");

	// mos_6502, opcode $20: "20 55 13"
	checkInstruction!(CpuVariant.mos_6502)(
		State(0x017b, 0x7d, 0x9e, 0x89, 0x34, 0xe6), [[0x017b, 0x20], [0x017c, 0x55], [0x017d, 0x13], [0x0155, 0xad]],
		State(0x0155, 0x7b, 0x9e, 0x89, 0x34, 0xe6), [[0x017c, 0x7d], [0x017d, 0x01]],
		"R 017b 20  R 017c 55  R 017d 13  W 017d 01  W 017c 7d  R 017d 01");

	// mos_6502, opcode $61: "61 91 cd"
	// ADC (zp,x) BCD: B3+46+1 == 113+46+1 == (1)60
	checkInstruction!(CpuVariant.mos_6502)(
		State(0xf372, 0x4c, 0xb3, 0x50, 0xd1, 0x6b), [[0xf372, 0x61], [0xf373, 0x91], [0xf374, 0xcd], [0x0091, 0xdc], [0x00e1, 0x1d], [0x00e2, 0x2c], [0x2c1d, 0x46]],
		State(0xf374, 0x4c, 0x60, 0x50, 0xd1, 0x29), [],
		"R f372 61  R f373 91  R 0091 dc  R 00e1 1d  R 00e2 2c  R 2c1d 46");

	// mos_6502, opcode $6c: "6c ff 70"
	// JMP ($70ff) bug
	checkInstruction!(CpuVariant.mos_6502)(
		State(0x2887, 0x47, 0x23, 0x66, 0xb2, 0x24), [[0x2887, 0x6c], [0x2888, 0xff], [0x2889, 0x70], [0x70ff, 0x9d], [0x7000, 0x98], [0x989d, 0x23]],
		State(0x989d, 0x47, 0x23, 0x66, 0xb2, 0x24), [],
		"R 2887 6c  R 2888 ff  R 2889 70  R 70ff 9d  R 7000 98");

	// mos_6502, opcode $08: "08 60 be"
	// PHP does idle fetch cycle
	checkInstruction!(CpuVariant.mos_6502)(
		State(0x2f81, 0x26, 0x87, 0x6a, 0xb4, 0x2b), [[0x2f81, 0x08], [0x2f82, 0x60], [0x2f83, 0xbe]],
		State(0x2f82, 0x25, 0x87, 0x6a, 0xb4, 0x2b), [[0x0126, 0x3b]],
		"R 2f81 08  R 2f82 60  W 0126 3b");

	// mos_6502, opcode $10: "10 b3 8d"
	// BPL taken
	checkInstruction!(CpuVariant.mos_6502)(
		State(0x90ca, 0x8c, 0x3c, 0x86, 0x68, 0x25), [[0x90ca, 0x10], [0x90cb, 0xb3], [0x90cc, 0x8d], [0x907f, 0xe7]],
		State(0x907f, 0x8c, 0x3c, 0x86, 0x68, 0x25), [],
		"R 90ca 10  R 90cb b3  R 90cc 8d");

	// mos_6502, opcode $10: "10 3c 3a"
	// BPL taken across page
	checkInstruction!(CpuVariant.mos_6502)(
		State(0x77e1, 0xed, 0xec, 0x04, 0xfb, 0x2a), [[0x77e1, 0x10], [0x77e2, 0x3c], [0x77e3, 0x3a], [0x771f, 0x88], [0x781f, 0xc7]],
		State(0x781f, 0xed, 0xec, 0x04, 0xfb, 0x2a), [],
		"R 77e1 10  R 77e2 3c  R 77e3 3a  R 771f 88");

	// mos_6502, opcode $18: "18 c9 9b"
	checkInstruction!(CpuVariant.mos_6502)(
		State(0x09a8, 0x26, 0xd7, 0x79, 0xbf, 0xec), [[0x09a8, 0x18], [0x09a9, 0xc9], [0x09aa, 0x9b]],
		State(0x09a9, 0x26, 0xd7, 0x79, 0xbf, 0xec), [],
		"R 09a8 18  R 09a9 c9");

	// mos_6502, opcode $28: "28 c6 97"
	// PLP does idle fetch and idle pop
	checkInstruction!(CpuVariant.mos_6502)(
		State(0xa532, 0xa3, 0x9e, 0x77, 0x6e, 0xad), [[0xa532, 0x28], [0xa533, 0xc6], [0xa534, 0x97], [0x01a3, 0x30], [0x01a4, 0x94]],
		State(0xa533, 0xa4, 0x9e, 0x77, 0x6e, 0xa4), [],
		"R a532 28  R a533 c6  R 01a3 30  R 01a4 94");

	// mos_6502, opcode $38: "38 08 67"
	checkInstruction!(CpuVariant.mos_6502)(
		State(0x85d6, 0x43, 0xa8, 0xd2, 0xb7, 0xe1), [[0x85d6, 0x38], [0x85d7, 0x08], [0x85d8, 0x67]],
		State(0x85d7, 0x43, 0xa8, 0xd2, 0xb7, 0xe1), [],
		"R 85d6 38  R 85d7 08");

	// mos_6502, opcode $40: "40 9c 2c"
	// RTI does idle fetch and idle pop
	checkInstruction!(CpuVariant.mos_6502)(
		State(0x8771, 0x6e, 0xa2, 0x81, 0x7e, 0x63), [[0x8771, 0x40], [0x8772, 0x9c], [0x8773, 0x2c], [0x016e, 0x98], [0x016f, 0x9c], [0x0170, 0xaa], [0x0171, 0x65], [0x65aa, 0x0e]],
		State(0x65aa, 0x71, 0xa2, 0x81, 0x7e, 0xac), [],
		"R 8771 40  R 8772 9c  R 016e 98  R 016f 9c  R 0170 aa  R 0171 65");

	// mos_6502, opcode $48: "48 e0 36"
	// PHA does idle fetch
	checkInstruction!(CpuVariant.mos_6502)(
		State(0x5063, 0x9f, 0x3e, 0x33, 0x4e, 0xac), [[0x5063, 0x48], [0x5064, 0xe0], [0x5065, 0x36]],
		State(0x5064, 0x9e, 0x3e, 0x33, 0x4e, 0xac), [[0x019f, 0x3e]],
		"R 5063 48  R 5064 e0  W 019f 3e");

	// mos_6502, opcode $58: "58 71 bb"
	checkInstruction!(CpuVariant.mos_6502)(
		State(0x448a, 0xf5, 0xb6, 0xd3, 0x96, 0xa9), [[0x448a, 0x58], [0x448b, 0x71], [0x448c, 0xbb]],
		State(0x448b, 0xf5, 0xb6, 0xd3, 0x96, 0xa9), [],
		"R 448a 58  R 448b 71");

	// mos_6502, opcode $60: "60 14 e2"
	// RTS does idle fetch, idle pop, and idle PC-1 read
	checkInstruction!(CpuVariant.mos_6502)(
		State(0x4147, 0xcb, 0xe7, 0x14, 0x64, 0xa6), [[0x4147, 0x60], [0x4148, 0x14], [0x4149, 0xe2], [0x01cb, 0x98], [0x01cc, 0xdc], [0x01cd, 0x1d], [0x1ddc, 0x5d], [0x1ddd, 0xda]],
		State(0x1ddd, 0xcd, 0xe7, 0x14, 0x64, 0xa6), [],
		"R 4147 60  R 4148 14  R 01cb 98  R 01cc dc  R 01cd 1d  R 1ddc 5d");

	// mos_6502, opcode $68: "68 b4 82"
	// PLA does idle fetch and idle pop
	checkInstruction!(CpuVariant.mos_6502)(
		State(0x3021, 0xa4, 0x32, 0xb2, 0x4a, 0x2e), [[0x3021, 0x68], [0x3022, 0xb4], [0x3023, 0x82], [0x01a4, 0xe0], [0x01a5, 0x36]],
		State(0x3022, 0xa5, 0x36, 0xb2, 0x4a, 0x2c), [],
		"R 3021 68  R 3022 b4  R 01a4 e0  R 01a5 36");

	// mos_6502, opcode $78: "78 ac 45"
	checkInstruction!(CpuVariant.mos_6502)(
		State(0x3eb3, 0xa0, 0xa2, 0x8c, 0x01, 0xa4), [[0x3eb3, 0x78], [0x3eb4, 0xac], [0x3eb5, 0x45]],
		State(0x3eb4, 0xa0, 0xa2, 0x8c, 0x01, 0xa4), [],
		"R 3eb3 78  R 3eb4 ac");

	// mos_6502, opcode $91: "91 bb 6e"
	// STA (zp),y w/ index penalty
	checkInstruction!(CpuVariant.mos_6502)(
		State(0x1c86, 0x95, 0x3f, 0x11, 0x1c, 0x2b), [[0x1c86, 0x91], [0x1c87, 0xbb], [0x1c88, 0x6e], [0x00bb, 0x8d], [0x00bc, 0x59], [0x59a9, 0xd5]],
		State(0x1c88, 0x95, 0x3f, 0x11, 0x1c, 0x2b), [[0x59a9, 0x3f]],
		"R 1c86 91  R 1c87 bb  R 00bb 8d  R 00bc 59  R 59a9 d5  W 59a9 3f");

	// mos_6502, opcode $83: "83 1b c1"
	// SAX (zp,x)
	checkInstruction!(CpuVariant.mos_6502)(
		State(0xb525, 0x86, 0xbe, 0x60, 0x8a, 0x6c), [[0xb525, 0x83], [0xb526, 0x1b], [0xb527, 0xc1], [0x001b, 0x4c], [0x007b, 0x42], [0x007c, 0x3a]],
		State(0xb527, 0x86, 0xbe, 0x60, 0x8a, 0x6c), [[0x3a42, 0x20]],
		"R b525 83  R b526 1b  R 001b 4c  R 007b 42  R 007c 3a  W 3a42 20");

	// mos_6502, opcode $87: "87 3c 74"
	// SAX zp
	checkInstruction!(CpuVariant.mos_6502)(
		State(0xad56, 0x91, 0xc2, 0xa4, 0x70, 0x6d), [[0xad56, 0x87], [0xad57, 0x3c], [0xad58, 0x74]],
		State(0xad58, 0x91, 0xc2, 0xa4, 0x70, 0x6d), [[0x003c, 0x80]],
		"R ad56 87  R ad57 3c  W 003c 80");

	// mos_6502, opcode $8f: "8f 5f a0"
	// SAX abs
	checkInstruction!(CpuVariant.mos_6502)(
		State(0x5f95, 0x48, 0xc5, 0x8a, 0xc9, 0x64), [[0x5f95, 0x8f], [0x5f96, 0x5f], [0x5f97, 0xa0], [0x5f98, 0x44]],
		State(0x5f98, 0x48, 0xc5, 0x8a, 0xc9, 0x64), [[0xa05f, 0x80]],
		"R 5f95 8f  R 5f96 5f  R 5f97 a0  W a05f 80");

	// mos_6502, opcode $97: "97 8b 67"
	// SAX zp,y wraps within zero page
	checkInstruction!(CpuVariant.mos_6502)(
		State(0x901d, 0x42, 0xbf, 0x1a, 0xe3, 0xe0), [[0x901d, 0x97], [0x901e, 0x8b], [0x901f, 0x67], [0x008b, 0xc9]],
		State(0x901f, 0x42, 0xbf, 0x1a, 0xe3, 0xe0), [[0x006e, 0x1a]],
		"R 901d 97  R 901e 8b  R 008b c9  W 006e 1a");

	// mos_6502, opcode $a3: "a3 4e d0"
	// LAX (zp,x)
	checkInstruction!(CpuVariant.mos_6502)(
		State(0xe472, 0xba, 0x61, 0xe7, 0x4c, 0x2d), [[0xe472, 0xa3], [0xe473, 0x4e], [0xe474, 0xd0], [0x004e, 0x72], [0x0035, 0xe6], [0x0036, 0x20], [0x20e6, 0x8f]],
		State(0xe474, 0xba, 0x8f, 0x8f, 0x4c, 0xad), [],
		"R e472 a3  R e473 4e  R 004e 72  R 0035 e6  R 0036 20  R 20e6 8f");

	// mos_6502, opcode $a7: "a7 f0 99"
	// LAX zp
	checkInstruction!(CpuVariant.mos_6502)(
		State(0x777f, 0x5b, 0xe3, 0x52, 0xd9, 0xab), [[0x777f, 0xa7], [0x7780, 0xf0], [0x7781, 0x99], [0x00f0, 0x0c]],
		State(0x7781, 0x5b, 0x0c, 0x0c, 0xd9, 0x29), [],
		"R 777f a7  R 7780 f0  R 00f0 0c");

	// mos_6502, opcode $af: "af 6d 59"
	// LAX abs
	checkInstruction!(CpuVariant.mos_6502)(
		State(0xff9a, 0xee, 0x7c, 0x08, 0x7c, 0xe9), [[0xff9a, 0xaf], [0xff9b, 0x6d], [0xff9c, 0x59], [0x596d, 0xe7], [0xff9d, 0x5c]],
		State(0xff9d, 0xee, 0xe7, 0xe7, 0x7c, 0xe9), [],
		"R ff9a af  R ff9b 6d  R ff9c 59  R 596d e7");

	// mos_6502, opcode $b3: "b3 eb bb"
	// LAX (zp),y across page: dummy read at the unfixed address
	checkInstruction!(CpuVariant.mos_6502)(
		State(0x0139, 0x9c, 0x69, 0xf5, 0x81, 0x6c), [[0x0139, 0xb3], [0x013a, 0xeb], [0x013b, 0xbb], [0x00eb, 0xd6], [0x00ec, 0x8c], [0x8c57, 0xd4], [0x8d57, 0xab]],
		State(0x013b, 0x9c, 0xab, 0xab, 0x81, 0xec), [],
		"R 0139 b3  R 013a eb  R 00eb d6  R 00ec 8c  R 8c57 d4  R 8d57 ab");

	// mos_6502, opcode $b7: "b7 6b 71"
	// LAX zp,y
	checkInstruction!(CpuVariant.mos_6502)(
		State(0xe5a5, 0x68, 0x9f, 0x61, 0x54, 0x64), [[0xe5a5, 0xb7], [0xe5a6, 0x6b], [0xe5a7, 0x71], [0x006b, 0xba], [0x00bf, 0xe1]],
		State(0xe5a7, 0x68, 0xe1, 0xe1, 0x54, 0xe4), [],
		"R e5a5 b7  R e5a6 6b  R 006b ba  R 00bf e1");

	// mos_6502, opcode $bf: "bf 1f f7"
	// LAX abs,y, no page crossing
	checkInstruction!(CpuVariant.mos_6502)(
		State(0x0b88, 0x64, 0xfa, 0x4f, 0x2c, 0xa5), [[0x0b88, 0xbf], [0x0b89, 0x1f], [0x0b8a, 0xf7], [0xf74b, 0x62], [0x0b8b, 0xa9]],
		State(0x0b8b, 0x64, 0x62, 0x62, 0x2c, 0x25), [],
		"R 0b88 bf  R 0b89 1f  R 0b8a f7  R f74b 62");

	// mos_6502, opcode $bf: "bf 54 1c"
	// LAX abs,y across page
	checkInstruction!(CpuVariant.mos_6502)(
		State(0xa814, 0x1b, 0x7c, 0x4a, 0xdc, 0xa0), [[0xa814, 0xbf], [0xa815, 0x54], [0xa816, 0x1c], [0x1c30, 0x09], [0x1d30, 0xd3], [0xa817, 0x4f]],
		State(0xa817, 0x1b, 0xd3, 0xd3, 0xdc, 0xa0), [],
		"R a814 bf  R a815 54  R a816 1c  R 1c30 09  R 1d30 d3");

	// wdc_65c02, opcode $07: "07 28 a5"
	// NOP absolute
	checkInstruction!(CpuVariant.wdc_65c02)(
		State(0x2f7b, 0x32, 0x42, 0x71, 0x5d, 0x2f), [[0x2f7b, 0x07], [0x2f7c, 0x28], [0x2f7d, 0xa5], [0x0028, 0xba]],
		State(0x2f7d, 0x32, 0x42, 0x71, 0x5d, 0x2f), [],
		"R 2f7b 07  R 2f7c 28  R 0028 ba");

	// wdc_65c02, opcode $0f: "0f 7c f5"
	// NOP absolute
	checkInstruction!(CpuVariant.wdc_65c02)(
		State(0x8da5, 0x9c, 0x88, 0x57, 0x65, 0xe8), [[0x8da5, 0x0f], [0x8da6, 0x7c], [0x8da7, 0xf5], [0x8da8, 0xe1]],
		State(0x8da8, 0x9c, 0x88, 0x57, 0x65, 0xe8), [],
		"R 8da5 0f  R 8da6 7c  R 8da7 f5");

	// wdc_65c02, opcode $17: "17 ab f6"
	// NOP absolute indexed
	checkInstruction!(CpuVariant.wdc_65c02)(
		State(0xf0f6, 0xac, 0xf6, 0xd2, 0x9b, 0xa6), [[0xf0f6, 0x17], [0xf0f7, 0xab], [0xf0f8, 0xf6], [0x00ab, 0x03], [0x007d, 0xdb]],
		State(0xf0f8, 0xac, 0xf6, 0xd2, 0x9b, 0xa6), [],
		"R f0f6 17  R f0f7 ab  R 00ab 03  R 007d db");

	// wdc_65c02, opcode $1a: "1a ea 57"
	// INC @ does idle fetch
	checkInstruction!(CpuVariant.wdc_65c02)(
		State(0x1abb, 0x3b, 0x3d, 0x6b, 0x7e, 0xa1), [[0x1abb, 0x1a], [0x1abc, 0xea], [0x1abd, 0x57]],
		State(0x1abc, 0x3b, 0x3e, 0x6b, 0x7e, 0x21), [],
		"R 1abb 1a  R 1abc ea");

	// wdc_65c02, opcode $44: "44 3c d4"
	// NOP zp
	checkInstruction!(CpuVariant.wdc_65c02)(
		State(0xd5c9, 0xa0, 0x1e, 0xdc, 0x6b, 0x22), [[0xd5c9, 0x44], [0xd5ca, 0x3c], [0xd5cb, 0xd4], [0x003c, 0x99]],
		State(0xd5cb, 0xa0, 0x1e, 0xdc, 0x6b, 0x22), [],
		"R d5c9 44  R d5ca 3c  R 003c 99");

	// wdc_65c02, opcode $6c: "6c 42 fc"
	// JMP (abs) always takes an extra cycle
	checkInstruction!(CpuVariant.wdc_65c02)(
		State(0x96ff, 0xc4, 0x96, 0xf7, 0x9b, 0xaf), [[0x96ff, 0x6c], [0x9700, 0x42], [0x9701, 0xfc], [0xfc42, 0xb1], [0xfc43, 0x3f], [0x3fb1, 0x0a]],
		State(0x3fb1, 0xc4, 0x96, 0xf7, 0x9b, 0xaf), [],
		"R 96ff 6c  R 9700 42  R 9701 fc  R fc42 b1  R fc43 3f  R fc43 3f");

	// wdc_65c02, opcode $5c: "5c 83 a9"
	// NOP abs,X
	checkInstruction!(CpuVariant.wdc_65c02)(
		State(0x7e40, 0x80, 0xdb, 0xc0, 0x1f, 0x6f), [[0x7e40, 0x5c], [0x7e41, 0x83], [0x7e42, 0xa9], [0x7e43, 0xef]],
		State(0x7e43, 0x80, 0xdb, 0xc0, 0x1f, 0x6f), [],
		"R 7e40 5c  R 7e41 83  R 7e42 a9  R 7e42 a9");

	// wdc_65c02, opcode $7a: "7a 24 4c"
	// PLY does idle fetch and idle pop
	checkInstruction!(CpuVariant.wdc_65c02)(
		State(0xeeed, 0x9d, 0x46, 0xf3, 0x49, 0xab), [[0xeeed, 0x7a], [0xeeee, 0x24], [0xeeef, 0x4c], [0x019d, 0x9e], [0x019e, 0x80]],
		State(0xeeee, 0x9e, 0x46, 0xf3, 0x80, 0xa9), [],
		"R eeed 7a  R eeee 24  R 019d 9e  R 019e 80");

	// wdc_65c02, opcode $91: "91 c9 f2"
	// STA (zp),y always does idle read at PC
	checkInstruction!(CpuVariant.wdc_65c02)(
		State(0x9d92, 0x6e, 0x1f, 0xf4, 0x4b, 0xef), [[0x9d92, 0x91], [0x9d93, 0xc9], [0x9d94, 0xf2], [0x00c9, 0x80], [0x00ca, 0xd4]],
		State(0x9d94, 0x6e, 0x1f, 0xf4, 0x4b, 0xef), [[0xd4cb, 0x1f]],
		"R 9d92 91  R 9d93 c9  R 00c9 80  R 00ca d4  R 9d93 c9  W d4cb 1f");

	// wdc_65c02, opcode $7c: "7c 32 9f"
	// JMP (abs,x)
	checkInstruction!(CpuVariant.wdc_65c02)(
		State(0x83c8, 0xf1, 0xe2, 0x6f, 0x8c, 0xe4), [[0x83c8, 0x7c], [0x83c9, 0x32], [0x83ca, 0x9f], [0x9fa1, 0x76], [0x9fa2, 0x2b], [0x2b76, 0x76]],
		State(0x2b76, 0xf1, 0xe2, 0x6f, 0x8c, 0xe4), [],
		"R 83c8 7c  R 83c9 32  R 83ca 9f  R 83c9 32  R 9fa1 76  R 9fa2 2b");

	// wdc_65c02, opcode $cb: "cb 4a 20"
	// NOP imp
	checkInstruction!(CpuVariant.wdc_65c02)(
		State(0x7487, 0x15, 0xd2, 0xf9, 0x06, 0x22), [[0x7487, 0xcb], [0x7488, 0x4a], [0x7489, 0x20]],
		State(0x7488, 0x15, 0xd2, 0xf9, 0x06, 0x22), [],
		"R 7487 cb  R 7488 4a");

	// wdc_65c02, opcode $db: "db cf 42"
	// NOP zp,x
	checkInstruction!(CpuVariant.wdc_65c02)(
		State(0x6aeb, 0x6f, 0x61, 0x9e, 0xd5, 0x27), [[0x6aeb, 0xdb], [0x6aec, 0xcf], [0x6aed, 0x42], [0x00cf, 0x8b], [0x006d, 0x85]],
		State(0x6aed, 0x6f, 0x61, 0x9e, 0xd5, 0x27), [],
		"R 6aeb db  R 6aec cf  R 00cf 8b  R 006d 85");

	// wdc_65c02, opcode $f1: "f1 3"
	// SBC (zp,x) BCD
	checkInstruction!(CpuVariant.wdc_65c02)(
		State(0x73e6, 0x45, 0xf3, 0xfc, 0x7e, 0xe8), [[0x00ff, 0x15], [0x1638, 0x1f], [0x00fe, 0xba], [0x73e7, 0xfe], [0x73e6, 0xf1]],
		State(0x73e8, 0x45, 0xcd, 0xfc, 0x7e, 0xa9), [],
		"R 73e6 f1  R 73e7 fe  R 00fe ba  R 00ff 15  R 73e7 fe  R 1638 1f  R 1638 1f");

	// wdc_65c02, opcode $69: "69 47 e1"
	// ADC #imm BCD
	// SingleStepTests expect a dummy read at $0056, but that looks suspicious
	// and probably it should be pc+1. TODO: check on real hardware.
	checkInstruction!(CpuVariant.wdc_65c02)(
		State(0x1378, 0xaf, 0x73, 0x19, 0xe9, 0x29), [[0x1378, 0x69], [0x1379, 0x47], [0x137a, 0xe1], [0x0056, 0x6d]],
		State(0x137a, 0xaf, 0x21, 0x19, 0xe9, 0x69), [],
		"R 1378 69  R 1379 47  R 137a e1");

	// wdc_w65c02s, opcode $04: "04 a7 8c"
	// TSB zp
	checkInstruction!(CpuVariant.wdc_w65c02s)(
		State(0xe8ee, 0x21, 0xa6, 0xa5, 0xc5, 0xee), [[0xe8ee, 0x04], [0xe8ef, 0xa7], [0xe8f0, 0x8c], [0x00a7, 0x6f]],
		State(0xe8f0, 0x21, 0xa6, 0xa5, 0xc5, 0xec), [[0x00a7, 0xef]],
		"R e8ee 04  R e8ef a7  R 00a7 6f  R 00a7 6f  W 00a7 ef");

	// wdc_w65c02s, opcode $07: "07 1f 9e"
	// RMB0
	checkInstruction!(CpuVariant.wdc_w65c02s)(
		State(0x5c3f, 0xbf, 0x34, 0x0c, 0x45, 0xe1), [[0x5c3f, 0x07], [0x5c40, 0x1f], [0x5c41, 0x9e], [0x001f, 0xaa]],
		State(0x5c41, 0xbf, 0x34, 0x0c, 0x45, 0xe1), [],
		"R 5c3f 07  R 5c40 1f  R 001f aa  R 001f aa  W 001f aa");

	// wdc_w65c02s, opcode $0f: "0f 1"
	checkInstruction!(CpuVariant.wdc_w65c02s)(
		State(0xfeb7, 0x2f, 0xe9, 0x9d, 0x86, 0x68), [[0xfeba, 0xe9], [0xfeb9, 0x54], [0x0035, 0x3c], [0xfeb8, 0x35], [0xfeb7, 0x0f]],
		State(0xff0e, 0x2f, 0xe9, 0x9d, 0x86, 0x68), [],
		"R feb7 0f  R feb8 35  R 0035 3c  R 0035 3c  R feb9 54  R feba e9  R feba e9");

	// wdc_w65c02s, opcode $0f: "0f 2"
	checkInstruction!(CpuVariant.wdc_w65c02s)(
		State(0x40fc, 0x72, 0xd2, 0x47, 0x46, 0x67), [[0x40fe, 0x8a], [0x00af, 0x3d], [0x40fd, 0xaf], [0x40fc, 0x0f]],
		State(0x40ff, 0x72, 0xd2, 0x47, 0x46, 0x67), [],
		"R 40fc 0f  R 40fd af  R 00af 3d  R 00af 3d  R 40fe 8a");

	// wdc_w65c02s, opcode $1f: "1f 1"
	checkInstruction!(CpuVariant.wdc_w65c02s)(
		State(0x1a2f, 0xdc, 0x03, 0x6a, 0x49, 0xe7), [[0x1a32, 0x2e], [0x1a31, 0x48], [0x0023, 0xdc], [0x1a30, 0x23], [0x1a2f, 0x1f]],
		State(0x1a7a, 0xdc, 0x03, 0x6a, 0x49, 0xe7), [],
		"R 1a2f 1f  R 1a30 23  R 0023 dc  R 0023 dc  R 1a31 48  R 1a32 2e");
}
