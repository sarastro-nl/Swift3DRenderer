all: main

CFLAGS=-O2
SWIFTFLAGS=-O

main: main.swift input.swift render/render.swift data-generator/data.bin
	swiftc $(SWIFTFLAGS) main.swift input.swift render/render.swift -o main

main-cpp: main.swift input.swift render-cpp/render.dylib bridging-header.h
	swiftc $(SWIFTFLAGS) -DCPP main.swift input.swift -import-objc-header bridging-header.h -I render-cpp -o main-cpp

data-generator/data.bin: data-generator/data-generator
	data-generator/data-generator

data-generator/data-generator: data-generator/main.swift
	swiftc $(SWIFTFLAGS) data-generator/main.swift -o data-generator/data-generator

render-cpp/render.dylib: render-cpp/render.cpp render-cpp/render.hpp data-generator/data.bin
	clang++ $(CFLAGS) render-cpp/render.cpp -dynamiclib -std=c++11 -o render-cpp/render.dylib

clean:
	rm -rf main main-cpp data-generator/data-generator data-generator/data.bin render-cpp/render.dylib
