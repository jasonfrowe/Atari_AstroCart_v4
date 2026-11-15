ROOT  := ../..
# dasm comes with 7800basic (bas7800dir, as for the other build scripts)
bas7800dir ?= $(HOME)/Software/Atari7800/7800basic
DASM  ?= $(bas7800dir)/dasm
SRCS  := $(ROOT)/rtl/dev/devcart_top.v $(ROOT)/rtl/cart/cart_bus.v \
         $(ROOT)/rtl/psram/psram_dual.v $(ROOT)/rtl/psram/psram_ll.v \
         $(ROOT)/rtl/common/uart_tx.v $(ROOT)/rtl/common/uart_rx.v $(ROOT)/rtl/common/pll_main.v \
         $(ROOT)/rtl/audio/pokey.v $(ROOT)/rtl/audio/audio_pwm.v $(ROOT)/rtl/sd/sd_spi.v \
         $(ROOT)/rtl/math/astromath.v
VFLAGS := --cc --exe --build -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-PINCONNECTEMPTY \
          -Wno-UNUSEDPARAM -Wno-SYNCASYNCNET -Wno-BLKSEQ --pins-inout-enables \
          --top-module devcart_top -O2 -GBAUD_DIV=8 -GMENU=1 '-GMENU_HEX="harness"' \
          -GSD_SLOW_HALF=6 -GSD_BOOT_CLKS=500 -GHSC_IDLE=150000

.PHONY: run clean
run: obj_dir/Vdevcart_top obj_menu/Vdevcart_top
	./run.sh

harness.bin: harness.asm $(ROOT)/menu/fat.asm
	$(DASM) harness.asm -I$(ROOT)/menu -f3 -oharness.bin -lharness.lst -sharness.sym
	python3 $(ROOT)/tools/rom2hex.py harness.bin harness

fake6502.o: $(ROOT)/sim/third_party/fake6502/fake6502.c
	$(CC) -O2 -w -c -o $@ $<

obj_dir/Vdevcart_top: $(SRCS) tb.cpp harness.bin fake6502.o
	verilator $(VFLAGS) $(SRCS) tb.cpp $(CURDIR)/fake6502.o

# the same testbench with the real 7800basic menu ROM in the slots (REALMENU=1 at run time)
MENU_BIN := $(ROOT)/menu/build/menu.bin
obj_menu/Vdevcart_top: $(SRCS) tb.cpp $(MENU_BIN) fake6502.o
	python3 $(ROOT)/tools/rom2hex.py $(MENU_BIN) menu
	verilator $(subst "harness","menu",$(VFLAGS)) --Mdir obj_menu $(SRCS) tb.cpp $(CURDIR)/fake6502.o

clean:
	rm -rf obj_dir obj_menu harness.bin harness.lst harness.sym harness_*.hex fake6502.o *.img
