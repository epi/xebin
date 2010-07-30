DC = dmd -O -release -inline -of$@
PERL = perl
RM = rm -f
XASM = xasm $< -o $@
XASM_TAB = $(XASM) -t $(subst .obx,.tab,$@)
OBX = fp21depk.obx fp21depk_noint.obx
TABLES = fp21depk.tab fp21depk_noint.tab
AUTO_D = fp21depktab.d
SOURCES = flashpack.d binary.d xebin.d

OS := $(shell uname -s)
ifneq (,$(findstring windows,$(OS)))
EXESUFFIX=.exe
else
ifneq (,$(findstring Cygwin,$(OS)))
EXESUFFIX=.exe
endif
endif
XEBIN_EXE=xebin$(EXESUFFIX)

all: $(XEBIN_EXE)

debug:
	$(MAKE) DC="dmd -unittest -debug -of$(XEBIN_EXE)"

$(XEBIN_EXE): $(SOURCES) $(AUTO_D) $(OBX)
	$(DC) $(SOURCES) $(AUTO_D) -J.

fp21depktab.d: tab2d.pl $(TABLES:.tab=.obx)
	perl tab2d.pl $(TABLES) >$@

fp21depk.obx fp21depk.tab: fp21depk.asx
	$(XASM_TAB) -d NO_INT=0

fp21depk_noint.obx fp21depk_noint.tab: fp21depk.asx
	$(XASM_TAB) -d NO_INT=1

clean:
	$(RM) $(XEBIN_EXE) xebin.o $(SOURCES:.d=.obj) $(SOURCES:.d=.map) $(OBX) $(TABLES) $(AUTO_D) $(AUTO_D:.d=.obj) $(AUTO_D:.d=.map)

