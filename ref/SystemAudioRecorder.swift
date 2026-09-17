// macOS 13+ / Swift / Apple標準フレームワークだけでシステム音声を録音します。
// マイクは取得しません。映像の出力・保存もしません。
//
// 1. Command Line Toolsが未導入の場合: xcode-select --install
// 2. このファイルのあるフォルダでビルド:
//    xcrun swiftc -swift-version 5 -parse-as-library -O \
//      -target "$(uname -m)-apple-macos13.0" \
//      SystemAudioRecorder.swift -o record-audio
// 3. 実行: ./record-audio recording.m4a
// 4. Ctrl+Cで停止。保存完了が表示されるまで待ってください。
//
// 初回はScreenCaptureKitの収録権限が必要です。許可しても起動できない場合は、
// システム設定 > プライバシーとセキュリティ > 画面とシステムオーディオの収録
// （旧OSでは「画面収録」）で、表示された実行元を許可して再起動してください。
// ログイン中のデスクトップで実行する小さなサンプルです。
// スリープや音声デバイス変更からの自動復旧は実装していません。
// このコードを作成した環境はLinuxのため、Macでのビルド・実録音は未検証です。
// 参考: https://developer.apple.com/videos/play/wwdc2022/10156/

import Foundation
import AVFoundation
import AudioToolbox
import ScreenCaptureKit
import Darwin

private func recordingError(_ message: String) -> NSError {
    NSError(domain: "SystemAudioRecorder", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message])
}

// シグナルや録音エラーから、非同期mainに停止を通知します。
private final class StopRequest {
    let events: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        var continuation: AsyncStream<Void>.Continuation!
        events = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func request() {
        continuation.yield(())
        continuation.finish()
    }
}

private final class AudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "system-audio.writer")
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let stop: StopRequest
    // 以下の可変状態とappend操作はqueueに集約します。
    private var accepting = true
    private var failure: Error?
    private var droppedBuffers = 0

    init(url: URL, stop: StopRequest) throws {
        self.stop = stop
        writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000
        ])
        input.expectsMediaDataInRealTime = true
        super.init()
        guard writer.canAdd(input) else {
            throw recordingError("AAC音声の書き込みを初期化できません。")
        }
        writer.add(input)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of outputType: SCStreamOutputType) {
        guard accepting, failure == nil, outputType == .audio,
              sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer),
              CMSampleBufferGetNumSamples(sampleBuffer) > 0,
              sampleBuffer.presentationTimeStamp.isValid else { return }

        if writer.status == .unknown {
            guard writer.startWriting() else {
                failure = writer.error ?? recordingError("録音ファイルを開始できません。")
                stop.request()
                return
            }
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
        }
        guard writer.status == .writing else {
            failure = writer.error ?? recordingError("録音ファイルへの書き込みが停止しました。")
            stop.request()
            return
        }
        guard input.isReadyForMoreMediaData else {
            droppedBuffers += 1
            return
        }
        if !input.append(sampleBuffer) {
            failure = writer.error ?? recordingError("音声データを書き込めません。")
            stop.request()
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async {
            self.failure = self.failure ?? error
            self.stop.request()
        }
    }

    func finish() async throws {
        try await withCheckedThrowingContinuation { (result: CheckedContinuation<Void, Error>) in
            queue.async {
                self.accepting = false
                guard self.writer.status == .writing else {
                    let error = self.failure ?? self.writer.error
                        ?? recordingError("音声データが届きませんでした。音を再生し、権限を確認してください。")
                    if self.writer.status == .unknown { self.writer.cancelWriting() }
                    result.resume(throwing: error)
                    return
                }
                self.input.markAsFinished()
                let captureError = self.failure
                let dropped = self.droppedBuffers
                self.writer.finishWriting {
                    if dropped > 0 {
                        fputs("注意: 書き込みの遅延により音声バッファを\(dropped)個取りこぼしました。\n", stderr)
                    }
                    if let error = self.writer.error ?? captureError {
                        result.resume(throwing: error)
                    } else if self.writer.status == .completed {
                        result.resume(returning: ())
                    } else {
                        result.resume(throwing: recordingError("録音ファイルの保存が完了しませんでした。"))
                    }
                }
            }
        }
    }
}

@main
private struct Main {
    static func main() async {
        setbuf(stdout, nil)
        guard CommandLine.arguments.count == 2 else {
            print("使い方: ./record-audio 出力先.m4a\n停止: Ctrl+C")
            exit(2)
        }
        do {
            let path = (CommandLine.arguments[1] as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard url.pathExtension.lowercased() == "m4a" else {
                throw recordingError("出力先の拡張子は.m4aにしてください。")
            }
            guard !FileManager.default.fileExists(atPath: url.path) else {
                throw recordingError("同名ファイルが存在します。別の出力先を指定してください。")
            }

            print("収録対象を取得しています。初回はmacOSの権限確認に対応してください。")
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else {
                throw recordingError("ディスプレイが見つかりません。ログイン中のMac上で実行してください。")
            }
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
            // 映像出力は登録しません。映像側の設定も小さくしておきます。
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

            let stop = StopRequest()
            let recorder = try AudioRecorder(url: url, stop: stop)
            let stream = SCStream(filter: filter, configuration: config, delegate: recorder)
            try stream.addStreamOutput(recorder, type: .audio, sampleHandlerQueue: recorder.queue)

            let signals = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
                source.setEventHandler { stop.request() }
                source.resume()
                return source
            }
            defer { signals.forEach { $0.cancel() } }

            try await stream.startCapture()
            print("録音中: \(url.path)\nCtrl+Cで停止・保存します。")
            for await _ in stop.events { break }
            // ストリーム停止がエラーになっても、M4Aの終端処理は試みます。
            do { try await stream.stopCapture() }
            catch { fputs("収録停止: \(error.localizedDescription)\n", stderr) }
            try await recorder.finish()
            print("保存完了: \(url.path)")
        } catch {
            fputs("エラー: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
