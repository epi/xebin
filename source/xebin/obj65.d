module xebin.obj65;

import std.file: read;
import std.stdio;
import std.conv;
import std.datetime;
import core.stdc.time;

// cc65 object file

class Obj65Exception : Exception
{
	this(string msg)
	{
		super(msg);
	}
}

private
{

immutable(ubyte[]) subArray(immutable(ubyte[]) data, size_t offs)
{
	if (data.length < offs + 8)
		throw new Obj65Exception("Where are my bytes?");
	auto offset = data[offs .. offs + 4].toUint();
	auto size = data[offs + 4 .. offs + 8].toUint();
	if (data.length < offset + size)
		throw new Obj65Exception("Where are my bytes?");
	return data[offset .. offset + size];
}

uint toUint(immutable(ubyte[]) arr)
{
	if (arr.length < 2)
		throw new Obj65Exception("Where are my bytes?");
	return arr[0] | (arr[1] << 8) | (arr[2] << 16) | (arr[3] << 24);
}

ushort toUshort(immutable(ubyte[]) arr)
{
	if (arr.length < 2)
		throw new Obj65Exception("Where are my bytes?");
	return arr[0] | (arr[1] << 8);
}

ubyte readUbyte(ref immutable(ubyte)[] arr)
{
	if (arr.length < 1)
		throw new Obj65Exception("Where are my bytes?");
	ubyte result = arr[0];
	arr = arr[1 .. $];
	return result;
}

uint readUint(ref immutable(ubyte)[] arr)
{
	uint result = arr.toUint();
	arr = arr[4 .. $];
	return result;
}

uint readVar(ref immutable(ubyte)[] arr)
{
	uint result;
	int shift;
	for (;;)
	{
		ubyte q = arr.readUbyte();
		result |= (q & 0x7F) << shift;
		if (q & 0x80)
			shift += 7;
		else
			return result;
	}		
}

immutable(ubyte)[] readArray(ref immutable(ubyte)[] arr, size_t len)
{
	if (arr.length < len)
		throw new Obj65Exception("Where are my bytes?");
	immutable(ubyte)[] result = arr[0 .. len];
	arr = arr[len .. $];
	return result;
}

string readString(ref immutable(ubyte)[] arr, size_t len)
{
	if (arr.length < len)
		throw new Obj65Exception("Where are my bytes?");
	string result = cast(string) arr[0 .. len];
	arr = arr[len.. $];
	return result;
}

enum Option : ubyte
{
	ArgMask = 0xC0,
	ArgStr = 0x00,
	ArgNum = 0x40,
	Comment = ArgStr + 0,
	Author = ArgStr + 1,
	Translator = ArgStr + 2,
	Compiler = ArgStr + 3,
	Os = ArgStr + 4,
	DateTime = ArgNum + 0
}

enum Flag : ushort
{
	HasDebugInfo = 0x0001
}

enum FragmentTypeMask = 0x38;

enum FragmentByteMask = 0x07;

enum FragmentType : ubyte
{
	Literal = 0x00,
	Expr = 0x08,
	SExpr = 0x10,
	Fill = 0x20
}

} // private

bool isObj65(immutable(ubyte[]) data)
{
	return data[0 .. 4].toUint() == Obj65.magic_ && data[4 .. 6].toUshort() == Obj65.version_;
}

struct LineInfo
{
	uint line;
	uint col;
	uint file;
}

struct SourceFile
{
	string name;
	uint size;
	SysTime mtime;
}

class Expr
{
}

class NullExpr : Expr
{
}

class LeafExpr : Expr
{
}

class LiteralExpr : LeafExpr
{
	this(int value)
	{
		this.value = value;
	}

	override string toString()
	{
		return to!string(value);
	}
	
	int value;
}

// TODO: symbol import id
class SymbolExpr : LeafExpr
{
	this(int value)
	{
		this.value = value;
	}

