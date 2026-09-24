SWIFTC = swiftc -swift-version 5 -parse-as-library -O -target arm64-apple-macos14.2
# NeMo-Speech.cpp のインストール先(live-transcribe だけが使う)
NEMO ?= $(HOME)/Library/Application Support/NeMoSpeech

all: record-audio play-audio

record-audio: main.swift recorder.swift
	$(SWIFTC) $^ -o $@

play-audio: play.swift
	$(SWIFTC) $< -o $@

live-transcribe: live.swift recorder.swift
	$(SWIFTC) $^ -import-objc-header "$(NEMO)/include/nemo_speech/diar.h" -I "$(NEMO)/include" \
		-L "$(NEMO)/lib" -lnemo_speech_asr_c -Xlinker -rpath -Xlinker "$(NEMO)/lib" -o $@

clean:
	rm -f record-audio play-audio live-transcribe

.PHONY: all clean
