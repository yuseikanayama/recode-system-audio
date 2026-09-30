// live-transcribe と live-minutes を裏で動かし、文字起こし・議事録・録音の状態を 1 画面にまとめる TUI(OpenTUI)。
// 実行: ./live-tui [--in-person] [--model nemotron|apple|<model.gguf>]   (引数は live-transcribe にそのまま渡す)
// 停止: q か Ctrl+C。文字起こしを止めて保存を待ち、残りの発言を議事録にまとめてから閉じる
import {
  BoxRenderable,
  createCliRenderer,
  MarkdownRenderable,
  ScrollBoxRenderable,
  SyntaxStyle,
  TextRenderable,
} from "@opentui/core"
import { join } from "node:path"

const root = join(import.meta.dir, "..")
const args = process.argv.slice(2)
const modelAt = args.indexOf("--model")
const model = modelAt < 0 ? "nemotron" : (args[modelAt + 1] ?? "")

// 終了のシグナルは OpenTUI に任せず stop() で受ける(先に画面を壊されると、子プロセスを止める前に落ちるため)
const renderer = await createCliRenderer({ exitOnCtrlC: false, exitSignals: [] })

const transcript = new ScrollBoxRenderable(renderer, { stickyScroll: true, stickyStart: "bottom", flexGrow: 1 })
const partial = new TextRenderable(renderer, { content: "", fg: "#808080", wrapMode: "none", truncate: true })
const left = new BoxRenderable(renderer, { title: " 文字起こし ", border: true, flexGrow: 1, flexDirection: "column" })
left.add(transcript)
left.add(partial)

const minutes = new MarkdownRenderable(renderer, {
  content: "(まだありません)",
  syntaxStyle: SyntaxStyle.fromStyles({
    default: { fg: "#d0d0d0" },
    "markup.heading": { fg: "#7aa2f7", bold: true },
    "markup.list": { fg: "#e0af68" },
    "markup.strong": { bold: true },
  }),
})
const right = new ScrollBoxRenderable(renderer, { title: " 議事録 ", border: true, flexGrow: 1 })
right.add(minutes)

const main = new BoxRenderable(renderer, { flexDirection: "row", flexGrow: 1 })
main.add(left)
main.add(right)
const status = new TextRenderable(renderer, { content: "", wrapMode: "none", truncate: true })
const message = new TextRenderable(renderer, { content: "", fg: "#808080", wrapMode: "none", truncate: true })
const screen = new BoxRenderable(renderer, { width: "100%", height: "100%", flexDirection: "column" })
screen.add(main)
screen.add(status)
screen.add(message)
renderer.root.add(screen)

// 最下部の 2 行。上が録音の状態、下が live-transcribe / live-minutes からの最新のメッセージ。
// 警告やエラーは次のメッセージで上書きされるので、画面を閉じたあとにまとめて出す(無音の警告などを見落とさないため)。
let lastMessage = ""
const notices = new Set<string>()
function say(text: string) {
  lastMessage = text
  message.content = text
  if (/警告|エラー|失敗|停止しました|未送信|終了します/.test(text)) notices.add(text)
}
let recordingSince: number | undefined
let recordingEnded: number | undefined
let levels = ""
let minutesUpdated = ""
let stopping = false
function drawStatus() {
  const rec =
    recordingSince === undefined
      ? "○ 準備中"
      : recordingEnded === undefined
        ? `● REC ${clock((Date.now() - recordingSince) / 1000)}`
        : `■ 停止 ${clock((recordingEnded - recordingSince) / 1000)}`
  const updated = minutesUpdated ? `議事録 ${minutesUpdated} 更新` : "議事録 未作成"
  status.content = [rec, levels, model, updated, stopping ? "停止中…" : "q: 停止"].filter(Boolean).join("  │  ")
}
setInterval(drawStatus, 1000)
drawStatus()

function clock(seconds: number) {
  const s = Math.floor(seconds)
  return [s / 3600, (s % 3600) / 60, s % 60].map((n) => String(Math.floor(n)).padStart(2, "0")).join(":")
}

// 自分はシアン、ほかの参加者は黄色で出す。
let lineCount = 0
function addLine(line: string) {
  const who = line.slice(11, line.indexOf(":", 11))
  const fg = who === "自分" ? "#7dcfff" : "#e0af68"
  transcript.add(new TextRenderable(renderer, { id: `line-${lineCount++}`, content: line, fg }))
}

