// data/ の録音ファイルを再生する最小 CLI。
//
// ビルド: make
// 実行:   ./play-audio [ファイル.m4a]   (省略時は data/ の最新ファイル)
// 停止:   Ctrl+C

import AVFoundation

@main
struct Main {
    static func main() async throws {
        let url: URL
        if let path = CommandLine.arguments.dropFirst().first {
            url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        } else {
            // ファイル名が日時なので、名前の最大値が最新
            let dir = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("data")
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            guard let latest = names.filter({ $0.hasSuffix(".m4a") }).max() else {
                fputs("data/ に録音ファイルがありません\n", stderr); exit(1)
            }
            url = dir.appendingPathComponent(latest)
        }

        let player = try AVAudioPlayer(contentsOf: url)
        player.play()
        print("再生中 → \(url.path)  (\(Int(player.duration.rounded())) 秒)\nCtrl+C で停止します")
        while player.isPlaying {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        print("再生終了")
    }
}
