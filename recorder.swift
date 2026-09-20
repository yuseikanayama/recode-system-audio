// システム音声とマイクを別々の .m4a に録音する部分。
// Core Audio のプロセスタップ(macOS 14.2+)で全プロセスの出力音声を捕まえるので、
// ウィンドウを持たないデーモン(callservicesd / avconferenced)の音も対象になります。
// マイクは同じ集約デバイスに入れて取り込むので、2 つのファイルはサンプル単位で揃います。

import Accelerate
import AVFoundation
import CoreAudio

func check(_ status: OSStatus, _ what: String) throws {
    guard status == noErr else {
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                      userInfo: [NSLocalizedDescriptionKey: "\(what)に失敗しました (OSStatus \(status))"])
    }
}

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

// AudioObject のグローバルプロパティを 1 つ読む。value には型を決めるための初期値を渡す。
func readProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: T) throws -> T {
    var address = address(selector)
    var value = value
    var size = UInt32(MemoryLayout<T>.size)
    try withUnsafeMutablePointer(to: &value) {
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0), "プロパティ取得")
    }
    return value
}

func deviceUID(_ device: AudioObjectID) throws -> String {
    try readProperty(device, kAudioDevicePropertyDeviceUID, "" as CFString) as String
}

// 1 本の出力ファイル(システム音声かマイク)と、その音量計測。
final class Track {
    let name: String
    let url: URL
    private var file: AVAudioFile?
    private var format: AVAudioFormat?
    private var peak: Float = 0      // 直近の表示区間のピーク
    private var maxPeak: Float = 0   // 録音全体のピーク

    init(name: String, url: URL) { self.name = name; self.url = url }

    // 最初のバッファでチャンネル数が分かるので、そのときにファイルを開く。
    func write(_ buffer: AudioBuffer, sampleRate: Double) {
        do {
            if file == nil {
                format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                       channels: buffer.mNumberChannels, interleaved: true)
                file = try AVAudioFile(forWriting: url, settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: buffer.mNumberChannels,
                ], commonFormat: .pcmFormatFloat32, interleaved: true)
            }
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: buffer)
            try withUnsafePointer(to: &list) { list in
                guard let format, let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list) else { return }
                try file?.write(from: pcm)
            }
        } catch {
            fputs("\(name)の書き込みエラー: \(error.localizedDescription)\n", stderr)
        }
        var m: Float = 0
        vDSP_maxmgv(buffer.mData!.assumingMemoryBound(to: Float.self), 1, &m, vDSP_Length(buffer.mDataByteSize / 4))
        peak = max(peak, m)
    }

    // 表示区間のピークを文字列にして、次の区間へ進む。
    func report() -> String {
        defer { maxPeak = max(maxPeak, peak); peak = 0 }
        return peak > 0 ? String(format: "%6.1f dB", 20 * log10(peak)) : "  無音  "
    }

    // file を解放するとヘッダが書かれて保存が完了する。
    func close() {
        file = nil
        if max(maxPeak, peak) == 0 {
            fputs("\n警告: \(name)は全て無音でした。許可設定を確認してください。\n", stderr)
        }
    }
}

final class Recorder {
    let queue = DispatchQueue(label: "record-audio.writer")
    private let system: Track
    private let mic: Track
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var sampleRate: Double = 0
    private var lastReport = Date()
    private(set) var micName = ""

    init(dir: URL, name: String) {
        system = Track(name: "システム音声", url: dir.appendingPathComponent("\(name)-system.m4a"))
        mic = Track(name: "マイク", url: dir.appendingPathComponent("\(name)-mic.m4a"))
    }

    var paths: String { "\(system.url.path)\n\(mic.url.path)" }

    func start() throws {
        // 全プロセスの出力をステレオにミックスするタップ(初回はシステムオーディオ録音の許可ダイアログが出る)
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "record-audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tap), "プロセスタップの作成")

        // タップと既定のマイクを 1 つの非公開の集約デバイスにまとめる。
        // クロック源はマイク自身にする(AirPods は通話モードで 24 kHz になり、他のレートでは正しく届かない)。
        // タップの音声は Core Audio がこのレートに合わせてくれる。入力バッファはマイク、タップの順に並ぶ。
        let micDevice = try readProperty(AudioObjectID(kAudioObjectSystemObject),
                                         kAudioHardwarePropertyDefaultInputDevice, AudioObjectID(kAudioObjectUnknown))
        let micUID = try deviceUID(micDevice)
        micName = try readProperty(micDevice, kAudioObjectPropertyName, "" as CFString) as String
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "record-audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: micUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: micUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString,
                                               kAudioSubTapDriftCompensationKey: true]],
        ]
        try check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate), "集約デバイスの作成")

        // 開始直後にレートが変わることがある(AirPods の通話モード切替)ので、ファイルは最初のバッファで開く。
        // 録音中に変わった場合はファイルのレートと合わなくなるので警告する。
        var rateAddress = address(kAudioDevicePropertyNominalSampleRate)
        AudioObjectAddPropertyListenerBlock(aggregate, &rateAddress, queue) { [unowned self] _, _ in
            guard sampleRate != 0 else { return }
            fputs("\n警告: 録音中にサンプルレートが変わりました。録音をやり直してください。\n", stderr)
        }

        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, queue) { [unowned self] _, input, _, _, _ in
            self.write(input)
        }, "IOProc の作成")
        try check(AudioDeviceStart(aggregate, procID), "録音の開始")
    }

    // 音声バッファが届くたびに呼ばれる(queue 上)。
    private func write(_ input: UnsafePointer<AudioBufferList>) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard list.count >= 2 else { return }
        if sampleRate == 0 {
            sampleRate = (try? readProperty(aggregate, kAudioDevicePropertyNominalSampleRate, Double(0))) ?? 0
            guard sampleRate != 0 else { return }
        }
        mic.write(list[0], sampleRate: sampleRate)
        system.write(list[list.count - 1], sampleRate: sampleRate)

        // 音が届いているか確認できるよう、1 秒ごとにピーク音量を表示する。
        guard Date().timeIntervalSince(lastReport) >= 1 else { return }
        fputs("\r音量: システム \(system.report()) / マイク \(mic.report())  ", stderr)
        lastReport = Date()
    }

    // 停止してタップと集約デバイスを片付け、ファイルを閉じて保存を完了する。
    func finish() {
        if let procID {
            AudioDeviceStop(aggregate, procID)
            AudioDeviceDestroyIOProcID(aggregate, procID)
        }
        AudioHardwareDestroyAggregateDevice(aggregate)
        AudioHardwareDestroyProcessTap(tap)
        queue.sync {
            system.close()
            mic.close()
        }
    }
}

func waitForSignal(_ sig: Int32) async {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        source.setEventHandler { source.cancel(); c.resume() }
        source.resume()
    }
}

// 実行ファイルの隣の data/ に、日時付きの名前で保存する(上書きしない)
func newRecording() throws -> (dir: URL, name: String) {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let dir = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("data")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return (dir, formatter.string(from: Date()))
}