	override string toString()
	{
		return "SYMBOL(" ~ to!string(value) ~ ")";
	}
	
	int value;
}

// TODO: wtf?
class SectionExpr : LeafExpr
{
	this(ubyte sectionId)
	{
		this.sectionId = sectionId;
	}

	override string toString()
	{
		return "SECTION(" ~ to!string(sectionId) ~ ")";
	}

	ubyte sectionId;
}

class UnaryExpr : Expr
{
	this(ExprUnaryOp op, Expr expr)
	{
		this.op = op;
		this.expr = expr;
	}

	override string toString()
	{
		return "(<" ~ to!string(op) ~ ">" ~ expr.toString() ~ ")";
	}
	
	ExprUnaryOp op;
	Expr expr;
}

class BinaryExpr : Expr
{
	this(ExprBinaryOp op, Expr lhs, Expr rhs)
	{
		this.op = op;
		this.lhs = lhs;
		this.rhs = rhs;
	}

	override string toString()
	{
		return "(" ~ lhs.toString() ~ "<" ~ to!string(op) ~ ">" ~ rhs.toString() ~ ")";
	}

	ExprBinaryOp op;
	Expr lhs;
	Expr rhs;
}

Expr readExpr(ref immutable(ubyte)[] arr)
{
	auto btype = arr.readUbyte();
	if (btype == ExprNullNode)
	{
		return new NullExpr();
	}
	auto type = cast(ExprNodeType) (btype & ExprNodeTypeMask);
	switch (type)
	{
	case ExprNodeType.Unary:
		if (cast(NullExpr) arr.readExpr() !is null)
			throw new Obj65Exception("lhs of unary expression should be null expression");
		return new UnaryExpr(
			cast(ExprUnaryOp) (btype & ExprUnaryOpMask),
			arr.readExpr());
	case ExprNodeType.Binary:
		return new BinaryExpr(
			cast(ExprBinaryOp) (btype & ExprBinaryOpMask),
			arr.readExpr(),
			arr.readExpr());
	case ExprNodeType.Leaf:
		switch (cast(ExprLeafNodeType) (btype & ExprLeafNodeTypeMask))
		{
		case ExprLeafNodeType.Literal:
			return new LiteralExpr(
				arr.readUint());
		case ExprLeafNodeType.Symbol:
			return new SymbolExpr(
				arr.readVar());
		case ExprLeafNodeType.Section:
			return new SectionExpr(
				arr.readUbyte());
		default:
			throw new Obj65Exception("not supported " ~ to!string(btype));
		}
	default:
		throw new Obj65Exception("Invalid exception type " ~ to!string(cast(ubyte) type));
	}
}

class Fragment
{
}

class LiteralFragment : Fragment
{
	this(ubyte[] data)
	{
		this.data = data;
	}

	this(immutable(ubyte)[] data)
	{
		this.data = data.dup;
	}

	ubyte[] data;
}

class ExprFragment : Fragment
{
	this (bool signed, uint bytes, Expr expr)
	{
		if (bytes < 1 || bytes > 4)
			throw new Obj65Exception("Invalid expression width");
		this.signed = signed;
		this.bytes = bytes;
		this.expr = expr;
	}

	override string toString()
	{
		return "ExprFragment{" ~ expr.toString() ~ "}";
	}

	bool signed;
	uint bytes;
	Expr expr;
}

class FillFragment : Fragment
{
	this(uint size)
	{
		this.size = size;
	}

	uint size;
}

struct ImportSymbol
{
	string name;
	uint addrSize;
}

struct ExportSymbol
{
	string name;
	uint flags;
	uint exportSize;
}

struct Segment
{
	string name;
	uint size;
	ubyte alignment;
	ubyte addrSize;
	Fragment[] fragments;
}

