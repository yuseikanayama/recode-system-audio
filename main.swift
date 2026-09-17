// macOS のシステム音声(ブラウザの Meet 音声など)を .m4a に録音する最小 CLI。
// マイクは録音しません。映像は取得せず、ScreenCaptureKit の音声のみ使います。
//
// ビルド: make
// 実行:   ./record-audio [出力先.m4a]   (省略時はカレントに日時付きファイル)
// 停止:   Ctrl+C(「保存完了」が出るまで待つ)

import Accelerate
import AVFoundation
import ScreenCaptureKit

final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "record-audio.writer")
    private let url: URL
    private var file: AVAudioFile?
    private var peak: Float = 0      // 直近 1 秒のピーク
    private var maxPeak: Float = 0   // 録音全体のピーク
    private var lastReport = Date()

    init(url: URL) { self.url = url }

    // 音声バッファが届くたびに呼ばれる(queue 上)。最初のバッファでファイルを開く。
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, let desc = sampleBuffer.formatDescription else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: desc)
        do {
            if file == nil {
                file = try AVAudioFile(forWriting: url, settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: format.sampleRate,
                    AVNumberOfChannelsKey: format.channelCount,
                ], commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            }
            try sampleBuffer.withAudioBufferList { list, _ in
                guard let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list.unsafePointer)
                else { return }
                try file?.write(from: pcm)
                measure(pcm)
            }
        } catch {
            fputs("書き込みエラー: \(error.localizedDescription)\n", stderr)
        }
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

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fputs("ストリームが停止しました: \(error.localizedDescription)\n", stderr)
        queue.async { self.file = nil; exit(1) }
    }

    // file を解放するとヘッダが書かれて保存が完了する。
    func finish() {
        queue.sync {
            file = nil
            if max(maxPeak, peak) == 0 {
                fputs("\n警告: 録音データは全て無音でした。音声が ScreenCaptureKit に届いていません。\n", stderr)
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
        let path = CommandLine.arguments.dropFirst().first
            ?? "system-audio-\(formatter.string(from: Date())).m4a"
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)

        // 画面全体をフィルタにして音声だけ受け取る(初回は収録権限のダイアログが出る)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            fputs("ディスプレイが見つかりません\n", stderr); exit(1)
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // 映像は使わないので最小コストに
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let recorder = Recorder(url: url)
        let stream = SCStream(filter: filter, configuration: config, delegate: recorder)
        try stream.addStreamOutput(recorder, type: .audio, sampleHandlerQueue: recorder.queue)
        try await stream.startCapture()
        print("録音中 → \(url.path)\nCtrl+C で停止して保存します")

        await waitForSignal(SIGINT)
        try? await stream.stopCapture()
        recorder.finish()
        print("\n保存完了: \(url.path)")
    }
}
