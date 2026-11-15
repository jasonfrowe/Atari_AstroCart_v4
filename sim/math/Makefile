# The math unit alone: reference-model self-test, then the RTL against the model.
.PHONY: run clean
run: obj_dir/Vastromath selftest
	./selftest
	./obj_dir/Vastromath 64
	./obj_dir/Vastromath 110

selftest: selftest.cpp astromath.h
	$(CXX) -std=c++11 -O2 -Wall -o $@ selftest.cpp

obj_dir/Vastromath: ../../rtl/math/astromath.v tb.cpp astromath.h
	verilator --cc --exe --build -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -O2 --top-module astromath -CFLAGS -I$(CURDIR) ../../rtl/math/astromath.v tb.cpp

clean:
	rm -rf obj_dir selftest
