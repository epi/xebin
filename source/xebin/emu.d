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

version(unittest) import std.stdio;

private ushort makeWord(uint b1, uint b0)
{
	return cast(ushort) ((b1 << 8) | b0);
}

string substOperand(string expr, string read, string writeOpen)
{
	return expr.replace("@w(", writeOpen).replace("@r", read);
}

enum adc =
q{
	uint arg = ld(addr);
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
		if (al >= 10)
		{
			tmp += al < 26 ? 6 : -10;
			nflag = (tmp & 0x80) != 0;
		}
		vflag = (~(arg ^ a) & (a ^ tmp) & 0x80) != 0;
		if (tmp >= 0xa0)
		{
			cflag = true;
			a = (tmp + 0x60) & 0xff;
		}
		else
		{
			cflag = false;
			a = tmp & 0xff;
		}
		static if (isCmos!cpuVariant)
			setNZ(a);
		else
			setNZ(tmp & 0xff);
	}
};

enum sbc =
q{
	ubyte operand = @r;
	ubyte arg = cast(ubyte) ~operand;
	ubyte oa = a;
	uint tmp = oa + arg + cflag;
	ubyte bin = tmp & 0xff;
	setNZ(bin);
	vflag = (~(arg ^ oa) & (oa ^ bin) & 0x80) != 0;
	if (!dflag)
		a = bin;
	else
	{
		int al = (oa & 0x0f) - (operand & 0x0f) + cflag - 1;
		if (al < 0)
			al = ((al - 0x06) & 0x0f) - 0x10;
		int res = (oa & 0xf0) - (operand & 0xf0) + al;
		if (res < 0)
			res -= 0x60;
		a = cast(ubyte) res;
		static if (isCmos!cpuVariant)
			setNZ(a);
	}
	cflag = tmp >= 0x100;
};

