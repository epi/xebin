DC = dmd -O -release -inline -of$@
PERL = perl
RM = rm -f
XASM = xasm $< -o $@
XASM_TAB = $(XASM) -t $(subst .obx,.tab,$@)
OBX = fp21depk.obx fp21depk_noint.obx
TABLES = fp21depk.tab fp21depk_noint.tab
AUTO_D = fp21depktab.d
SOURCES = flashpack.d binary.d xebin.d

all: xebin.exe

debug:
	$(MAKE) DC="dmd -unittest -debug -of$$@"

xebin.exe: $(SOURCES) $(AUTO_D) $(OBX)
	$(DC) $(SOURCES) $(AUTO_D) -J.

fp21depktab.d: tab2d.pl $(TABLES:.tab=.obx)
	perl tab2d.pl $(TABLES) >$@

fp21depk.obx fp21depk.tab: fp21depk.asx
	$(XASM_TAB) -d NO_INT=0

fp21depk_noint.obx fp21depk_noint.tab: fp21depk.asx
	$(XASM_TAB) -d NO_INT=1

clean:
	$(RM) xebin.exe $(SOURCES:.d=.obj) $(SOURCES:.d=.map) $(OBX) $(TABLES) $(AUTO_D) $(AUTO_D:.d=.obj) $(AUTO_D:.d=.map)
