/*
Atari DOS binary files

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
module xebin.ataridos;

import xebin.utils;
import xebin.objectfile;

class AtariDOSSegment : LoadableSegment
{
	/// Short, human-readable description
	string type() const => "Atari DOS";

	/// Load address
	override uint addr() const => _start;

	/// Size
	override uint size() const => _end - _start + 1;

	/// The data contained in this segment
	override const(ubyte)[] data() const => _data;

private:
	ushort _start;
	ushort _end;
	const(ubyte)[] _data;

	this(ushort start, ushort end, const(ubyte)[] data) {
		_start = start;
		_end = end;
		_data = data;
	}
}

class AtariDOSExecutable : ObjectFile
{
	import std.range : inputRangeObject, popFrontN;
	import std.algorithm : min, map;
	import std.stdio : stderr;

	string type() const => "Atari DOS Executable";

	CompositeSegment top() {
		return _top;
	}

	static this() {
		register(&tryRead);
	}

	static Segment[] readSegments(const(ubyte)[] bytes) {
		Segment[] segments;
		if (bytes.peekLE!ushort != 0xffff)
			return null;
		bytes.popFrontN(ushort.sizeof);
		while (bytes.length > 4) {
			const start = bytes.peekLE!ushort;
			const end = bytes[2 .. $].peekLE!ushort;
			if (start > end)
				return null;
			const len = min(bytes.length - 4, end - start + 1);
			segments ~= new AtariDOSSegment(start, end, bytes[4 .. 4 + len]);
			bytes.popFrontN(4 + len);
			if (bytes.length >= 2 && bytes.peekLE!ushort == 0xffff)
				bytes.popFrontN(ushort.sizeof);
		}
		return segments;
	}

private:
	static ObjectFile tryRead(const(ubyte)[] bytes) {
		Segment[] segments = readSegments(bytes);
		return segments.length == 0
			? null
			: new AtariDOSExecutable(new SegmentArray(segments));
	}

	SegmentArray _top;

	this(SegmentArray top) {
		this._top = top;
	}
}
