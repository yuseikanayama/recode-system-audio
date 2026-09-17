SWIFTC = swiftc -swift-version 5 -parse-as-library -O -target arm64-apple-macos14.2

all: record-audio play-audio

record-audio: main.swift
	$(SWIFTC) $< -o $@

play-audio: play.swift
	$(SWIFTC) $< -o $@

clean:
	rm -f record-audio play-audio

.PHONY: all clean