class Obj65
{
	this(immutable(ubyte[]) data)
	{
		if (!isObj65(data))
			throw new Obj65Exception("Not a cc65 object file");
		auto flags = cast(Flag) data[6 .. 8].toUshort();
		hasDebugInfo_ = flags & Flag.HasDebugInfo;
		readStrings(subArray(data, 64));
		readOptions(subArray(data, 8));
		readFiles(subArray(data, 16));
		readSegments(subArray(data, 24));
		readImports(subArray(data, 32));
		readExports(subArray(data, 40));
		readDebugSymbols(subArray(data, 48));
		readLineInfos(subArray(data, 56));
		readAsserts(subArray(data, 72));
		readScopes(subArray(data, 80));
		readSpans(subArray(data, 88));
		strings_ = null;
	}

	const @property bool hasDebugInfo()
	{
		return hasDebugInfo_;
	}

private:
	void readStrings(immutable(ubyte)[] data)
	{
		auto nstrings = data.readVar();
		while (nstrings--)
		{
			auto len = data.readVar();
			strings_ ~= data.readString(len);
		}
	}

	void readOptions(immutable(ubyte)[] data)
	{
		auto nopts = data.readVar();
		while (nopts--)
		{
			auto opt = cast(Option) data.readUbyte();
			auto value = data.readVar();
			switch (opt)
			{
			case Option.Comment:
				comment_ = strings_[value];
				break;
			case Option.Author:
				author_ = strings_[value];
				break;
			case Option.Translator:
				translator_ = strings_[value];
				break;
			case Option.Compiler:
				compiler_ = strings_[value];
				break;
			case Option.Os:
				os_ = strings_[value];
				break;
			case Option.DateTime:
				dateTime_ = SysTime(unixTimeToStdTime(cast(time_t) value));
				break;
			default:
				throw new Obj65Exception("Invalid option type");
			}
		}
	}

	void readFiles(immutable(ubyte)[] data)
	{
    	auto nfiles = data.readVar();
		while (nfiles--)
		{
			SourceFile file;
			file.name = strings_[data.readVar()];
			file.mtime = SysTime(unixTimeToStdTime(cast(time_t) data.readUint()));
			file.size = data.readVar();
			files_ ~= file;
		}
		writeln(files_);
	}

	void readSegments(immutable(ubyte)[] data)
	{
		auto nsegments = data.readVar();
		while (nsegments--)
		{
			Segment segment;
			auto size = data.readUint();
			segment.name = strings_[data.readVar()];
			segment.size = data.readVar();
			segment.alignment = data.readUbyte();
			segment.addrSize = data.readUbyte();
			auto nfragments = data.readVar();
			while (nfragments--)
			{
				auto btype = data.readUbyte();
				auto type = cast(FragmentType) (btype & FragmentTypeMask);
				auto nbytes = btype & FragmentByteMask;
				Fragment fragment;
				switch (type)
				{
				case FragmentType.Literal:
					fragment = new LiteralFragment(data.readArray(data.readVar()));
					break;
				case FragmentType.Expr:
					fragment = new ExprFragment(false, nbytes, data.readExpr());
					break;
				case FragmentType.SExpr:
					fragment = new ExprFragment(true, nbytes, data.readExpr());
					break;
				case FragmentType.Fill:
					fragment = new FillFragment(data.readVar());
					break;
				default:
					throw new Obj65Exception("Invalid fragment type " ~ to!string(btype));
				}
				// TODO: line infos
				auto nlineinfos = data.readVar();
				while (nlineinfos--)
				{
					data.readVar();
				}
				segment.fragments ~= fragment;
			}
			segments_ ~= segment;
		}
	}

	void readImports(immutable(ubyte)[] data)
	{
		auto nimports = data.readVar();
		while (nimports--)
		{
			auto addrSize = data.readUbyte();
			auto name = strings_[data.readVar()];
			imports_ ~= ImportSymbol(name, addrSize);
			// TODO: line infos
			auto nlineinfos = data.readVar();
			while (nlineinfos--)
			{
				data.readVar();
			}
			nlineinfos = data.readVar();
			while (nlineinfos--)
			{
				data.readVar();
			}
		}
		writeln(imports_);
	}

