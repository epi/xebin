/*
Number conversion helpers

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
module xebin.utils;

import std.traits : isIntegral;

T peekLE(T)(const(ubyte)[] arr)
{
	import std.bitmanip : peek;
	import std.system : Endian;
	return arr.peek!(T, Endian.littleEndian);
}

T parse(T)(const(char)[] str)
{
	import std.conv : to;
	import std.string : startsWith;
	if (str.startsWith('-'))
		return -parse!T(str[1 .. $]);
	if (str.startsWith('$'))
		return str[1 .. $].to!T(16);
	if (str.startsWith("0x") || str.startsWith("0X"))
		return str[2 .. $].to!T(16);
	return str.to!T;
}

unittest {
	assert("-10".parse!int == -10);
	assert("-$10".parse!int == -16);
	assert("0x42".parse!int == 0x42);
	assert("-0xdeadbeef".parse!long == -0xdeadbeefL);
}