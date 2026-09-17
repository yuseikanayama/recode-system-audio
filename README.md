# record-audio

Apple Silicon Mac で鳴っている音(ブラウザの Google Meet、電話アプリの通話音声など)を `.m4a` に録音する最小 CLI。
Core Audio のプロセスタップ(macOS 14.2 以降)で全プロセスの出力音声を捕まえるので、
ウィンドウを持たないデーモン経由の音(iPhone 連係の電話、FaceTime)も録音できます。マイクは取得しません。

## ビルド

```sh
xcode-select --install   # Command Line Tools が未導入の場合
make
```

## 使い方

```sh
./record-audio   # data/system-audio-YYYYMMDD-HHmmss.m4a に保存
```

録音中は 1 秒ごとにピーク音量が表示されます。`無音` のままなら音が届いていません。
Ctrl+C で停止し、「保存完了」が表示されたら終了です。

## 権限

初回実行時に「システムオーディオ録音」の許可ダイアログが出ます。
CLI なので許可対象は実行元のターミナルアプリ(Terminal / iTerm2 / VS Code など)になります。
許可した直後の録音は無音になるので、許可後にもう一度実行してください。

手動で設定する場合:
システム設定 > プライバシーとセキュリティ > 画面とシステムオーディオの収録 > システムオーディオ録音のみ
