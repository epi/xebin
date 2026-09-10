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

singlestep:
	dub run -b release :singlestep -- -c 6502 -u
	dub run -b release :singlestep -- -c 6502 -o 83,87,8f,97,a3,a7,af,b3,b7,bf,1a,3a,5a,7a,da,fa,80,82,89,c2,e2,04,44,64,14,34,54,74,d4,f4,0c,1c,3c,5c,7c,dc,fc,02,12,22,32,42,52,62,72,92,b2,d2,f2,03,07,0f,13,17,1b,1f,23,27,2f,33,37,3b,3f,43,47,4f,53,57,5b,5f,63,67,6f,73,77,7b,7f,c3,c7,cf,d3,d7,db,df,e3,e7,ef,f3,f7,fb,ff,0b,2b,4b,6b,cb,eb
	dub run -b release :singlestep -- -c synertek65c02,rockwell65c02,wdc65c02


.PHONY: all doc debug dist windist srcdist clean install test

.DELETE_ON_ERROR:
