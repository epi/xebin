VERSION = $(shell git describe --tags)
SOURCES = $(wildcard source/xebin/*.d source/*.d)
ASCIIDOC = asciidoc -o $@ -a doctime
ASCIIDOC_POSTPROCESS =
ZIP = 7z a -mx=9 -tzip $@
RM = rm -f
PREFIX = /usr/local

all:
	dub build -b release

doc: xebin.html

windist: xebin-$(VERSION)-windows.zip

debug:
	dub build

xebin.html: README.asciidoc
	$(ASCIIDOC) $<
	$(ASCIIDOC_POSTPROCESS)
#	$(ASCIIDOC_VALIDATE)

xebin-$(VERSION)-windows.zip: xebin.exe xebin.html
	$(RM) $@
	$(ZIP) $^

clean:
	$(RM) xebin xebin.exe xebin.o $(SOURCES:.d=.obj) $(SOURCES:.d=.map)
	$(RM) xebin.html xebin-$(VERSION)-windows.zip
	$(RM) xebin-test-library version.txt
	dub clean

install:
	mkdir -p $(PREFIX)/bin && cp xebin $(PREFIX)/bin/

test:
	dub test

.PHONY: all doc debug dist windist srcdist clean install test

.DELETE_ON_ERROR:
