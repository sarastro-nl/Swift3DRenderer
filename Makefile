all: main

CFLAGS=-O2
SWIFTFLAGS=-O

main: main.swift input.swift data-generator/data.swift render/render.swift
	swiftc $(SWIFTFLAGS) main.swift input.swift data-generator/data.swift render/render.swift -o main

main-cpp: main.swift input.swift Frameworks/render_dylib.framework/render_dylib bridging-header.h
	swiftc $(SWIFTFLAGS) -DCPP main.swift input.swift -import-objc-header bridging-header.h -I render-cpp -o main-cpp

data-generator/data.swift data-generator/data.hpp: data-generator/data-generator
	data-generator/data-generator

data-generator/data-generator: data-generator/main.swift
	swiftc $(SWIFTFLAGS) data-generator/main.swift -o data-generator/data-generator

Frameworks/render_dylib.framework/render_dylib: render-cpp/render.cpp render-cpp/render.hpp data-generator/data.hpp
	mkdir -p Frameworks/render_dylib.framework
	clang $(CFLAGS) render-cpp/render.cpp -dynamiclib -std=c++11 -o Frameworks/render_dylib.framework/render_dylib

clean:
	rm -rf main main-cpp data-generator/data-generator data-generator/data.swift data-generator/data.hpp Frameworks
