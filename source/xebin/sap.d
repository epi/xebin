/*
SAP (Slight Atari Player) files

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
module xebin.sap;

import xebin.objectfile;
import xebin.ataridos;

class SapTag : NoteSegment
{
	override const(char)[] name() const {
		return _name;
	}

	override const(char)[] description() const {
		return _value;
	}

private:
	string _name;
	string _value;
}

class SapHeader : SegmentArray
{
}

class SapFile : ObjectFile
{
	string type() const => "SAP (Slight Atari Player)";

	CompositeSegment top() {
		return _top;
	}

	static this() {
		register(&tryRead);
	}

private:
	static ObjectFile tryRead(const(ubyte)[] bytes) {
		auto sap = new SapFile;
		sap._top = new SegmentArray;
		auto header = new SapHeader;
		import std.algorithm : startsWith, countUntil;
		import std.string : representation;
		if (!bytes.startsWith("SAP\r\n".representation))
			return null;
		bytes = bytes[5 .. $];
		ptrdiff_t i;
		while ((i = bytes.countUntil("\r\n".representation)) >= 0
			&& !bytes.startsWith([0xff, 0xff]))
		{
			auto line = cast(const(char)[]) bytes[0 .. i];
			auto tag = new SapTag();
			auto j = line.countUntil(' ');
			if (j == 0)
				return null;
			if (j < 0) {
				tag._name = line.idup;
			} else {
				tag._name = line[0 .. j].idup;
				tag._value = line[j + 1 .. $].idup;
			}
			header ~= tag;
			bytes = bytes[i + 2 .. $];
		}

		sap._top ~= header;
		sap._top ~= AtariDOSExecutable.readSegments(bytes);
		if (sap._top.length < 2)
			return null;
		return sap;
	}

	SegmentArray _top;
}
