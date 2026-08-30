/**	(Written in D programming language)

	Atari XL/XE host emulation on top of CPU emulation in `xebin.emu.Emulator`.

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

module xebin.atari;

import std.algorithm;
import std.array;
import std.exception;
import std.format : format;
import std.range : empty, front, popFront;
import std.stdio;
import std.string;

import xebin.binary;

/**	Drives `Emulator` as an Atari XL/XE, by installing host escape handlers
	for the OS entry points a binary expects to be able to call.
*/
class AtariHost(E)
{
	/// Escape selector bytes this host claims.
	enum Escape : ubyte {
		exit, cio, brk
	}

	private E emu;
	private File[7] iocbs;

	/// Traces every CIO call to stderr.
	bool ioTrace;

	/// Reports each block as it is loaded, and the init/run addresses taken.
	bool traceLoad;

	this(E emu)
	{
		this.emu = emu;
	}

	void loadAndRun(BinaryBlock[] blocks)
	{
		emu.sp = 0xff;
		emu.dpoke(0x2e7, 0x706);
		emu.dpoke(0x2e5, 0xbc1f);
		emu.dpoke(0xa, 0x700);

		emu.ram[0x0700] = 0x02;
		emu.ram[0x0701] = 0x00;
		emu.installTrap(Escape.exit, delegate void()
		{
			import core.stdc.stdlib : exit;
			exit(0);
		});

		emu.ram[0xe456] = 0x02;
		emu.ram[0xe457] = 0x01;
		emu.ram[0xe458] = 0x60;
		emu.installTrap(Escape.cio, &cio);

		emu.ram[0xfff8] = 0x02; // host escape
		emu.ram[0xfff9] = 0x02;
		emu.ram[0xfffa] = 0xf8; // nmi vector
		emu.ram[0xfffb] = 0xff;
		emu.ram[0xfffe] = 0xf8; // irq/brk vector
		emu.ram[0xffff] = 0xff;
		emu.installTrap(Escape.brk, delegate void()
		{
			emu.pop();                               // P
			ushort baddr = emu.pop();                // return address, low byte first
			baddr |= cast(ushort) (emu.pop() << 8);
			baddr -= 2;                              // back up over BRK + signature
			throw new Exception(format("BRK at %04X", baddr));
		});

		emu.ram[0x0340] = 0;
		for (uint ad = 0x0340 + 0x10; ad < 0x340 + 0x80; ++ad)
			emu.ram[ad] = 255;

		bool run = false;
		foreach (block; blocks)
		{
			if (traceLoad)
			{
				writefln("Load %d bytes at %04X-%04X", block.length,
					block.addr, block.end);
			}
			emu.ram[block.addr .. block.addr + block.length] = block.data[];
			if (block.isInit)
			{
				const initaddr = emu.dpeek(initAd);
				if (traceLoad)
					writefln("Init at %04X", initaddr);
				emu.jsr(initaddr);
			}
			run |= block.isRun;
		}
		if (run)
		{
			const runaddr = emu.dpeek(runAd);
			if (traceLoad)
				writefln("Run at %04X", runaddr);
			emu.jsr(runaddr);
		}
	}

	void consoleIO(uint cmd, uint addr, uint len)
	{
		if (ioTrace)
			writeln();
		switch (cmd)
		{
		case 5:
			const s = readln().representation;
			const l = min(len, s.length);
			foreach (ubyte ch; s[0 .. l])
				emu.ram[addr++] = (ch == '\n') ? 0x9b : ch;
			emu.dpoke(0x348, l);
			break;
		case 9:
			if (!len)
				len = 1;
			foreach (ubyte ch; emu.ram[addr .. addr + len])
			{
				if (ch == 0x9b)
				{
					putchar('\n');
					break;
				}
				else
					putchar(ch);
			}
			break;
		case 11:
			if (!len)
				putchar(emu.a == 0x9b ? '\n' : emu.a);
			else
			{
				foreach (ubyte ch; emu.ram[addr .. addr + len])
					putchar(ch == 0x9b ? '\n' : ch);
			}
			break;
		default:
			emu.setNZ(emu.y = 132);
		}
	}

	void cio()
	{
		emu.setNZ(emu.y = 1);
		uint iocb = emu.x;
		uint cmd = emu.ram[0x342 + emu.x];
		uint addr = emu.dpeek(0x344 + emu.x);
		uint len = emu.dpeek(0x348 + emu.x);
		uint aux1 = emu.ram[0x34a + emu.x];
		uint aux2 = emu.ram[0x34b + emu.x];
		if (ioTrace)
			stderr.writef(
				"CIO #%02x cmd=%02x addr=%04x len=%04x aux1=%02x aux2=%02x",
				iocb, cmd, addr, len, aux1, aux2);
		if (iocb == 0)
			consoleIO(cmd, addr, len);
		else
		{
			if (iocb & 0x8f)
			{
				emu.setNZ(emu.y = 134);
				return;
			}
			iocb >>>= 4;
			iocb -= 1;
			scope (exit)
			if (ioTrace)
				stderr.writefln("   result=%3d len=%04x",
					emu.y, emu.dpeek(0x358 + iocb * 16));
			switch (cmd)
			{
			case 3:
				if (emu.ram[0x350 + iocb * 16] != 255)
				{
					emu.setNZ(emu.y = 129);
					return;
				}
				char[] name;
				foreach (ch; emu.ram[addr .. $])
				{
					if (ch == 0x9b || !ch)
						break;
					name ~= ch;
				}
				if (ioTrace)
					writefln(`OPEN #%d,%d,%d,"%s"`, iocb + 1, aux1, aux2, name);
				if (name[0] != 'D')
				{
					emu.setNZ(emu.y = 130);
					return;
				}
				string mode;
				switch (aux1)
				{
				case 4: mode = "r"; break;
				case 8: mode = "w"; break;
				case 12: mode = "r+"; break;
				case 9: mode = "emu.a"; break;
				default:
					emu.setNZ(emu.y = 132);
					return;
				}
				if (collectException(iocbs[iocb] = File(
					find(name, ':')[1 .. $].assumeUnique.replace(">", "/"), mode)))
				{
					emu.setNZ(emu.y = 170);
					return;
				}
				emu.ram[0x350 + iocb * 16] = 1;
				break;
			case 7:
				size_t res;
				if (collectException(res = iocbs[iocb].rawRead(
					emu.ram[addr .. addr + len]).length))
				{
					emu.setNZ(emu.y = 144);
					return;
				}
				emu.dpoke(0x358 + iocb * 16, cast(uint) res);
				if (res < len)
				{
					emu.setNZ(emu.y = 136);
					return;
				}
				break;
			case 11:
				if (collectException(iocbs[iocb].rawWrite(
					emu.ram[addr .. addr + len])))
				{
					emu.setNZ(emu.y = 144);
					return;
				}
				break;
			case 12:
				if (ioTrace)
					writefln("CLOSE #%d", iocb + 1);
				iocbs[iocb].close();
				emu.ram[0x350 + iocb * 16] = 255;
				break;
			default:
				emu.setNZ(emu.y = 132);
			}
		}
	}
}

/// Convenience constructor, so the emulator type need not be spelled out.
auto atariHost(E)(E emu)
{
	return new AtariHost!E(emu);
}
