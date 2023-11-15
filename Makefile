all: main

CFLAGS=-O2
SWIFTFLAGS=-O

main: main.swift simd.swift data-generator/data.swift render/render.swift
	swiftc $(SWIFTFLAGS) main.swift simd.swift data-generator/data.swift render/render.swift -o main

main-cpp: main.swift simd.swift render-cpp/render.dylib bridging-header.h
	swiftc $(SWIFTFLAGS) -DCPP main.swift simd.swift -import-objc-header bridging-header.h -I render-cpp -o main-cpp

data-generator/data.swift data-generator/data.hpp: data-generator/data-generator
	data-generator/data-generator

data-generator/data-generator: data-generator/main.swift simd.swift
	swiftc $(SWIFTFLAGS) data-generator/main.swift simd.swift -o data-generator/data-generator

render-cpp/render.dylib: render-cpp/render.cpp render-cpp/render.hpp data-generator/data.hpp
	clang $(CFLAGS) render-cpp/render.cpp -dynamiclib -std=c++11 -o render-cpp/render.dylib

clean:
	rm -f main main-cpp data-generator/data-generator data-generator/data.swift data-generator/data.hpp render-cpp/render.dylib
