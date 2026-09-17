record-audio: main.swift
	swiftc -swift-version 5 -parse-as-library -O -target arm64-apple-macos14.0 main.swift -o $@

clean:
	rm -f record-audio

.PHONY: clean
