# record-audio

Apple Silicon Mac のシステム音声(ブラウザの Google Meet 音声など)を `.m4a` に録音する最小 CLI。
ScreenCaptureKit の音声キャプチャだけを使い、マイク・映像は取得しません。

## ビルド

```sh
xcode-select --install   # Command Line Tools が未導入の場合
make
```

## 使い方

```sh
./record-audio                 # ./system-audio-YYYYMMDD-HHmmss.m4a に保存
./record-audio ~/Desktop/meet.m4a
```

Ctrl+C で停止し、「保存完了」が表示されたら終了です。

## 権限

初回実行時に「画面とシステムオーディオの収録」の許可ダイアログが出ます。
CLI なので許可対象は実行元のターミナルアプリ(Terminal / iTerm2 など)になります。
許可後にターミナルを再起動してから再実行してください。

手動で設定する場合:
システム設定 > プライバシーとセキュリティ > 画面とシステムオーディオの収録
