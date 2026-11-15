ROOT  := ../..
SRCS  := $(ROOT)/rtl/audio/pokey.v
VFLAGS := --cc --exe --build -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-BLKSEQ --top-module pokey -O2

.PHONY: run clean
run: obj_dir/Vpokey
	./obj_dir/Vpokey

obj_dir/Vpokey: $(SRCS) tb.cpp
	verilator $(VFLAGS) $(SRCS) tb.cpp

clean:
	rm -rf obj_dir
