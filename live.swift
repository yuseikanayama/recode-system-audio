// record-audio と同じ録音をしながら、NVIDIA Nemotron 3.5 ASR Streaming でリアルタイムに文字起こしする。
// 推論は NVIDIA 公式のローカル実行環境 NeMo-Speech.cpp の C SDK で行い、音声はこの Mac の外に出ない。
// --model apple で、代わりに Apple の SpeechTranscriber(macOS 26 以降。これもオンデバイス)で認識する。
// system を「相手」、mic を「自分」として別々のストリームで認識し、無音で発話が区切れるたびに 1 行確定する。
// 相手が複数いるときのために、system は Sortformer で話者分離して「相手1」「相手2」…と区別する(最大 4 人)。
// 対面の会議では --in-person を付けると、mic も同じように話者分離して「話者1」「話者2」…になる(自分もその 1 人)。
// 話者分離は ASR に付属のもの(発話ごとに話者の記憶が切れて全員 1 になった)ではなく、単体のストリームを並走させ、
// 確定した発話の時間帯に最も長く重なる話者を採用する。
//
// 準備:   README の「リアルタイム文字起こし」を参照
// ビルド: make live-transcribe
// 実行:   ./live-transcribe [--in-person] [--model nemotron|apple|<model.gguf>]
//         (録音は record-audio と同じ。文字起こしは data/<日時>-live.txt)
// 停止:   Ctrl+C(「保存完了」が出るまで待つ)

import AVFoundation
import CoreAudio
import Foundation
import Speech

func failure(_ message: String) -> NSError {
    NSError(domain: "live-transcribe", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

func asrCheck(_ status: nemo_speech_asr_status, _ what: String) throws {
    guard status == NEMO_SPEECH_ASR_OK else {
        let reason = String(cString: nemo_speech_asr_last_error())
        throw NSError(domain: "nemo-speech", code: Int(status.rawValue),
                      userInfo: [NSLocalizedDescriptionKey: "\(what)に失敗しました: \(reason)"])
    }
}

// nemo-speech pull が保存した公式の GGUF を探す(パスにリビジョンが入るので列挙する)。
func cachedModel(_ repo: String) -> String? {
    let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/NeMoSpeech/models/nvidia/\(repo)")
    let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
    return files.first { $0.pathExtension == "gguf" }?.path
}

// SDK(ggml)は診断ログを大量に stderr へ出し、止める手段がない。
// stderr は捨て、自分の表示は複製しておいた元の出力先(console)に出す。
func silenceSDKLogs() {
    console = fdopen(dup(STDERR_FILENO), "w")
    setvbuf(console, nil, _IONBF, 0)
    let null = open("/dev/null", O_WRONLY)
    dup2(null, STDERR_FILENO)
    close(null)
}

// モデルを読み込む。1 つの recognizer を 2 本のストリームで共有するので、重みは 1 回しか載らない。
// 設定の構造体は sizeof を size に入れる約束(Swift の size は末尾の詰め物を含まないので stride を使う)。
func makeRecognizer(model path: String) throws -> OpaquePointer {
    var backend = nemo_speech_asr_backend_config()
    backend.size = MemoryLayout.stride(ofValue: backend)
    backend.gpu = 0   // Metal
    var model = nemo_speech_asr_model_config()
    model.size = MemoryLayout.stride(ofValue: model)
    // 先読みはモデルが対応する最大の 13 フレーム(1.12 秒)。遅延は増えるが日本語の精度が最も高い。
    // CTC 用の 3 つは既定値のまま。
    var streaming = nemo_speech_asr_streaming_config()
    streaming.size = MemoryLayout.stride(ofValue: streaming)
    streaming.chunk_size = 0.16
    streaming.ctc_left_padding = 1.92
    streaming.ctc_right_padding = 1.92
    streaming.rnnt_right_context = 13
    // 無音が 0.8 秒続いたら発話を確定する。
    var endpointing = nemo_speech_asr_endpointing_config()
    endpointing.size = MemoryLayout.stride(ofValue: endpointing)
    endpointing.enable = true
    endpointing.stop_history_eou_ms = 800

    return try path.withCString { path in
        model.path = path
        return try withUnsafePointer(to: backend) { backend in
        try withUnsafePointer(to: model) { model in
        try withUnsafePointer(to: streaming) { streaming in
        try withUnsafePointer(to: endpointing) { endpointing in
            var config = nemo_speech_asr_recognizer_config()
            config.size = MemoryLayout.stride(ofValue: config)
            config.backend = backend
            config.model = model
            config.streaming = streaming
            config.endpointing = endpointing
            var recognizer: OpaquePointer?
            try asrCheck(nemo_speech_asr_create(&config, &recognizer), "モデルの読み込み")
            return recognizer!
        }}}}
    }
}

// 話者分離のモデル(Sortformer)を読み込む。1 つのモデルを複数のストリームで共有できる。
// 形状は NVIDIA が公開している低遅延の設定(1 フレーム 80 ms)。SDK の既定(fifo 80、spkcache 160、update 80)は
// 話者の記憶が短く、対面の 2 人の会話がほぼ 1 人にまとめられた。
func makeDiarizer(model path: String) throws -> OpaquePointer {
    var config = nemo_speech_diar_model_config()
    config.size = MemoryLayout.stride(ofValue: config)
    config.gpu = 0   // Metal
    config.chunk_frames = 6
    config.right_context_frames = 7
    config.left_context_frames = 0
    config.fifo_frames = 188
    config.spkcache_frames = 188
    config.update_period_frames = 144
    return try path.withCString { path in
        config.model_path = path
        var model: OpaquePointer?
        try asrCheck(nemo_speech_diar_create(&config, &model), "話者分離モデルの読み込み")
        return model!
    }
}

// 話者分離のストリーム。認識と同じ音声を並走で渡し、確定した発話の時間帯に最も長く重なる話者を求める。
// 付加機能なので、失敗しても止めるのは話者分離だけで、文字起こしは番号なしで続ける。
final class Diarization {
    private var diar: OpaquePointer?

    init(_ diarizer: OpaquePointer) throws {
        try asrCheck(nemo_speech_diar_stream_open(diarizer, &diar), "話者分離の開始")
    }

    func push(_ samples: [Float], sampleRate: Double) {
        call("話者分離への受け渡し") { nemo_speech_diar_stream_push_f32($0, samples, samples.count, Int32(sampleRate)) }
    }

    func finish() {
        call("話者分離の終了") { nemo_speech_diar_stream_finish($0) }
    }

    func close() {
        if let diar { nemo_speech_diar_stream_close(diar) }
        diar = nil
    }

    // from〜to 秒に最も長く重なっている話者(1 始まり)。止まっているか、重なりが無ければ 0。
    // 区間の後処理はストリーム全体に及ぶので、確定した発話にだけ使う。
    func speaker(from: Double, to: Double) -> Int32 {
        var count = 0
        guard call("話者分離の結果", { nemo_speech_diar_segments($0, nil, nil, 0, &count) }) else { return 0 }
        var segments = [nemo_speech_diar_segment](repeating: nemo_speech_diar_segment(), count: count)
        guard call("話者分離の結果", { nemo_speech_diar_segments($0, nil, &segments, count, &count) }) else { return 0 }
        var overlap: [Int32: Double] = [:]
        for segment in segments.prefix(count) {
            let length = min(to, segment.end_time) - max(from, segment.start_time)
            if length > 0 { overlap[segment.speaker, default: 0] += length }
        }
        return overlap.max { $0.value < $1.value }?.key ?? 0
    }

    @discardableResult
    private func call(_ what: String, _ body: (OpaquePointer) -> nemo_speech_asr_status) -> Bool {
        guard let diar else { return false }
        if body(diar) == NEMO_SPEECH_ASR_OK { return true }
        let reason = String(cString: nemo_speech_asr_last_error())
        fputs("\n話者分離を停止しました(文字起こしは続きます): \(what)に失敗しました: \(reason)\n", console)
        close()
        return false
    }
}

// 1 入力ぶんのストリーミング認識。push と finish は、確定した発話を「[時刻] 話者: 本文」の行で返す。
// 話者分離のモデルを渡すと、話者名に 1 始まりの番号が付く(「相手1」)。
protocol SpeechStream: AnyObject {
    var onPartial: (_ who: String, _ text: String) -> Void { get set }   // 認識途中の文(確定したら空文字)
    func push(_ samples: [Float], sampleRate: Double) throws -> [String]
    func finish() throws -> [String]   // 残りの音声を認識しきる
    func close()
}

func line(at seconds: Double, _ who: String, _ speaker: Int32, _ text: String) -> String {
    let s = Int(seconds)
    let who = speaker > 0 ? "\(who)\(speaker)" : who
    return String(format: "[%02d:%02d:%02d] %@: %@", s / 3600, s % 3600 / 60, s % 60, who, text)
}

// Nemotron(NeMo-Speech.cpp)での認識。サンプルレートの変換は SDK がやってくれる。
final class NemotronStream: SpeechStream {
    private let who: String
    private var stream: OpaquePointer?
    private var diar: Diarization?
    private var start: Float?   // 認識中の発話が始まった時刻(録音開始からの秒)
    var onPartial: (_ who: String, _ text: String) -> Void = { _, _ in }

    init(_ who: String, recognizer: OpaquePointer, diarizer: OpaquePointer?) throws {
        self.who = who
        var options = nemo_speech_asr_recognition_options_default()
        options.interim_results = true
        options.enable_word_time_offsets = true   // 話者分離の結果と突き合わせる時刻
        try "ja-JP".withCString {
            options.language_code = $0
            try asrCheck(nemo_speech_asr_streaming_recognize(recognizer, &options, &stream), "ストリームの開始")
        }
        diar = try diarizer.map(Diarization.init)
    }

    func push(_ samples: [Float], sampleRate: Double) throws -> [String] {
        try asrCheck(nemo_speech_asr_stream_push_f32(stream, samples, samples.count, Int32(sampleRate)), "音声の受け渡し")
        diar?.push(samples, sampleRate: sampleRate)
        return try drain()
    }

    func finish() throws -> [String] {
        diar?.finish()
        try asrCheck(nemo_speech_asr_stream_finish(stream), "ストリームの終了")
        return try drain()
    }

    // recognizer を解放する前に呼ぶ。
    func close() {
        nemo_speech_asr_stream_close(stream)
        stream = nil
        diar?.close()
    }

    private func speaker(of result: OpaquePointer) -> Int32 {
        let words = nemo_speech_asr_result_word_count(result, 0)
        guard let diar, words > 0 else { return 0 }
        return diar.speaker(from: Double(nemo_speech_asr_result_word_start_time(result, 0, 0)) / 1000,
                            to: Double(nemo_speech_asr_result_word_end_time(result, 0, words - 1)) / 1000)
    }

    // 今の時点で出ている結果をすべて受け取る。
    private func drain() throws -> [String] {
        var lines: [String] = []
        while true {
            var result: OpaquePointer?
            try asrCheck(nemo_speech_asr_stream_next(stream, &result), "認識")
            guard let result else { return lines }
            defer { nemo_speech_asr_result_destroy(result) }
            guard nemo_speech_asr_result_alternative_count(result) > 0 else { continue }
            let text = String(cString: nemo_speech_asr_result_transcript(result, 0)).trimmingCharacters(in: .whitespaces)
            let s = Int(start ?? nemo_speech_asr_result_audio_processed(result))
            if nemo_speech_asr_result_is_final(result) {
                if !text.isEmpty { lines.append(line(at: Double(s), who, speaker(of: result), text)) }
                start = nil
                onPartial(who, "")
            } else if !text.isEmpty {
                start = Float(s)
                onPartial(who, text)
            }
        }
    }
}

// Apple の SpeechTranscriber(SpeechAnalyzer)での認識。これもオンデバイスで、音声は Mac の外に出ない。
// 結果は別のタスクに非同期で届くので溜めておき、push のたびに呼び出し元(Transcriber のキュー)で受け取る。
@available(macOS 26, *)
final class AppleStream: SpeechStream, @unchecked Sendable {
    private let who: String
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let format: AVAudioFormat   // モデルが受け付ける形式。録音から変換して渡す
    private var converter: AVAudioConverter?
    private var diar: Diarization?
    private var reader: Task<Void, Never>?
    private let lock = NSLock()
    private var received: [(isFinal: Bool, text: String, range: CMTimeRange)] = []
    private var readError: Error?
    var onPartial: (_ who: String, _ text: String) -> Void = { _, _ in }

    // 日本語のモデルが入っていなければダウンロードする(初回のみ)。
    static func prepare() async throws -> Locale {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "ja-JP")) else {
            throw failure("Apple の音声認識が日本語に対応していません")
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            fputs("Apple の日本語モデルをダウンロード中…\n", console)
            try await request.downloadAndInstall()
        }
        return locale
    }

    init(_ who: String, locale: Locale, diarizer: OpaquePointer?) async throws {
        self.who = who
        // 認識途中の文(volatile)と、話者分離と突き合わせる時刻も受け取る
        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
        analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw failure("Apple の音声認識が受け付ける音声の形式が分かりません")
        }
        self.format = format
        let (sequence, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
        self.input = input
        diar = try diarizer.map(Diarization.init)
        try await analyzer.start(inputSequence: sequence)
        reader = Task { [unowned self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespaces)
                    lock.withLock { received.append((result.isFinal, text, result.range)) }
                }
            } catch {
                lock.withLock { readError = error }
            }
        }
    }

    func push(_ samples: [Float], sampleRate: Double) throws -> [String] {
        let buffer = try convert(samples, sampleRate: sampleRate)
        if buffer.frameLength > 0 { input.yield(AnalyzerInput(buffer: buffer)) }
        diar?.push(samples, sampleRate: sampleRate)
        return try drain()
    }

    // 呼び出し元のキューを止めたまま、非同期の終了処理と結果の受け取りを待つ。
    func finish() throws -> [String] {
        input.finish()
        diar?.finish()
        let done = DispatchSemaphore(value: 0)
        var finishError: Error?
        Task { [self] in
            do { try await analyzer.finalizeAndFinishThroughEndOfInput() } catch { finishError = error }
            await reader?.value
            done.signal()
        }
        done.wait()
        if let finishError { throw finishError }
        return try drain()
    }

    func close() {
        diar?.close()
    }

    // 録音(モノラルの Float32)をモデルの形式にする。変換器は前後のサンプルを持ち越すので使い回す。
    private func convert(_ samples: [Float], sampleRate: Double) throws -> AVAudioPCMBuffer {
        let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
        guard let converter = converter ?? AVAudioConverter(from: source, to: format) else {
            throw failure("音声を Apple の音声認識の形式に変換できません")
        }
        self.converter = converter
        let capacity = AVAudioFrameCount(Double(samples.count) * format.sampleRate / sampleRate) + 1024
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)!
        var given = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            defer { given = true }
            status.pointee = given ? .noDataNow : .haveData
            return given ? nil : buffer
        }
        if let error { throw error }
        return output
    }

    // ここまでに届いた結果をすべて受け取る。
    private func drain() throws -> [String] {
        let (results, error) = lock.withLock {
            defer { received = [] }
            return (received, readError)
        }
        if let error { throw error }
        var lines: [String] = []
        for result in results {
            if result.isFinal {
                if !result.text.isEmpty {
                    let from = result.range.start.seconds, to = result.range.end.seconds
                    lines.append(line(at: from, who, diar?.speaker(from: from, to: to) ?? 0, result.text))
                }
                onPartial(who, "")
            } else if !result.text.isEmpty {
                onPartial(who, result.text)
            }
        }
        return lines
    }
}

