// macOS で鳴っている音(ブラウザの Meet、電話アプリの通話音声など)とマイクの音を、別々の .m4a に録音する最小 CLI。
// 録音の仕組みは recorder.swift を参照。
//
// ビルド: make
// 実行:   ./record-audio   (実行ファイルと同じ場所の data/ に <日時>-system.m4a と <日時>-mic.m4a で保存)
// 停止:   Ctrl+C(「保存完了」が出るまで待つ)

import Foundation

@main
struct Main {
    static func main() async throws {
        let (dir, name) = try newRecording()
        let recorder = Recorder(dir: dir, name: name)
        try recorder.start()
        print("マイク: \(recorder.micName)\n録音中 →\n\(recorder.paths)\nCtrl+C で停止して保存します")

        await waitForSignal(SIGINT)
        recorder.finish()
        print("\n保存完了")
    }
}
