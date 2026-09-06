/** Runs SingleStepTests/65x02 against xebin CPU emulation.

	---
	git clone https://github.com/SingleStepTests/65x02 ext/65x02
	dub run :singlestep
	---

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

import std.file : exists;
import std.getopt;
import std.path : buildPath;
import std.stdio;

string findSuite(string dir)
{
	if (dir.length)
		return dir;
	foreach (candidate; ["ext/65x02", "../65x02", "65x02"])
		if (exists(buildPath(candidate, "6502", "v1")))
			return candidate;
	return null;
}

int main(string[] args)
{
	string dir;
	auto help = getopt(args,
		"d|dir", "root of SingleStepTests/65x02", &dir);

	if (help.helpWanted)
	{
		defaultGetoptPrinter(
			"Runs SingleStepTests/65x02 against xebin CPU emulator.\n", help.options);
		return 0;
	}

	const root = findSuite(dir);
	if (root is null)
	{
		stderr.writeln("no 65x02 test data found -- clone " ~
			"https://github.com/SingleStepTests/65x02 and pass --dir=<path>");
		return 2;
	}

	return 0;
}