// インターリーブされた Float32 のバッファを、全チャンネルの平均でモノラルにする。
func mono(_ buffer: AudioBuffer) -> [Float] {
    let channels = Int(buffer.mNumberChannels)
    let samples = UnsafeBufferPointer(start: buffer.mData!.assumingMemoryBound(to: Float.self),
                                      count: Int(buffer.mDataByteSize) / 4)
    guard channels > 1 else { return Array(samples) }
    return stride(from: 0, to: samples.count, by: channels).map { i in
        samples[i..<i + channels].reduce(0, +) / Float(channels)
    }
}

// 画面上の桁数(全角は 2 桁と数える)。
func columns(_ text: String) -> Int {
    text.reduce(0) { $0 + ($1.isASCII ? 1 : 2) }
}

// 2 本のストリームをまとめ、確定した行を画面とファイルに出す。
// 画面の最下部 2 行は上書きで使う(上が認識途中の文、下が音量)。カーソルはいつも上の行の先頭に置いておく。
// 認識は録音の書き込みを待たせないよう専用のキューで行い、状態にはそのキューからしか触らない。
final class Transcriber: @unchecked Sendable {
    private let queue = DispatchQueue(label: "live-transcribe.asr")
    private let mic: SpeechStream
    private let system: SpeechStream
    private let url: URL
    private let file: FileHandle
    private var lines: [String] = []
    private var failed = false
    private var levels = ""
    private var partial = (who: "", text: "")
    // 最下部に今出ている内容。nil なら出さない(端末でないときと、終了処理に入ってから)。
    private var status: String? = isatty(fileno(console)) != 0 ? "" : nil

    init(mic: SpeechStream, system: SpeechStream, url: URL) throws {
        self.mic = mic
        self.system = system
        self.url = url
        FileManager.default.createFile(atPath: url.path, contents: nil)
        file = try FileHandle(forWritingTo: url)
        // 複数人が同時に話しているときは、後から更新されたほうを表示する。確定で消すのは自分の文だけ。
        let onPartial: (String, String) -> Void = { [unowned self] who, text in
            if !text.isEmpty || partial.who == who { partial = (who, text) }
        }
        mic.onPartial = onPartial
        system.onPartial = onPartial
    }

    func showLevels(_ text: String) {
        queue.async { [self] in
            levels = text
            drawStatus()
        }
    }

    func push(mic micSamples: [Float], system systemSamples: [Float], sampleRate: Double) {
        queue.async { [self] in
            emit { try mic.push(micSamples, sampleRate: sampleRate) + system.push(systemSamples, sampleRate: sampleRate) }
        }
    }

    // 最下部の表示を消して、以後は出さない(録音の終了時の警告と混ざらないよう、先に呼ぶ)。
    func hideStatus() {
        queue.sync {
            if status != nil { fputs("\r\u{1B}[J", console) }
            status = nil
        }
    }

    // 溜まっている音声を認識しきるまで待つ。
    // 長い発話ほど遅れて確定するので、ファイルは最後に発話の開始順(同時刻なら確定順)へ並べ直す。
    func finish() throws {
        queue.sync {
            emit { try mic.finish() + system.finish() }
            mic.close()
            system.close()
        }
        let sorted = lines.enumerated().sorted { ($0.element.prefix(10), $0.offset) < ($1.element.prefix(10), $1.offset) }
        try sorted.map { $0.element + "\n" }.joined().write(to: url, atomically: true, encoding: .utf8)
    }

    // 確定した行はその場でファイルにも足しておく(途中で落ちても残る)。認識で失敗しても録音は続ける。
    private func emit(_ newLines: () throws -> [String]) {
        guard !failed else { return }
        do {
            for line in try newLines() {
                if status != nil {
                    fputs("\r\u{1B}[J", console)
                    status = ""
                }
                print(line)
                fflush(stdout)
                file.write((line + "\n").data(using: .utf8)!)
                lines.append(line)
            }
            drawStatus()
        } catch {
            failed = true
            fputs("\n文字起こしを停止しました(録音は続きます): \(error.localizedDescription)\n", console)
        }
    }

    // 内容が変わっていたら最下部の 2 行を描き直す。
    // 折り返すと上書きできなくなるので、認識途中の文は端末の幅に収まる末尾だけを出す。
    private func drawStatus() {
        guard status != nil else { return }
        var size = winsize()
        let width = ioctl(fileno(console), TIOCGWINSZ, &size) == 0 && size.ws_col > 0 ? Int(size.ws_col) : 80
        let label = partial.text.isEmpty ? "" : "\(partial.who): "
        var room = width - columns(label) - 1
        let tail = String(partial.text.reversed().prefix { room -= columns(String($0)); return room >= 0 }.reversed())
        let next = "\(label)\(tail)\n\u{1B}[K\(levels)"
        guard next != status else { return }
        status = next
        fputs("\r\u{1B}[K\(next)\u{1B}[1A\r", console)
    }
}