enum cmp = q{ ubyte tmp = ld(addr); setNZ(a - tmp); cflag = a >= tmp; };
enum cpx = q{ ubyte tmp = ld(addr); setNZ(x - tmp); cflag = x >= tmp; };
enum cpy = q{ ubyte tmp = ld(addr); setNZ(y - tmp); cflag = y >= tmp; };
enum lda = q{ setNZ(a = ld(addr)); };
enum ldx = q{ setNZ(x = ld(addr)); };
enum ldy = q{ setNZ(y = ld(addr)); };
enum ora = q{ setNZ(a |= ld(addr)); };
enum and = q{ setNZ(a &= ld(addr)); };
enum eor = q{ setNZ(a ^= ld(addr)); };
enum inc = q{ setNZ(st(addr, ld(addr) + 1)); };
enum dec = q{ setNZ(st(addr, ld(addr) - 1)); };
enum asl =
q{
	ubyte tmp = @r;
	cflag = (tmp & 0x80) != 0;
	tmp <<= 1;
	setNZ(tmp);
	@w(tmp);
};
enum rol =
q{
	ubyte tmp = @r;
	bool nc = (tmp & 0x80) != 0;
	tmp = cast(ubyte) ((tmp << 1) | cflag);
	cflag = nc;
	setNZ(tmp);
	@w(tmp);
};
enum lsr =
q{
	ubyte tmp = @r;
	cflag = (tmp & 1) != 0;
	tmp >>>= 1;
	setNZ(tmp);
	@w(tmp);
};
enum ror =
q{
	ubyte tmp = @r;
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
enum tsb = q{ ubyte tmp = @r; zflag = (a & tmp) == 0; @w(cast(ubyte) (tmp | a)); };
enum trb = q{ ubyte tmp = @r; zflag = (a & tmp) == 0; @w(cast(ubyte) (tmp & ~a)); };

///
enum CpuVariant {
	mos_6502,        /// NMOS
	wdc_65c02,       /// original CMOS (also Synertek, GTE, etc.), part of Lynx's Mikey
	rockwell_r65c02, /// Rockwell (bit ops)
	wdc_w65c02s,     /// modern W65C02S (bit ops + WAI/STP)}
}

///	Basic CMOS instruction set + BCD and JMP (abs) fixes.
enum bool isCmos(CpuVariant v) = v != CpuVariant.mos_6502;

///	RMBn/SMBn/BBRn/BBSn. Rockwell's addition, carried over into the W65C02S.
enum bool hasBitOps(CpuVariant v) =
	v == CpuVariant.rockwell_r65c02 || v == CpuVariant.wdc_w65c02s;

/// WAI and STP, added by the W65C02S; NOPs everywhere else.
enum bool hasWaiStp(CpuVariant v) = v == CpuVariant.wdc_w65c02s;

/**	The do-nothing observer, and the interface every observer implements.

	`Emulator` reports each instruction and each bus access here. Because the
	policy is a template parameter rather than a runtime flag, an emulator built
	with `NoObserver` has none of this code in it -- the hooks are empty and
	inline away, taking their arguments with them. Measured at ~50% of
	throughput versus testing a `bool` in the same places.

	On a 6502 every cycle is exactly one bus access, so the access stream is
	what a timing model needs; `idle` reports the cycles that do not carry an
	operand, whose addresses still take part in DRAM page-mode accounting.

	See `xebin.trace.CpuTracer` and `UniformTicks` for real ones, and `Compose`
	to install several at once.
*/
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

/**	Installs several observers at once, forwarding every hook to each in turn.

	`Compose!(CpuTracer, UniformTicks)` traces and counts ticks; reach the
	members through `observer.get!0`, `observer.get!1`.
*/
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

///	Counts every bus access as the same number of ticks.
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

class Emulator(CpuVariant cpuVariant = CpuVariant.mos_6502, Observer = NoObserver)
{
	/// Observer policy instance; configure it before running.
	Observer observer;

	/// Instructions retired. Always counted -- it is one add, and it gives a
	/// run budget that does not depend on any timing model being installed.
	long instructions;

	/// `run`/`resume` return once `instructions` reaches this; -1 disables.
	long instructionLimit = -1;

	private ubyte[] memory;
	private void delegate()[ubyte] traps;

	///	Registers `handler` for the $02 host escape with the given selector	byte.
	/// An escape with no handler is left to the silicon: a JAM on NMOS,
	///	a two-byte NOP on the CMOS parts.
	void installTrap(ubyte selector, void delegate() handler)
	{
		traps[selector] = handler;
	}

	///	The 64K address space, for hosts and debuggers that need to load or
	///	inspect it in bulk. CPU accesses go through `ld` and `st`.
	@property ubyte[] ram() { return memory; }

	bool stopOnEmptyStackRts = true;

	/// Set by STP, WAI or a JAM; execution returns and stays put.
	bool stopped;

	ubyte a;
	ubyte x;
	ubyte y;
	ushort pc;
	ubyte sp = 0xff;
	bool nflag;
	bool vflag;
	bool bflag;
	bool dflag;
	bool iflag;
	bool zflag;
	bool cflag;

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
		return makeWord(memory[addr + 1], memory[addr]);
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

	/// Two fetches, low byte first, as the hardware does them.
	ushort fetchWord()
	{
		const lo = fetchByte();
		const hi = fetchByte();
		return makeWord(hi, lo);
	}

	/// Reads a word through the bus, low byte first. For CPU-visible indirection
	/// only -- `dpeek` is the untimed host view.
	private ushort readWord(ushort addr, ushort hiAddr)
	{
		const lo = ld(addr);
		const hi = ld(hiAddr);
		return makeWord(hi, lo);
	}

	void doAccumulator(string expr)()
	{
		mixin(substOperand(expr, "a", "a = ("));
	}

	void doImmediate(string expr)()
	{
		++pc;
		alias pc addr;
		mixin(substOperand(expr, "ld(addr)", "st(addr, "));
	}

	void doAbsolute(string expr)(ubyte index = 0)
	{
		ushort addr = fetchWord();
		addr += index;
		mixin(substOperand(expr, "ld(addr)", "st(addr, "));
	}

	void doAbsoluteZP(string expr)(ubyte index = 0)
	{
		ubyte addr = fetchByte();
		addr += index;
		mixin(substOperand(expr, "ld(addr)", "st(addr, "));
	}

	void doIndirectY(string expr)()
	{
		const ushort zp = fetchByte();
		ushort addr = readWord(zp, cast(ushort) ((zp + 1) & 0xff));
		addr += y;
		mixin(substOperand(expr, "ld(addr)", "st(addr, "));
	}

	void doIndirectX(string expr)()
	{
		ushort zp = fetchByte();
		zp = (zp + x) & 0xff;
		const addr = readWord(zp, cast(ushort) ((zp + 1) & 0xff));
		mixin(substOperand(expr, "ld(addr)", "st(addr, "));
	}

	static if (isCmos!cpuVariant)
	void doIndirectZP(string expr)()
	{
		const ushort zp = fetchByte();
		const addr = readWord(zp, cast(ushort) ((zp + 1) & 0xff));
		mixin(substOperand(expr, "ld(addr)", "st(addr, "));
	}

	static if (isCmos!cpuVariant)
	void doBitSetReset(ubyte mask, bool set)()
	{
		const ubyte addr = fetchByte();
		const ubyte value = ld(addr);
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
		const byte offs = fetchByte();
		if (isSet == branchIfSet)
		{
			pc = cast(ushort) (pc + offs);
		}
	}

	void doBranch(string pred)()
	{
		byte offs = fetchByte();
		if (mixin(pred))
		{
			pc++;
			pc += offs;
			pc--;
		}
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
				push((pc + 2) >> 8);
				push((pc + 2) & 0xff);
				push(
					(nflag ? 0x80 : 0) |
					(vflag ? 0x40 : 0) |
					0x20 | 0x10 |
					(dflag ? 0x08 : 0) |
					(iflag ? 0x04 : 0) |
					(zflag ? 0x02 : 0) |
					(cflag ? 0x01 : 0));
				iflag = true;
				static if (isCmos!cpuVariant)
					dflag = false;
				pc = dpeek(0xfffe);
				--pc;
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
							--pc;   // JAM: report the address of the $02 itself
							stopped = true;
							observer.endInstruction();
							return;
						}
					}
				}
				break;
			case 0x01: doIndirectX!ora(); break;
			case 0x05: doAbsoluteZP!ora(); break;
			case 0x06: doAbsoluteZP!asl(); break;
			case 0x08:
				// PHP always pushes B set, regardless of how P was last pulled.
				push(
					(nflag ? 0x80 : 0) |
					(vflag ? 0x40 : 0) |
					0x20 | 0x10 |
					(dflag ? 0x08 : 0) |
					(iflag ? 0x04 : 0) |
					(zflag ? 0x02 : 0) |
					(cflag ? 0x01 : 0));
				break;
			case 0x09: doImmediate!ora(); break;
			case 0x0a: doAccumulator!asl(); break;
			case 0x0d: doAbsolute!ora(); break;
			case 0x0e: doAbsolute!asl(); break;
			case 0x10: doBranch!"!nflag"(); break;
			case 0x11: doIndirectY!ora(); break;
			case 0x15: doAbsoluteZP!ora(x); break;
			case 0x16: doAbsoluteZP!asl(x); break;
			case 0x18: cflag = false; break;
			case 0x19: doAbsolute!ora(y); break;
			case 0x1d: doAbsolute!ora(x); break;
			case 0x1e: doAbsolute!asl(x); break;
			case 0x20:
				push((pc + 2) >> 8);
				push((pc + 2) & 0xff);
				pc = fetchWord();
				--pc;
				break;
			case 0x21: doIndirectX!and(); break;
			case 0x24: doAbsoluteZP!bit(); break;
			case 0x25: doAbsoluteZP!and(); break;
			case 0x26: doAbsoluteZP!rol(); break;
			case 0x28:
				{
					auto p = pop();
					nflag = (p & 0x80) != 0;
					vflag = (p & 0x40) != 0;
					bflag = (p & 0x10) != 0;
					dflag = (p & 0x08) != 0;
					iflag = (p & 0x04) != 0;
					zflag = (p & 0x02) != 0;
					cflag = (p & 0x01) != 0;
				}
				break;
			case 0x29: doImmediate!and(); break;
			case 0x2a: doAccumulator!rol(); break;
			case 0x2c: doAbsolute!bit(); break;
			case 0x2d: doAbsolute!and(); break;
			case 0x2e: doAbsolute!rol(); break;
			case 0x30: doBranch!"nflag"(); break;
			case 0x31: doIndirectY!and(); break;
			case 0x35: doAbsoluteZP!and(x); break;
			case 0x36: doAbsoluteZP!rol(x); break;
			case 0x38: cflag = true; break;
			case 0x39: doAbsolute!and(y); break;
			case 0x3d: doAbsolute!and(x); break;
			case 0x3e: doAbsolute!rol(x); break;
			case 0x40:
				{
					auto p = pop();
					nflag = (p & 0x80) != 0;
					vflag = (p & 0x40) != 0;
					bflag = (p & 0x10) != 0;
					dflag = (p & 0x08) != 0;
					iflag = (p & 0x04) != 0;
					zflag = (p & 0x02) != 0;
					cflag = (p & 0x01) != 0;
				}
				ushort rti = pop();
				rti |= cast(ushort) (pop() << 8);
				pc = cast(ushort) (rti - 1);
				break;
			case 0x41: doIndirectX!eor(); break;
			case 0x45: doAbsoluteZP!eor(); break;
			case 0x46: doAbsoluteZP!lsr(); break;
			case 0x48: push(a); break;
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
			case 0x55: doAbsoluteZP!eor(x); break;
			case 0x56: doAbsoluteZP!lsr(x); break;
			case 0x58: iflag = false; break;
			case 0x59: doAbsolute!eor(y); break;
			case 0x5d: doAbsolute!eor(x); break;
			case 0x5e: doAbsolute!lsr(x); break;
			case 0x60:
				ushort ad = pop();
				ad |= cast(ushort) (pop() << 8);
				if (stopOnEmptyStackRts && sp == 0xff)
				{
					observer.endInstruction();
					return;
				}
				pc = ad;
				break;
			case 0x61: doIndirectX!adc(); break;
			case 0x65: doAbsoluteZP!adc(); break;
			case 0x66: doAbsoluteZP!ror(); break;
			case 0x68: setNZ(a = pop()); break;
			case 0x69: doImmediate!adc(); break;
			case 0x6a: doAccumulator!ror(); break;
			case 0x6c:
				ushort ad = fetchWord();
				pc = dpeek(ad);
				--pc;
				break;
			case 0x6d: doAbsolute!adc(); break;
			case 0x6e: doAbsolute!ror(); break;
			case 0x70: doBranch!"vflag"(); break;
			case 0x71: doIndirectY!adc(); break;
			case 0x75: doAbsoluteZP!adc(x); break;
			case 0x76: doAbsoluteZP!ror(x); break;
			case 0x78: iflag = true; break;
			case 0x79: doAbsolute!adc(y); break;
			case 0x7d: doAbsolute!adc(x); break;
			case 0x7e: doAbsolute!ror(x); break;
			case 0x81: doIndirectX!"st(addr, a);"(); break;
			case 0x84: doAbsoluteZP!"st(addr, y);"(); break;
			case 0x85: doAbsoluteZP!"st(addr, a);"(); break;
			case 0x86: doAbsoluteZP!"st(addr, x);"(); break;
			case 0x88: setNZ(--y); break;
			case 0x8a: setNZ(a = x); break;
			case 0x8c: doAbsolute!"st(addr, y);"(); break;
			case 0x8d: doAbsolute!"st(addr, a);"(); break;
			case 0x8e: doAbsolute!"st(addr, x);"(); break;
			case 0x90: doBranch!"!cflag"(); break;
			case 0x91: doIndirectY!"st(addr, a);"(); break;
			case 0x94: doAbsoluteZP!"st(addr, y);"(x); break;
			case 0x95: doAbsoluteZP!"st(addr, a);"(x); break;
			case 0x96: doAbsoluteZP!"st(addr, x);"(y); break;
			case 0x98: setNZ(a = y); break;
			case 0x99: doAbsolute!"st(addr, a);"(y); break;
			case 0x9a: sp = x; break;
			case 0x9d: doAbsolute!"st(addr, a);"(x); break;
			case 0xa0: doImmediate!ldy(); break;
			case 0xa1: doIndirectX!lda(); break;
			case 0xa2: doImmediate!ldx(); break;
			case 0xa4: doAbsoluteZP!ldy(); break;
			case 0xa5: doAbsoluteZP!lda(); break;
			case 0xa6: doAbsoluteZP!ldx(); break;
			case 0xa8: setNZ(y = a); break;
			case 0xa9: doImmediate!lda(); break;
			case 0xaa: setNZ(x = a); break;
			case 0xac: doAbsolute!ldy(); break;
			case 0xad: doAbsolute!lda(); break;
			case 0xae: doAbsolute!ldx(); break;
			case 0xb0: doBranch!"cflag"(); break;
			case 0xb1: doIndirectY!lda(); break;
			case 0xb4: doAbsoluteZP!ldy(x); break;
			case 0xb5: doAbsoluteZP!lda(x); break;
			case 0xb6: doAbsoluteZP!ldx(y); break;
			case 0xb8: vflag = false; break;
			case 0xb9: doAbsolute!lda(y); break;
			case 0xba: setNZ(x = sp); break;
			case 0xbc: doAbsolute!ldy(x); break;
			case 0xbd: doAbsolute!lda(x); break;
			case 0xbe: doAbsolute!ldx(y); break;
			case 0xc0: doImmediate!cpy(); break;
			case 0xc1: doIndirectX!cmp(); break;
			case 0xc4: doAbsoluteZP!cpy(); break;
			case 0xc5: doAbsoluteZP!cmp(); break;
			case 0xc6: doAbsoluteZP!dec(); break;
			case 0xc8: setNZ(++y); break;
			case 0xc9: doImmediate!cmp(); break;
			case 0xca: setNZ(--x); break;
			case 0xcc: doAbsolute!cpy(); break;
			case 0xcd: doAbsolute!cmp(); break;
			case 0xce: doAbsolute!dec(); break;
			case 0xd0: doBranch!"!zflag"(); break;
			case 0xd1: doIndirectY!cmp(); break;
			case 0xd5: doAbsoluteZP!cmp(x); break;
			case 0xd6: doAbsoluteZP!dec(x); break;
			case 0xd8: dflag = false; break;
			case 0xd9: doAbsolute!cmp(y); break;
			case 0xdd: doAbsolute!cmp(x); break;
			case 0xde: doAbsolute!dec(x); break;
			case 0xe0: doImmediate!cpx(); break;
			case 0xe1: doIndirectX!sbc(); break;
			case 0xe4: doAbsoluteZP!cpx(); break;
			case 0xe5: doAbsoluteZP!sbc(); break;
			case 0xe6: doAbsoluteZP!inc(); break;
			case 0xe8: setNZ(++x); break;
			case 0xe9: doImmediate!sbc(); break;
			case 0xea: break;
			case 0xed: doAbsolute!sbc(); break;
			case 0xec: doAbsolute!cpx(); break;
			case 0xee: doAbsolute!inc(); break;
			case 0xf0: doBranch!"zflag"(); break;
			case 0xf1: doIndirectY!sbc(); break;
			case 0xf5: doAbsoluteZP!sbc(x); break;
			case 0xf6: doAbsoluteZP!inc(x); break;
			case 0xf8: dflag = true; break;
			case 0xf9: doAbsolute!sbc(y); break;
			case 0xfd: doAbsolute!sbc(x); break;
			case 0xfe: doAbsolute!inc(x); break;
			static if (isCmos!cpuVariant) {
			case 0x1a: setNZ(a = cast(ubyte) (a + 1)); break; // INC A
			case 0x3a: setNZ(a = cast(ubyte) (a - 1)); break; // DEC A
			case 0x5a: push(y); break;                        // PHY
			case 0x7a: setNZ(y = pop()); break;               // PLY
			case 0xda: push(x); break;                        // PHX
			case 0xfa: setNZ(x = pop()); break;               // PLX
			case 0x80: doBranch!"true"(); break;              // BRA
			case 0x89: zflag = (a & fetchByte()) == 0; break; // BIT #imm (65C02: Z only)
			case 0x64: doAbsoluteZP!"st(addr, 0);"(); break;  // STZ zp
			case 0x74: doAbsoluteZP!"st(addr, 0);"(x); break; // STZ zp,X
			case 0x9c: doAbsolute!"st(addr, 0);"(); break;    // STZ abs
			case 0x9e: doAbsolute!"st(addr, 0);"(x); break;   // STZ abs,X
			// (zp) -- the indirect mode without an index register
			case 0x12: doIndirectZP!ora(); break;
			case 0x32: doIndirectZP!and(); break;
			case 0x52: doIndirectZP!eor(); break;
			case 0x72: doIndirectZP!adc(); break;
			case 0x92: doIndirectZP!"st(addr, a);"(); break;
			case 0xb2: doIndirectZP!lda(); break;
			case 0xd2: doIndirectZP!cmp(); break;
			case 0xf2: doIndirectZP!sbc(); break;
			// test and set / reset memory bits
			case 0x04: doAbsoluteZP!tsb(); break;
			case 0x0c: doAbsolute!tsb(); break;
			case 0x14: doAbsoluteZP!trb(); break;
			case 0x1c: doAbsolute!trb(); break;
			// indexed BIT (these do set N and V, unlike BIT #imm)
			case 0x34: doAbsoluteZP!bit(x); break;
			case 0x3c: doAbsolute!bit(x); break;
			case 0x7c:                                        // JMP (abs,X)
				pc = dpeek(cast(ushort) (fetchWord() + x));
				--pc;
				break;
			// Rockwell bit operations. RMBn/SMBn clear or set one bit of a
			// zero page location; BBRn/BBSn branch on one. On parts that lack
			// them the same 32 slots are one-byte NOPs.
			static foreach (n; 0 .. 8)
			{
				static if (hasBitOps!cpuVariant)
				{
			case 0x07 + n * 0x10: doBitSetReset!(1 << n, false)(); break dispatch;
			case 0x87 + n * 0x10: doBitSetReset!(1 << n, true)(); break dispatch;
			case 0x0f + n * 0x10: doBitBranch!(1 << n, false)(); break dispatch;
			case 0x8f + n * 0x10: doBitBranch!(1 << n, true)(); break dispatch;
				}
				else
				{
			case 0x07 + n * 0x10:
			case 0x87 + n * 0x10:
			case 0x0f + n * 0x10:
			case 0x8f + n * 0x10: break dispatch;
				}
			}
			// WAI and STP, likewise NOPs on everything but the W65C02S. There
			// is no interrupt model yet, so both simply halt.
			case 0xcb:
			case 0xdb:
				static if (hasWaiStp!cpuVariant)
				{
					stopped = true;
					observer.endInstruction();
					return;
				}
				else
					break;
			// Every remaining opcode is a NOP on the 65C02, but they differ in
			// length, so the operand bytes still have to be consumed.
			static foreach (op; [0x03, 0x13, 0x23, 0x33, 0x43, 0x53, 0x63, 0x73,
				0x83, 0x93, 0xa3, 0xb3, 0xc3, 0xd3, 0xe3, 0xf3,
				0x0b, 0x1b, 0x2b, 0x3b, 0x4b, 0x5b, 0x6b, 0x7b,
				0x8b, 0x9b, 0xab, 0xbb, 0xeb, 0xfb])
			{
			case op: break dispatch;                           // one byte
			}
			static foreach (op; [0x22, 0x42, 0x62, 0x82, 0xc2, 0xe2,
				0x44, 0x54, 0xd4, 0xf4])
			{
			case op: fetchByte(); break dispatch;               // two bytes
			}
			static foreach (op; [0x5c, 0xdc, 0xfc])
			{
			case op: fetchByte(); fetchByte(); break dispatch;  // three bytes
			}
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

private version(unittest) {

	// TODO: build tests from source and extract the values from there
	enum ushort entryPoint = 0x0400;
	enum ushort testCaseVar = 0x0200;

	enum long chunkInstructions = 1_000_000;
	enum long budgetInstructions = 200_000_000;

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
		while (emu.instructions < budgetInstructions)
		{
			emu.instructionLimit = emu.instructions + chunkInstructions;
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
			budgetInstructions, emu.pc, emu.ld(testCaseVar)));
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
			writefln("FAIL -- stopped at $%04X, expected $%04X, test_case=%d",
				trap, successAddress, emu.ld(testCaseVar));
			writeln("       look the address up in the suite's .lst to identify the check");
		}
		catch (Exception e)
			writefln("FAIL -- %s", e.msg);
		return false;
	}
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
