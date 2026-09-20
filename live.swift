// record-audio と同じ録音をしながら、NVIDIA Nemotron 3.5 ASR Streaming でリアルタイムに文字起こしする。
// 推論は NVIDIA 公式のローカル実行環境 NeMo-Speech.cpp の C SDK で行い、音声はこの Mac の外に出ない。
// system を「相手」、mic を「自分」として別々のストリームで認識し、無音で発話が区切れるたびに 1 行確定する。
//
// 準備:   README の「リアルタイム文字起こし」を参照
// ビルド: make live-transcribe
// 実行:   ./live-transcribe [model.gguf]   (録音は record-audio と同じ。文字起こしは data/<日時>-live.txt)
// 停止:   Ctrl+C(「保存完了」が出るまで待つ)

import CoreAudio
import Foundation

func asrCheck(_ status: nemo_speech_asr_status, _ what: String) throws {
    guard status == NEMO_SPEECH_ASR_OK else {
        let reason = String(cString: nemo_speech_asr_last_error())
        throw NSError(domain: "nemo-speech", code: Int(status.rawValue),
                      userInfo: [NSLocalizedDescriptionKey: "\(what)に失敗しました: \(reason)"])
    }
}

// nemo-speech pull が保存した公式の GGUF を探す(パスにリビジョンが入るので列挙する)。
func cachedModel() throws -> String {
    let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/NeMoSpeech/models/nvidia/nemotron-3.5-asr-streaming-0.6b")
    let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
    guard let model = files.first(where: { $0.pathExtension == "gguf" }) else {
        throw NSError(domain: "live-transcribe", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "モデルがありません。先に nemo-speech pull nemotron-3.5 を実行してください"])
    }
    return model.path
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

// 1 話者ぶんのストリーミング認識。
final class LiveStream {
    private let who: String
    private var stream: OpaquePointer?
    private var start: Float?   // 認識中の発話が始まった時刻(録音開始からの秒)
    var onPartial: (_ who: String, _ text: String) -> Void = { _, _ in }   // 認識途中の文(確定したら空文字)

    init(_ who: String, recognizer: OpaquePointer) throws {
        self.who = who
        var options = nemo_speech_asr_recognition_options_default()
        options.interim_results = true
        try "ja-JP".withCString {
            options.language_code = $0
            try asrCheck(nemo_speech_asr_streaming_recognize(recognizer, &options, &stream), "ストリームの開始")
        }
    }

    // 音声を渡し、確定した発話を「[時刻] 話者: 本文」の行で返す。サンプルレートの変換は SDK がやってくれる。
    func push(_ samples: [Float], sampleRate: Double) throws -> [String] {
        try asrCheck(nemo_speech_asr_stream_push_f32(stream, samples, samples.count, Int32(sampleRate)), "音声の受け渡し")
        return try drain()
    }

    // 残りの音声を認識しきって、ストリームを閉じる。
    func finish() throws -> [String] {
        defer { nemo_speech_asr_stream_close(stream) }
        try asrCheck(nemo_speech_asr_stream_finish(stream), "ストリームの終了")
        return try drain()
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
                if !text.isEmpty {
                    lines.append(String(format: "[%02d:%02d:%02d] %@: %@", s / 3600, s % 3600 / 60, s % 60, who, text))
                }
                start = nil
                onPartial(who, "")
            } else if !text.isEmpty {
                start = Float(s)
                onPartial(who, text)
            }
        }
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
    private let mic: LiveStream
    private let system: LiveStream
    private let url: URL
    private let file: FileHandle
    private var lines: [String] = []
    private var failed = false
    private var levels = ""
    private var partial = (who: "", text: "")
    private var status: String? = ""   // 最下部に今出ている内容(nil なら表示をやめている)

    init(recognizer: OpaquePointer, url: URL) throws {
        mic = try LiveStream("自分", recognizer: recognizer)
        system = try LiveStream("相手", recognizer: recognizer)
        self.url = url
        FileManager.default.createFile(atPath: url.path, contents: nil)
        file = try FileHandle(forWritingTo: url)
        // 2 人が同時に話しているときは、後から更新されたほうを表示する。
        mic.onPartial = { [unowned self] in partial = ($0, $1) }
        system.onPartial = { [unowned self] in partial = ($0, $1) }
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
            fputs("\r\u{1B}[J", console)
            status = nil
        }
    }

    // 溜まっている音声を認識しきるまで待つ。
    // 長い発話ほど遅れて確定するので、ファイルは最後に発話の開始順(同時刻なら確定順)へ並べ直す。
    func finish() throws {
        queue.sync { emit { try mic.finish() + system.finish() } }
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
        // 録音を始める前に読み込んでおく(10 秒ほどかかる)
        let modelPath = try CommandLine.arguments.dropFirst().first ?? cachedModel()
        fputs("モデルを読み込み中…\n", console)
        let recognizer = try makeRecognizer(model: modelPath)

        let (dir, name) = try newRecording()
        let textURL = dir.appendingPathComponent("\(name)-live.txt")
        let transcriber = try Transcriber(recognizer: recognizer, url: textURL)

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
        nemo_speech_asr_destroy(recognizer)
        print("保存完了")
    }
}
