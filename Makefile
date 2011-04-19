VERSION = 1.0.1
SOURCES = flashpack.d binary.d disasm.d xasm.d xebin.d
DMD = dmd -O -release -inline -of$@
ASCIIDOC = asciidoc -o $@ -a doctime
ASCIIDOC_POSTPROCESS = perl -pi.bak -e "END{unlink '$@.bak'}" $@
ASCIIDOC_VALIDATE = xmllint --valid --noout --nonet $@
ZIP = 7z a -mx=9 -tzip $@
RM = rm -f

ifdef ComSpec
EXESUFFIX = .exe
else
ifdef COMSPEC
EXESUFFIX = .exe
endif
endif 

XEBIN_EXE=xebin$(EXESUFFIX)

all: $(XEBIN_EXE)

doc: xebin.html

windist: xebin-$(VERSION)-windows.zip

srcdist: xebin-$(VERSION)-src.zip

debug:
	$(MAKE) DMD="dmd -unittest -debug -w -wi -of$(XEBIN_EXE)" clean all

$(XEBIN_EXE): $(SOURCES)
	$(DMD) $(SOURCES)

xebin.html: README.asciidoc
	$(ASCIIDOC) $<
	$(ASCIIDOC_POSTPROCESS)
	$(ASCIIDOC_VALIDATE)

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
	$(RM) $(XEBIN_EXE) xebin.o $(SOURCES:.d=.obj) $(SOURCES:.d=.map)
	$(RM) xebin.html xebin-$(VERSION)-windows.zip xebin-$(VERSION)-src.zip
	$(RM) -r xebin-$(VERSION)

.PHONY: all doc debug windist srcdist clean Makefile
	
.DELETE_ON_ERROR:
