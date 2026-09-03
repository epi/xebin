/**	CPU versions and features

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
module xebin.cpu;

///
enum Cpu {
	mos_6502,        /// NMOS
	wdc_65c02,       /// original CMOS (also Synertek, GTE, etc.), part of Lynx's Mikey
	rockwell_r65c02, /// Rockwell (bit ops)
	wdc_w65c02s,     /// modern W65C02S (bit ops + WAI/STP)
}

///	Basic CMOS instruction set + BCD and JMP (abs) fixes.
enum bool isCmos(Cpu v) = v != Cpu.mos_6502;

///	RMBn/SMBn/BBRn/BBSn. Rockwell's addition, carried over into the W65C02S.
enum bool hasBitOps(Cpu v) =
	v == Cpu.rockwell_r65c02 || v == Cpu.wdc_w65c02s;

/// WAI and STP, added by the W65C02S; NOPs everywhere else.
enum bool hasWaiStp(Cpu v) = v == Cpu.wdc_w65c02s;
