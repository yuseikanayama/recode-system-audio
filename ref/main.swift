import Foundation
import AVFoundation
import CoreMedia
import ScreenCaptureKit

// CMSampleBuffer → AVAudioPCMBuffer 変換
extension CMSampleBuffer {
    var asPCMBuffer: AVAudioPCMBuffer? {
        try? self.withAudioBufferList { audioBufferList, _ -> AVAudioPCMBuffer? in
            guard let absd = self.formatDescription?.audioStreamBasicDescription,
                  let format = AVAudioFormat(standardFormatWithSampleRate: absd.mSampleRate,
                                             channels: absd.mChannelsPerFrame)
            else { return nil }
            return AVAudioPCMBuffer(pcmFormat: format,
                                    bufferListNoCopy: audioBufferList.unsafePointer)
        }
    }
}

final class SystemAudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private var audioFile: AVAudioFile?
    private let outputURL: URL

    init(outputURL: URL) { self.outputURL = outputURL }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, let pcm = sampleBuffer.asPCMBuffer else { return }
        do {
            if audioFile == nil {
                audioFile = try AVAudioFile(forWriting: outputURL, settings: pcm.format.settings)
                print("録音開始 → \(outputURL.path)")
            }
            try audioFile?.write(from: pcm)
        } catch {
            print("書き込みエラー: \(error)")
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("ストリーム停止: \(error)")
        exit(1)
    }
}

@main
struct Main {
    static func main() async throws {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("system-audio-\(Int(Date().timeIntervalSince1970)).caf")
        let recorder = SystemAudioRecorder(outputURL: url)

        // 画面全体を対象にしたフィルタ(音声取得に必要。映像は捨てる)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { fatalError("ディスプレイが見つかりません") }
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true                 // ← これが本体
        config.excludesCurrentProcessAudio = true   // 自分自身の音は除外
        config.sampleRate = 48_000
        config.channelCount = 2
        // 映像は使わないので最小コストに
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: recorder)
        try stream.addStreamOutput(recorder, type: .audio,
                                   sampleHandlerQueue: DispatchQueue(label: "audio.queue"))
        try await stream.startCapture()
        print("録音中… Ctrl+C で停止して保存します")

        // Ctrl+C で綺麗に閉じる
        signal(SIGINT, SIG_IGN)
        let sig = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sig.setEventHandler {
            Task {
                try? await stream.stopCapture()
                print("\n保存完了: \(url.lastPathComponent)")
                exit(0)
            }
        }
        sig.resume()

        dispatchMain()
    }
}