	void readExports(immutable(ubyte)[] data)
	{
		auto nexports = data.readVar();
		while (nexports--)
		{
			
		}
		writeln(exports_);
	}

	void readDebugSymbols(immutable(ubyte)[] data)
	{
		if (data != [ cast(ubyte) 0, 0 ])
			throw new Obj65Exception("Debug symbols in cc65 object files not supported");
	}

	void readLineInfos(immutable(ubyte)[] data)
	{
		auto nlineinfos = data.readVar();
		while (nlineinfos--)
		{
			auto line = data.readVar();
			auto col = data.readVar();
			auto file = data.readVar();
			// TODO: line info type
			data.readVar();
			// TODO: spans
			if (data.readVar() != 0)
				throw new Obj65Exception("Spans in cc65 object files not supported");
			lineInfos_ ~= LineInfo(line, col, file);
		}
		writeln(lineInfos_);
	}

	void readAsserts(immutable(ubyte)[] data)
	{
		if (data != [ cast(ubyte) 0 ])
			throw new Obj65Exception("Assertions in cc65 object files not supported");
	}

	void readScopes(immutable(ubyte)[] data)
	{
		writeln("scopes ", data);
		if (data != [ cast(ubyte) 0 ])
			throw new Obj65Exception("Scopes in cc65 object files not supported");
	}

	void readSpans(immutable(ubyte)[] data)
	{
		writeln("spans ", data);
		if (data != [ cast(ubyte) 0 ])
			throw new Obj65Exception("Spans in cc65 object files not supported");
	}

	// flags
	bool hasDebugInfo_;
	
	// options
	string comment_;
	string author_;
	string translator_;
	string compiler_;
	string os_;
	SysTime dateTime_;

	SourceFile[] files_;
	Segment[] segments_;
	ImportSymbol[] imports_;
	ExportSymbol[] exports_;
	LineInfo[] lineInfos_;

	string[] strings_;

	enum magic_ = 0x616E7A55;
	enum version_ = 0x000F;	
}


enum ExprNodeTypeMask = 0xC0;

enum ExprNodeType : ubyte
{
	Binary = 0x00,
	Unary = 0x40,
	Leaf = 0x80
}

enum ExprNullNode = 0x00;

enum ExprLeafNodeTypeMask = 0x3F;

enum ExprLeafNodeType : ubyte
{
	Literal = 1,
	Symbol = 2,
	Section = 3,
	Segment = 4,
	MemArea = 5,
	ULabel = 6
}

enum ExprBinaryOpMask = 0x3F;

enum ExprBinaryOp : ubyte
{
	Plus = 1,
	Minus = 2,
	Mul = 3,
	Div = 4,
	Mod = 5,
	Or = 6,
	Xor = 7,
	And = 8,
	Shl = 9,
	Shr = 10,
	Eq = 11,
	Ne = 12,
	Lt = 13,
	Gt = 14,
	Le = 15,
	Ge = 16,
	BoolAnd = 17,
	BoolOr = 18,
	BoolXor = 19,
	Max = 20,
	Min = 21
}

enum ExprUnaryOpMask = 0x3F;

enum ExprUnaryOp : ubyte
{
	Minus = 1,
	Not = 2,
	Swap = 3,
	BoolNot = 4,
	Byte0 = 8,
	Byte1 = 9,
	Byte2 = 10,
	Byte3 = 11,
	Word0 = 12,
	Word1 = 13
}

version(none) unittest
{
	import std.file : read;
	foreach (fileName; [ "lda.o" ])
	{
		writeln(fileName);
		auto infile = cast(immutable(ubyte[])) read(fileName);
		auto obj65 = new Obj65(infile);
		writefln("%s debug info\n\n", obj65.hasDebugInfo ? "has" : "no");
	}
}
