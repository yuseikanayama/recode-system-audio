# record-audio

Apple Silicon Mac で鳴っている音(ブラウザの Google Meet、電話アプリの通話音声など)とマイクの音を、
別々の `.m4a` に録音する最小 CLI。オンライン会議の録音と文字起こし用です。

- システム音声は Core Audio のプロセスタップ(macOS 14.2 以降)で全プロセスの出力を捕まえます。
  ウィンドウを持たないデーモン経由の音(iPhone 連係の電話、FaceTime)も対象です。
- マイクは既定の入力デバイスを同じ集約デバイスで取り込むので、2 つのファイルはサンプル単位で揃います。
- 集約デバイスのクロック源はマイクなので、録音のサンプルレートはマイクに従います
  (AirPods は通話モードの 24 kHz、内蔵マイクは 48 kHz)。システム音声も同じレートで保存されます。

## ビルド

```sh
xcode-select --install   # Command Line Tools が未導入の場合
make
```

## 使い方

```sh
./record-audio   # data/<日時>-system.m4a と data/<日時>-mic.m4a に保存
./play-audio     # data/ の最新の system ファイルを再生(引数でファイル指定も可)
```

録音中は 1 秒ごとにシステム音声とマイクのピーク音量が表示されます。`無音` のままなら音が届いていません。
Ctrl+C で停止し、「保存完了」が表示されたら終了です。

内蔵スピーカーで会議をすると、相手の声がマイク側にも回り込みます。AirPods などのイヤホンを推奨します。

会議や通話を録音するときは、事前に相手の同意を得てください。

## 文字起こし

[OpenAI Whisper](https://github.com/openai/whisper) でローカルに文字起こしします。

```sh
brew install ffmpeg && uv tool install --python 3.12 openai-whisper   # 初回のみ
./transcribe     # data/ の最新の録音を data/<日時>.txt に保存(引数で system ファイル指定も可)
```

system を「相手」、mic を「自分」として別々に文字起こしし、時刻順に 1 つにまとめます。
モデル(turbo、約 1.5 GB)は初回実行時に `~/.cache/whisper` へダウンロードされます。

## リアルタイム文字起こし

録音しながら、[NVIDIA Nemotron 3.5 ASR Streaming](https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b) でその場で文字起こしします。
推論は NVIDIA 公式のローカル実行環境 [NeMo-Speech.cpp](https://github.com/NVIDIA/NeMo-Speech.cpp)(Metal)で行い、音声はこの Mac の外に出ません。

```sh
# 初回のみ: NeMo-Speech.cpp と、NVIDIA 公式の GGUF(約 740 MB)を入れる
curl -fsSL https://github.com/NVIDIA/NeMo-Speech.cpp/raw/main/scripts/install.sh | sh
~/.local/bin/nemo-speech pull nemotron-3.5
make live-transcribe

./live-transcribe   # 録音は record-audio と同じ。文字起こしは data/<日時>-live.txt にも保存
```

system を「相手」、mic を「自分」として認識し、0.8 秒の無音で発話が区切れるたびに 1 行確定します。
画面の一番下には `record-audio` と同じ 1 秒ごとのピーク音量が、その上の行には認識途中の文が表示されます。
遅延は 1 秒ほどです。起動時のモデルの読み込みに 10 秒ほどかかります。
ストリーミング認識は先の文脈を見られないぶん精度が落ちるので、議事録には録音後の `./transcribe` を使ってください。

## 権限

初回実行時に「システムオーディオ録音」と「マイク」の許可ダイアログが出ます。
CLI なので許可対象は実行元のターミナルアプリ(Terminal / iTerm2 / VS Code など)になります。
許可した直後の録音は無音になるので、許可後にもう一度実行してください。

手動で設定する場合:
- システム設定 > プライバシーとセキュリティ > 画面とシステムオーディオの収録 > システムオーディオ録音のみ
- システム設定 > プライバシーとセキュリティ > マイク

## ライセンス

MIT License。詳細は [LICENSE](LICENSE) を参照してください。
