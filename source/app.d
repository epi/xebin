/*
xebin command line interface

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
import std.stdio;

import xebin.objectfile;

import std.string : strip;
immutable VERSION_STRING = import("version.txt").strip;

auto inputFiles(string[] args) {
	import std.algorithm : map;
	import std.array : join;
	return (args.length == 0 ? [""] : args)
		.map!((string fn) {
			File file = fn.length == 0 ? stdin : File(fn);
			if (args.length > 1)
				writefln("\n%s:", file.name);
			return ObjectFile.read(file.name, file.byChunk(65536).join);
		});
}

void list(string[] args) {
	foreach (file; inputFiles(args[2 .. $])) {
		file.top.accept(new class DefaultSegmentVisitor {
			override bool visit(NoteSegment note) {
				writefln("%s %s", note.name, note.description);
				return true;
			}

			override bool visit(LoadableSegment loadable) {
				writefln("%04x-%04x (%04x)",
					loadable.addr,
					loadable.addr + loadable.size - 1,
					loadable.data.length);
				return true;
			}
		});
	}
}

void disassemble(string[] args)
{
	import xebin.disasm : Disassembler;

	foreach (objf; inputFiles(args[2 .. $])) {
		foreach (line; Disassembler(objf.top)) {
			writeln(line);
		}
	}

}

void printHelp(string[] args)
{
	write(
		"Atari XL/XE binary file utility " ~ VERSION_STRING ~ "\n" ~
		"\nUsage:\n" ~
		args[0] ~ " command [options] [input_file ...]\n" ~
		"\nThe following commands are available:\n" ~
		" l[ist]                                list blocks inside file\n" ~
		" d[isasm]                              disassemble blocks\n" ~
		" h[elp]                                print this message\n" ~
		"\nIf input file is not specified, stdin is used as input.\n"
		);
}

int main(string[] args)
{
	import std.string : startsWith;
	version(unittest) { return 0; }
	else {
		try {
			if (args.length >= 2) {
				auto funcs = [
					"help":&printHelp,
					"list":&list,
					"disasm":&disassemble,
					];
				foreach (cmd, fun; funcs) {
					if (cmd.startsWith(args[1])) {
						fun(args);
						return 0;
					}
				}
			}
		} catch (Exception e) {
			debug writeln("Error: ", e);
			else writeln("Error: ", e.msg);
			return 1;
		}
		printHelp(args);
		return 1;
	}
}
