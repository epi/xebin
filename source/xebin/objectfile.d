/*
Definition of object file and its segments

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
module xebin.objectfile;

import std.range.interfaces : ForwardRange;

import xebin.utils;

interface Segment
{
	bool accept(SegmentVisitor);

	alias Range = ForwardRange!Segment;
}

abstract class NoteSegment : Segment
{
	abstract const(char)[] name() const;
	abstract const(char)[] description() const;

	bool accept(SegmentVisitor sv) {
		return sv.visit(this);
	}
}

abstract class LoadableSegment : Segment
{
	import std.exception : enforce;

	abstract uint addr() const;

	/// The raw data contained in this segment in file.
	/// `data.length` must be smaller or equal to `size`.
	const(ubyte)[] data() const;

	/// Number of bytes occupied by this segment in memory
	uint size() const;

	uint end() const => addr + size - 1;

	bool accept(SegmentVisitor sv) {
		return sv.visit(this);
	}

	bool isRun() const {
		return addr == 0x2E0 && (data.length == 2 || data.length == 4);
	}

	bool isInit() const {
		return (addr == 0x2E2 && data.length == 2) || (addr == 0x2E0 && data.length == 4);
	}

	ushort initAddr() const {
		enforce(isInit, "Not an init block");
		return data[0x2E2 - addr .. 0x2E2 - addr + 2].peekLE!ushort;
	}

	ushort runAddr() const {
		enforce(isRun, "Not a run block");
		return data[0x2E0 - addr .. 0x2E0 - addr + 2].peekLE!ushort;
	}

}

abstract class CompositeSegment : Segment
{
	abstract Segment.Range opSlice();

	bool accept(SegmentVisitor sv) {
		if (!sv.visitEnter(this))
			return false;
		foreach (s; this[]) {
			if (!s.accept(sv))
				break;
		}
		return sv.visitLeave(this);
	}
}

class SegmentArray : CompositeSegment
{
	import std.range : ElementType, isForwardRange, save, inputRangeObject;

	override Segment.Range opSlice() {
		return inputRangeObject(_segments);
	}

	this() {}

	this(R)(R segments)
		if (isForwardRange!R && is(ElementType!R : Segment))
	{
		import std.array : array;
		_segments = segments.save.array;
	}

	SegmentArray opOpAssign(string op : "~", T)(T seg) {
		_segments ~= seg;
		return this;
	}

	size_t length() const { return _segments.length; }

private:
	Segment[] _segments;
}

interface SegmentVisitor
{
	bool visit(NoteSegment);
	bool visit(LoadableSegment);
	bool visitEnter(CompositeSegment);
	bool visitLeave(CompositeSegment);
}

class DefaultSegmentVisitor : SegmentVisitor {
	bool visit(NoteSegment) => true;
	bool visit(LoadableSegment) => true;
	bool visitEnter(CompositeSegment) => true;
	bool visitLeave(CompositeSegment) => true;
}

interface ObjectFile
{
	/// Short, human-readable description
	string type() const;

	/// Iterate over segments in the file
	CompositeSegment top();

	/// Parse array of bytes as contents of an object file
	static ObjectFile read(string filename, const(ubyte)[] bytes) {
		foreach (r; _readers) {
			ObjectFile of = r(bytes);
			if (of)
				return of;
		}
		throw new Exception("Unrecognized file format");
	}

	alias ReadFn = ObjectFile function(const(ubyte)[] bytes);

	static void register(ReadFn tryRead) {
		_readers ~= tryRead;
	}

private:
	static ReadFn[] _readers;
}
