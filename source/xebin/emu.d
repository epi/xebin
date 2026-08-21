module xebin.emu;

import std.string;

version(unittest) import std.stdio;

private ushort makeWord(uint b1, uint b0)
{
	return cast(ushort) ((b1 << 8) | b0);
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
	ubyte operand = @;
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
enum asl = q{ ubyte tmp = @; cflag = (tmp & 0x80) != 0; tmp <<= 1; setNZ(@ = tmp); };
enum rol =
q{
	ubyte tmp = @;
	bool nc = (tmp & 0x80) != 0;
	tmp = cast(ubyte) ((tmp << 1) | cflag);
	cflag = nc;
	setNZ(@ = tmp);
};
enum lsr =
q{
	cflag = @ & 1;
	setNZ(@ >>>= 1);
};
enum ror =
q{
	ubyte tmp = @;
	bool nc = tmp & 1;
	setNZ(@ = cast(ubyte) ((tmp >>> 1) | (cflag ? 0x80 : 0)));
	cflag = nc;
};
enum bit =
q{
	zflag = (a & @) == 0;
	nflag = (@ & 0x80) != 0;
	vflag = (@ & 0x40) != 0;
};
enum tsb = q{ zflag = (a & @) == 0; @ = cast(ubyte) (@ | a); };
enum trb = q{ zflag = (a & @) == 0; @ = cast(ubyte) (@ & ~a); };

private immutable ubyte[256] baseCycles =
{
	ubyte[256] c;
	foreach (ref v; c)
		v = 2; // implied / immediate / accumulator / relative (branch not taken)
	void set(ubyte cyc, const(ubyte)[] ops)
	{
		foreach (o; ops)
			c[o] = cyc;
	}
	set(3, [0x05, 0x24, 0x25, 0x45, 0x65, 0x84, 0x85, 0x86, 0xa4, 0xa5, 0xa6,
		0xc4, 0xc5, 0xe4, 0xe5,           // zp load/store/ALU, BIT zp, CPx/CPy zp
		0x64,                             // STZ zp
		0x08, 0x48, 0x5a, 0xda,           // PHP PHA PHY PHX
		0x4c]);                           // JMP abs
	set(4, [0x0d, 0x2c, 0x2d, 0x4d, 0x6d, 0x8c, 0x8d, 0x8e, 0x9c, 0xac, 0xad,
		0xae, 0xcc, 0xcd, 0xec, 0xed,     // abs load/store/ALU, BIT abs, STZ abs
		0x15, 0x35, 0x55, 0x75, 0xf5, 0x95, 0xb5, 0x74,
		0x94, 0x96, 0xb4, 0xb6, 0xd5, // zp,X load/store/ALU, STZ zp,X
		0x19, 0x1d, 0x39, 0x3d, 0x59, 0x5d, 0x79, 0x7d, // abs,X/Y load/ALU
		0xb9, 0xbc, 0xbd, 0xbe, 0xd9, 0xdd, 0xf9, 0xfd,
		0x28, 0x68, 0x7a, 0xfa]);         // PLP PLA PLY PLX
	set(5, [0x06, 0x26, 0x46, 0x66, 0xc6, 0xe6,         // RMW zp
		0x11, 0x31, 0x51, 0x71, 0xb1, 0xd1, 0xf1,      // (zp),Y
		0x99, 0x9d, 0x9e,                              // STA abs,Y/X, STZ abs,X
		0x6c]);                                        // JMP (abs)
	set(6, [0x20, 0x60, 0x40,                          // JSR RTS RTI
		0x01, 0x21, 0x41, 0x61, 0x81, 0xa1, 0xc1, 0xe1, // (zp,X)
		0x0e, 0x2e, 0x4e, 0x6e, 0xce, 0xee,            // RMW abs
		0x91,                                          // STA (zp),Y
		0x16, 0x36, 0x56, 0x76, 0xd6, 0xf6]);          // RMW zp,X
	set(7, [0x00,                                       // BRK
		0x1e, 0x3e, 0x5e, 0x7e, 0xde, 0xfe]);          // RMW abs,X
	return c;
}();

///
enum CpuVariant {
	mos_6502,        /// NMOS
	wdc_65c02,       /// original CMOS re-design
	gte_65sc02,      /// e.g. Lynx
	rockwell_r65c02, /// Rockwell
	wdc_w65c02s,     /// modern W65C02S
}

///	Basic CMOS instruction set + BCD and JMP (abs) fixes.
enum bool isCmos(CpuVariant v) = v != CpuVariant.mos_6502;

///	RMBn/SMBn/BBRn/BBSn. Rockwell's addition, carried over into the W65C02S.
enum bool hasBitOps(CpuVariant v) =
	v == CpuVariant.rockwell_r65c02 || v == CpuVariant.wdc_w65c02s;

/// WAI and STP, added by the W65C02S; NOPs everywhere else.
enum bool hasWaiStp(CpuVariant v) = v == CpuVariant.wdc_w65c02s;

/**	The do-nothing tracing policy, and the interface every tracer implements.

	`Emulator` calls these on every instruction and every `ld`/`st`. Because the
	policy is a template parameter rather than a runtime flag, an emulator built
	with `NoTrace` has no tracing code in it at all -- the hooks are empty and
	inline away, taking the arguments with them. That is worth roughly 40% of
	throughput compared with testing a `bool` in the same places.

	See `xebin.trace.CpuTracer` for one that actually prints something.
*/
struct NoTrace
{
	/// Called after the opcode is fetched, with pc still on the opcode.
	void instruction(E)(E emu) {}
	void read(ushort addr, ubyte value) {}   /// Called from `ld`.
	void write(ushort addr, ubyte value) {}  /// Called from `st`.
	/// Called once the instruction is done, to emit whatever accumulated.
	void endInstruction() {}
}

class Emulator(CpuVariant cpuVariant = CpuVariant.mos_6502, Trace = NoTrace)
{
	/// Tracing policy instance; configure it before running.
	Trace tracer;

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

	long cycles;
	long cycleLimit = -1;

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
		memory[0x100 + sp--] = cast(ubyte) b;
	}

	ubyte pop()
	{
		return memory[0x100 + ++sp];
	}

	ubyte fetchByte()
	{
		return memory[++pc];
	}

	ushort fetchWord()
	{
		pc += 2;
		ushort result = makeWord(memory[pc], memory[pc - 1]);
		return result;
	}

	void doAccumulator(string expr)()
	{
		mixin(replace(expr, "@", "a"));
	}

	void doImmediate(string expr)()
	{
		++pc;
		alias pc addr;
		mixin(replace(expr, "@", "memory[pc]"));
	}

	void doAbsolute(string expr)(ubyte index = 0)
	{
		ushort addr = fetchWord();
		addr += index;
		mixin(replace(expr, "@", "memory[addr]"));
	}

	void doAbsoluteZP(string expr)(ubyte index = 0)
	{
		ubyte addr = fetchByte();
		addr += index;
		mixin(replace(expr, "@", "memory[addr]"));
	}

	void doIndirectY(string expr)()
	{
		ushort addr = fetchByte();
		addr = makeWord(memory[(addr + 1) & 0xff], memory[addr]);
		addr += y;
		mixin(replace(expr, "@", "memory[addr]"));
	}

	void doIndirectX(string expr)()
	{
		ushort addr = fetchByte();
		addr += x;
		addr = makeWord(memory[(addr + 1) & 0xff], memory[addr & 0xff]);
		mixin(replace(expr, "@", "memory[addr]"));
	}

	static if (isCmos!cpuVariant)
	void doIndirectZP(string expr)()
	{
		ushort zp = fetchByte();
		ushort addr = makeWord(memory[(zp + 1) & 0xff], memory[zp]);
		mixin(replace(expr, "@", "memory[addr]"));
	}

	static if (isCmos!cpuVariant)
	void doBitSetReset(ubyte mask, bool set)()
	{
		const ubyte addr = fetchByte();
		static if (set)
			memory[addr] |= mask;
		else
			memory[addr] &= cast(ubyte) ~mask;
	}

	static if (hasBitOps!cpuVariant)
	void doBitBranch(ubyte mask, bool branchIfSet)()
	{
		const ubyte zp = fetchByte();
		const bool isSet = (memory[zp] & mask) != 0;
		const byte offs = fetchByte();
		if (isSet == branchIfSet)
		{
			pc = cast(ushort) (pc + offs);
			++cycles;
		}
	}

	void doBranch(string pred)()
	{
		byte offs = fetchByte();
		if (mixin(pred))
		{
			ushort oldpc = pc;
			pc++;
			pc += offs;
			pc--;
			++cycles;                                   // taken branch: +1
			if (((oldpc + 1) & 0xff00) != ((pc + 1) & 0xff00))
				++cycles;                               // crosses a page: +1 more
		}
	}

	void setNZ(uint res)
	{
		zflag = res == 0;
		nflag = (res & 0x80) != 0;
	}

	ubyte ld(ushort addr)
	{
		tracer.read(addr, memory[addr]);
		return memory[addr];
	}

	ubyte st(ushort addr, uint val)
	{
		memory[addr] = cast(ubyte) val;
		tracer.write(addr, memory[addr]);
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
			if (cycleLimit >= 0 && cycles >= cycleLimit)
				return;
			ubyte instr = fetchByte();
			cycles += baseCycles[instr];
			tracer.instruction(this);

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
							tracer.endInstruction();
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
					tracer.endInstruction();
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
			case 0x89: ++pc; zflag = (a & memory[pc]) == 0; break; // BIT #imm (65C02: Z only)
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
					tracer.endInstruction();
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
			case op: ++pc; break dispatch;                     // two bytes
			}
			static foreach (op; [0x5c, 0xdc, 0xfc])
			{
			case op: pc += 2; break dispatch;                  // three bytes
			}
			}
			default:
				throw new Exception(
					format("Unimplemented instruction %02X", instr));
			}
			tracer.endInstruction();
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
		emu.cycleLimit = 4;
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
		emu.cycleLimit = 4;
		emu.run();
		assert(seen == [1, 0]);
	}

	// With no handler the escape falls back to what the silicon would do:
	// NMOS jams, reporting the address of the $02 rather than the selector.
	{
		auto emu = new Emulator!(CpuVariant.mos_6502)();
		load(emu, 0x1000, [ubyte(0x02), 0x37, 0xe8]);
		emu.cycleLimit = 4;
		emu.run();
		assert(emu.stopped);
		assert(emu.pc == 0x1000);
		assert(emu.x == 0);         // never got past the jam
	}

	// ... while the CMOS parts see it as an ordinary two-byte NOP.
	static foreach (v; [CpuVariant.wdc_65c02, CpuVariant.gte_65sc02,
		CpuVariant.rockwell_r65c02, CpuVariant.wdc_w65c02s])
	{{
		auto emu = new Emulator!v();
		load(emu, 0x1000, [ubyte(0x02), 0x37, 0xe8]);
		emu.cycleLimit = 4;
		emu.run();
		assert(!emu.stopped, v.stringof);
		assert(emu.x == 1, v.stringof);   // both bytes skipped, inx ran
	}}
}

private version(unittest) {

	// TODO: build tests from source and extract the values from there
	enum ushort entryPoint = 0x0400;
	enum ushort testCaseVar = 0x0200;

	enum long chunkCycles = 1_000_000;
	enum long budgetCycles = 500_000_000;

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
		emu.cycles = 0;
		emu.stopOnEmptyStackRts = false;

		bool started;
		while (emu.cycles < budgetCycles)
		{
			emu.cycleLimit = emu.cycles + chunkCycles;
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
			"did not settle within %d cycles (pc=$%04X, test_case=%d)",
			budgetCycles, emu.pc, emu.ld(testCaseVar)));
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
				writefln("PASS (success trap $%04X, %d cycles)", trap, emu.cycles);
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
