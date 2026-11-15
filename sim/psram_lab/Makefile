ROOT  := ../..
SRCS  := $(ROOT)/lab/psram_lab/psram_lab_top.v $(ROOT)/rtl/psram/psram_ll.v \
         $(ROOT)/rtl/common/uart_tx.v $(ROOT)/rtl/common/pll_main.v
VFLAGS := --cc --exe --build -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-PINCONNECTEMPTY -Wno-UNUSEDPARAM -Wno-SYNCASYNCNET \
          --top-module psram_lab_top -O2 \
          -GFILL_LOG2=10 -GNREADS_LOG2=9 -GCLKS_PER_BIT=8

.PHONY: run clean
run: obj_dir/Vpsram_lab_top
	./obj_dir/Vpsram_lab_top 10 > lab_uart.txt
	python3 -I $(ROOT)/tools/psram_lab_read.py --file lab_uart.txt --freq 81000000 --check-sim

obj_dir/Vpsram_lab_top: $(SRCS) tb.cpp
	verilator $(VFLAGS) $(SRCS) tb.cpp

clean:
	rm -rf obj_dir lab_uart.txt