@main
struct Main {
    static func main() async {
        silenceSDKLogs()
        do {
            try await run()
        } catch {
            fputs("エラー: \(error.localizedDescription)\n", console)
            _exit(1)   // exit だと、モデルを解放していない SDK が終了処理の中で abort する
        }
    }

    static func run() async throws {
        var args = Array(CommandLine.arguments.dropFirst())
        let inPerson = args.contains("--in-person")
        args.removeAll { $0 == "--in-person" }
        var model = "nemotron"
        if let i = args.firstIndex(of: "--model"), i + 1 < args.count {
            model = args[i + 1]
            args.removeSubrange(i...i + 1)
        }
        guard args.isEmpty else {
            throw failure("使い方: ./live-transcribe [--in-person] [--model nemotron|apple|<model.gguf>]")
        }

        // 録音を始める前に読み込んでおく(10 秒ほどかかる)
        let diarPath = cachedModel("diar_streaming_sortformer_4spk-v2")
        if diarPath == nil {
            fputs("話者分離のモデルがないので話者を区別しません(nemo-speech pull sortformer で有効になります)\n", console)
        }
        fputs("モデルを読み込み中…\n", console)
        let diarizer = try diarPath.map(makeDiarizer)
        var recognizer: OpaquePointer?
        let makeStream: (_ who: String, _ diarizer: OpaquePointer?) async throws -> SpeechStream
        if model == "apple" {
            guard #available(macOS 26, *) else { throw failure("Apple のモデルは macOS 26 以降で使えます") }
            let locale = try await AppleStream.prepare()
            makeStream = { try await AppleStream($0, locale: locale, diarizer: $1) }
        } else {
            guard let path = model == "nemotron" ? cachedModel("nemotron-3.5-asr-streaming-0.6b") : model else {
                throw failure("モデルがありません。先に nemo-speech pull nemotron-3.5 を実行してください")
            }
            let nemotron = try makeRecognizer(model: path)
            recognizer = nemotron
            makeStream = { try NemotronStream($0, recognizer: nemotron, diarizer: $1) }
        }
        let mic = try await makeStream(inPerson ? "話者" : "自分", inPerson ? diarizer : nil)
        let system = try await makeStream("相手", diarizer)

        let (dir, name) = try newRecording()
        let textURL = dir.appendingPathComponent("\(name)-live.txt")
        let transcriber = try Transcriber(mic: mic, system: system, url: textURL)

        let recorder = Recorder(dir: dir, name: name)
        recorder.onLevels = { transcriber.showLevels($0) }
        recorder.onAudio = { mic, system, sampleRate in
            transcriber.push(mic: mono(mic), system: mono(system), sampleRate: sampleRate)
        }
        try recorder.start()
        print("マイク: \(recorder.micName)\n録音中 →\n\(recorder.paths)\n\(textURL.path)\nCtrl+C で停止して保存します")

        await waitForSignal(SIGINT)
        transcriber.hideStatus()
        recorder.finish()
        try transcriber.finish()
        if let recognizer { nemo_speech_asr_destroy(recognizer) }
        if let diarizer { nemo_speech_diar_destroy(diarizer) }
        print("保存完了")
    }
}
