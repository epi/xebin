VERSION = 1.1.0
SOURCES = $(addprefix source/xebin/,flashpack.d binary.d disasm.d vm.d xasm.d) \
	source/app.d
ASCIIDOC = asciidoc -o $@ -a doctime
ASCIIDOC_POSTPROCESS =
ZIP = 7z a -mx=9 -tzip $@
RM = rm -f
PREFIX = /usr/local

all:
	dub build -b release

doc: xebin.html

dist: windist srcdist

windist: xebin-$(VERSION)-windows.zip

srcdist: xebin-$(VERSION)-src.zip

debug:
	dub build

xebin.html: README.asciidoc
	$(ASCIIDOC) $<
	$(ASCIIDOC_POSTPROCESS)
#	$(ASCIIDOC_VALIDATE)

xebin-$(VERSION)-windows.zip: xebin.exe xebin.html
	$(RM) $@
	$(ZIP) $^

xebin-$(VERSION)-src.zip: xebin-$(VERSION)
	$(RM) $@
	$(ZIP) $<

xebin-$(VERSION): $(SOURCES) README.asciidoc
	$(RM) -r $@
	( mkdir xebin-$(VERSION) && cp $^ Makefile xebin-$(VERSION) )

clean:
	$(RM) xebin xebin.exe xebin.o $(SOURCES:.d=.obj) $(SOURCES:.d=.map)
	$(RM) xebin.html xebin-$(VERSION)-windows.zip xebin-$(VERSION)-src.zip
	$(RM) -r xebin-$(VERSION)
	$(RM) xebin-test-library

install:
	mkdir -p $(PREFIX)/bin && cp xebin $(PREFIX)/bin/

test:
	dub test

.PHONY: all doc debug dist windist srcdist clean install test

.DELETE_ON_ERROR:
