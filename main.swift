// macOS で鳴っている音(ブラウザの Meet、電話アプリの通話音声など)を .m4a に録音する最小 CLI。
// マイクは録音しません。Core Audio のプロセスタップ(macOS 14.2+)で全プロセスの出力音声を捕まえるので、
// ウィンドウを持たないデーモン(callservicesd / avconferenced)の音も対象になります。
//
// ビルド: make
// 実行:   ./record-audio   (実行ファイルと同じ場所の data/ に日時付きファイルで保存)
// 停止:   Ctrl+C(「保存完了」が出るまで待つ)

import Accelerate
import AVFoundation
import CoreAudio

func check(_ status: OSStatus, _ what: String) throws {
    guard status == noErr else {
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                      userInfo: [NSLocalizedDescriptionKey: "\(what)に失敗しました (OSStatus \(status))"])
    }
}

// AudioObject のグローバルプロパティを 1 つ読む。value には型を決めるための初期値を渡す。
func readProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: T) throws -> T {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var value = value
    var size = UInt32(MemoryLayout<T>.size)
    try withUnsafeMutablePointer(to: &value) {
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0), "プロパティ取得")
    }
    return value
}

final class Recorder {
    let queue = DispatchQueue(label: "record-audio.writer")
    private let url: URL
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var file: AVAudioFile?
    private var format: AVAudioFormat!
    private var peak: Float = 0      // 直近 1 秒のピーク
    private var maxPeak: Float = 0   // 録音全体のピーク
    private var lastReport = Date()

    init(url: URL) { self.url = url }

    func start() throws {
        // 全プロセスの出力をステレオにミックスするタップ(初回はシステムオーディオ録音の許可ダイアログが出る)
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "record-audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tap), "プロセスタップの作成")

        // タップを読み出すには、それを含む非公開の集約デバイスが必要。クロック源として既定の出力デバイスを入れる。
        let output = try readProperty(AudioObjectID(kAudioObjectSystemObject),
                                      kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(kAudioObjectUnknown))
        let outputUID = try readProperty(output, kAudioDevicePropertyDeviceUID, "" as CFString) as String
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "record-audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString,
                                               kAudioSubTapDriftCompensationKey: true]],
        ]
        try check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate), "集約デバイスの作成")

        var asbd = try readProperty(tap, kAudioTapPropertyFormat, AudioStreamBasicDescription())
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            throw NSError(domain: "record-audio", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "タップの音声フォーマットを解釈できません"])
        }
        self.format = format
        file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
        ], commonFormat: format.commonFormat, interleaved: format.isInterleaved)

        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, queue) { [unowned self] _, input, _, _, _ in
            self.write(input)
        }, "IOProc の作成")
        try check(AudioDeviceStart(aggregate, procID), "録音の開始")
    }

    // 音声バッファが届くたびに呼ばれる(queue 上)。
    private func write(_ input: UnsafePointer<AudioBufferList>) {
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input) else { return }
        do { try file?.write(from: pcm) } catch {
            fputs("書き込みエラー: \(error.localizedDescription)\n", stderr)
        }
        measure(pcm)
    }

    // 音が届いているか確認できるよう、1 秒ごとにピーク音量を表示する。
    private func measure(_ pcm: AVAudioPCMBuffer) {
        guard let channels = pcm.floatChannelData else { return }
        for c in 0..<Int(pcm.format.channelCount) {
            var m: Float = 0
            vDSP_maxmgv(channels[c], 1, &m, vDSP_Length(pcm.frameLength))
            peak = max(peak, m)
        }
        guard Date().timeIntervalSince(lastReport) >= 1 else { return }
        let db = peak > 0 ? String(format: "%6.1f dB", 20 * log10(peak)) : "  無音  "
        fputs("\r音量: \(db)  ", stderr)
        maxPeak = max(maxPeak, peak)
        peak = 0
        lastReport = Date()
    }

    // 停止してタップと集約デバイスを片付け、file を解放してヘッダを書き保存を完了する。
    func finish() {
        if let procID {
            AudioDeviceStop(aggregate, procID)
            AudioDeviceDestroyIOProcID(aggregate, procID)
        }
        AudioHardwareDestroyAggregateDevice(aggregate)
        AudioHardwareDestroyProcessTap(tap)
        queue.sync {
            file = nil
            if max(maxPeak, peak) == 0 {
                fputs("\n警告: 録音データは全て無音でした。「システムオーディオ録音」の許可を確認してください。\n", stderr)
            }
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

@main
struct Main {
    static func main() async throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        // 実行ファイルの隣の data/ に、日時付きの名前で保存する(上書きしない)
        let dir = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("data")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("system-audio-\(formatter.string(from: Date())).m4a")

        let recorder = Recorder(url: url)
        try recorder.start()
        print("録音中 → \(url.path)\nCtrl+C で停止して保存します")

        await waitForSignal(SIGINT)
        recorder.finish()
        print("\n保存完了: \(url.path)")
    }
}
