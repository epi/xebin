VERSION = 1.0.0
OBX = fp21depk.obx fp21depk_noint.obx
TABLES = fp21depk.tab fp21depk_noint.tab
AUTO_D = fp21depktab.d
SOURCES = flashpack.d binary.d xebin.d

DC = dmd -O -release -inline -of$@
PERL = perl
XASM = xasm $< -o $@
XASM_TAB = $(XASM) -t $(subst .obx,.tab,$@)
ASCIIDOC = asciidoc -o $@ -a doctime
ASCIIDOC_POSTPROCESS = perl -pi.bak -e "s/527bbd;/20a0a0;/;END{unlink '$@.bak'}" $@
ASCIIDOC_VALIDATE = xmllint --valid --noout --nonet $@
ZIP = 7z a -mx=9 -tzip $@
RM = rm -f

OS := $(shell uname -s)
ifneq (,$(findstring windows,$(OS)))
EXESUFFIX=.exe
endif
ifneq (,$(findstring Cygwin,$(OS)))
EXESUFFIX=.exe
endif
ifneq (,$(findstring MINGW,$(OS)))
EXESUFFIX=.exe
endif
XEBIN_EXE=xebin$(EXESUFFIX)

all: $(XEBIN_EXE) xebin.html

windist: xebin-$(VERSION)-windows.zip

srcdist: xebin-$(VERSION)-src.zip

debug:
	$(MAKE) DC="dmd -unittest -debug -w -wi -of$(XEBIN_EXE)"

$(XEBIN_EXE): $(SOURCES) $(AUTO_D) $(OBX)
	$(DC) $(SOURCES) $(AUTO_D) -J.

fp21depktab.d: tab2d.pl $(TABLES:.tab=.obx)
	perl tab2d.pl $(TABLES) >$@

fp21depk.obx fp21depk.tab: fp21depk.asx
	$(XASM_TAB) -d NO_INT=0

fp21depk_noint.obx fp21depk_noint.tab: fp21depk.asx
	$(XASM_TAB) -d NO_INT=1

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

xebin-$(VERSION): $(SOURCES) tab2d.pl fp21depk.asx README.asciidoc makefile
	$(RM) -r $@
	( mkdir xebin-$(VERSION) && cp $^ xebin-$(VERSION)/ )

clean:
	$(RM) $(XEBIN_EXE) xebin.o $(SOURCES:.d=.obj) $(SOURCES:.d=.map) $(OBX) $(TABLES) $(AUTO_D) $(AUTO_D:.d=.obj) $(AUTO_D:.d=.map)
	$(RM) xebin.html xebin-$(VERSION)-windows.zip xebin-$(VERSION)-src.zip
	$(RM) -r xebin-$(VERSION)
	
.DELETE_ON_ERROR:
