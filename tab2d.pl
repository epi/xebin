#!/usr/bin/perl -w
use strict;
print "class Labels {\n";
for (@ARGV) {
	open INPUT, $_ or die "$_: $!\n";
	s/\..*//g;
	print "\n\tenum ${_} {\n\t\t";
	my $l;
	while ($l = <INPUT>) {
		if ($l =~ /Label table/) { last; }
	}
	$. = 0;
	while ($l = <INPUT>) {
		if ($l =~ /([0-9A-F]{4}) ([0-9A-Z_]*)$/) {
			printf "%s$2 = 0x$1", $. > 1 ? ",\n\t\t" : "";
		}
	}
	print "\n\t}\n";
}
print "\n}\n";
