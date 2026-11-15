ROOT  := ../..
SRCS  := $(ROOT)/rtl/dev/devcart_top.v $(ROOT)/rtl/cart/cart_bus.v \
         $(ROOT)/rtl/psram/psram_dual.v $(ROOT)/rtl/psram/psram_ll.v \
         $(ROOT)/rtl/common/uart_tx.v $(ROOT)/rtl/common/uart_rx.v $(ROOT)/rtl/common/pll_main.v \
         $(ROOT)/rtl/audio/pokey.v $(ROOT)/rtl/audio/audio_pwm.v $(ROOT)/rtl/sd/sd_spi.v \
         $(ROOT)/rtl/math/astromath.v
VFLAGS := --cc --exe --build -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-PINCONNECTEMPTY \
          -Wno-UNUSEDPARAM -Wno-SYNCASYNCNET -Wno-BLKSEQ --pins-inout-enables \
          --top-module devcart_top -O2 -GBAUD_DIV=8 -GMENU=0

.PHONY: run clean
run: obj_dir/Vdevcart_top
	./obj_dir/Vdevcart_top

obj_dir/Vdevcart_top: $(SRCS) tb.cpp
	verilator $(VFLAGS) $(SRCS) tb.cpp

clean:
	rm -rf obj_dir