async function eachLine(stream: ReadableStream<Uint8Array>, onLine: (line: string) => void) {
  const decoder = new TextDecoder()
  let rest = ""
  for await (const chunk of stream) {
    const lines = (rest + decoder.decode(chunk, { stream: true })).split("\n")
    rest = lines.pop()!
    lines.forEach(onLine)
  }
  if (rest) onLine(rest)
}

// 端末でないとき、live-transcribe は確定した行を stdout に、「認識中: 」「音量: 」とそれ以外のメッセージを stderr に出す。
// 子プロセスは端末から切り離し(detached)、端末を閉じても直接は止まらないようにする。止めるのは stop() だけ。
const transcribe = Bun.spawn([join(root, "live-transcribe"), ...args], {
  cwd: root,
  detached: true,
  stdin: "ignore",
  stdout: "pipe",
  stderr: "pipe",
})
let minutesProcess: Bun.Subprocess<"pipe", "ignore", "pipe"> | undefined
let minutesPath = ""

const transcribeOutput = eachLine(transcribe.stdout, (line) => {
  if (/^\[\d\d:\d\d:\d\d\] /.test(line)) addLine(line)
  else if (line.startsWith("録音中")) recordingSince = Date.now()
  else if (line.endsWith("-live.txt")) startMinutes(line)
  else if (line.trim()) say(line)
})
const transcribeErrors = eachLine(transcribe.stderr, (line) => {
  if (line.startsWith("認識中: ")) partial.content = line.slice(5)
  else if (line.startsWith("音量: ")) levels = line
  else if (line.trim()) say(line.trim())
})

// 文字起こしのファイルが決まったら live-minutes に追いかけさせ、書き出された議事録のファイルを読んで表示する。
function startMinutes(transcriptPath: string) {
  minutesPath = transcriptPath.replace(/-live\.txt$/, "-minutes.md")
  minutesProcess = Bun.spawn([join(root, "live-minutes"), transcriptPath], {
    cwd: root,
    detached: true,
    stdin: "pipe", // 何も書かない。TUI が死ぬと閉じられ、live-minutes はそれを合図に終わる
    stdout: "ignore",
    stderr: "pipe",
  })
  void eachLine(minutesProcess.stderr, (line) => {
    if (line.trim()) say(`議事録: ${line.trim()}`)
  })
}

let minutesMtime = 0
setInterval(async () => {
  const file = Bun.file(minutesPath)
  if (!minutesPath || !(await file.exists())) return
  const mtime = file.lastModified
  if (mtime === minutesMtime) return
  minutesMtime = mtime
  minutes.content = await file.text()
  minutesUpdated = new Date(mtime).toTimeString().slice(0, 5)
}, 1000)

// 文字起こしが自分から止まったとき(エラーなど)も、議事録は残りをまとめて終わらせる。画面は q で閉じる。
void Promise.all([transcribe.exited, transcribeOutput, transcribeErrors]).then(([code]) => {
  minutesProcess?.kill("SIGINT")
  recordingEnded = Date.now()
  partial.content = ""
  drawStatus()
  if (!stopping) message.content = `${lastMessage}(live-transcribe が終了コード ${code} で止まりました。q で閉じます)`
})

// 文字起こしを先に止め、最後の行が保存されてから議事録を止める(最後の発言まで議事録に入れるため)。
// q / Ctrl+C のほか、端末を閉じたとき・kill されたとき・TUI が例外で落ちるときもここを通して保存を待つ。
// それでも TUI が先に死んだら、live-transcribe は出力先が閉じたことに気づいて自分で停止・保存する。
async function stop() {
  if (stopping) return
  stopping = true
  transcribe.kill("SIGINT")   // 画面の更新で例外が出ても止め損ねないよう、子プロセスへの指示を先にする
  drawStatus()
  say("文字起こしの保存を待っています…")
  await transcribe.exited
  if (minutesProcess) {
    say("残りの発言を議事録にまとめています…")
    await minutesProcess.exited
  }
  try {
    renderer.destroy()
    for (const notice of notices) console.error(notice)
    console.log(minutesPath ? `保存しました: ${minutesPath.replace(/-minutes\.md$/, "-*")}` : "終了しました")
  } finally {
    process.exit(0)
  }
}

renderer.keyInput.on("keypress", (key) => {
  if (key.name === "q" || (key.ctrl && key.name === "c")) void stop()
})
for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"] as const) process.on(signal, () => void stop())
for (const event of ["uncaughtException", "unhandledRejection"] as const) {
  process.on(event, (error) => {
    notices.add(`TUI のエラー: ${error instanceof Error ? error.message : String(error)}`)
    void stop()
  })
}
