# Download Organizer

Windows の「ダウンロード」フォルダに新しく入ったファイルやフォルダを、種類ごとのフォルダへ自動で移動するツールです。ルールは `config.json` で変えられます。

> **English:** A config-driven Windows Downloads auto-organizer. It watches the Downloads folder, waits until a new file’s size is stable, and moves it into a category folder. It never deletes your files. The only cleanup is empty folders that sit directly in Downloads and are not category folders.

## 必要環境

- Windows 10 / 11
- Windows PowerShell 5.1（標準搭載）
- 管理者権限は不要です

## インストール

リポジトリを展開したフォルダで、次を実行します。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
```

`Install.ps1` は次を行います。

1. スクリプトを `%USERPROFILE%\Scripts\DownloadsSorter` へコピーする
2. `config.example.json` から `config.json` を作り、監視先・ログ・ジャーナルを `$env:USERPROFILE\Downloads` にする
3. カテゴリフォルダをダウンロード直下に作る
4. ログオン時に起動するタスク `DownloadsSorterWatcher` を登録する（タスク登録に失敗したときはスタートアップフォルダのショートカットに切り替える）
5. ウォッチャーを起動する

すでに `config.json` がある場合は上書きしません。ルールを初期状態に戻すときは、そのファイルを消してからもう一度インストールしてください。

## 設定

ウォッチャーが読むのはインストール先の `config.json` です。配布物のひな型は `config.example.json` で、中の `%USERPROFILE%` はインストール時に自分のユーザーフォルダへ置き換わります。UTF-8 で保存してください。

編集するのは主に次の項目です。

1. **categories** … 振り分け先フォルダ名。無いフォルダは起動時に作られます。
2. **ignore** … 無視する名前の接頭辞・パターン・ダウンロード途中の拡張子。
3. **rules** … **上から順に、最初に一致したルールが使われます。**
   - `match`: `"extension"` / `"nameContains"` / `"nameRegex"`
   - `values`: 配列。拡張子は `.zip` のようにドット付きを推奨します。
   - `category`: `categories` にあるフォルダ名
   - 任意: `"dirsOnly": true` / `"filesOnly": true`
4. **defaultCategory** … どれにも一致しなかったときのフォルダ
5. **settings** … サイズ安定待ち、トースト、単一インスタンス用ミューテックス、空フォルダ掃除の間隔など

名前に含まれる言葉で分けるルール（音源、3D プリント、回路、モデルなど）は、拡張子ルールより上に置いてください。そうしないと `.zip` などが先にアーカイブへ入ります。`.lib`、`.bin`、`.net` は別の種類のファイルにも付く拡張子です。不要ならルールから外してください。

保存して数秒待つと、待機中に設定を読み直します。すぐに反映したいときは再起動します。

```powershell
cd "$env:USERPROFILE\Scripts\DownloadsSorter"
.\Restart-Watcher.ps1
```

手で配置する場合は、`config.example.json` を `config.json` としてコピーし、`%USERPROFILE%` を自分のユーザーフォルダ（JSON 内では `\` を `\\` と書く）に置き換えてください。

## 操作

```powershell
cd "$env:USERPROFILE\Scripts\DownloadsSorter"

# 状態（プロセス、ログ末尾、ジャーナル末尾、ログオンタスク）
.\Check-Status.ps1

# 停止 / 開始 / 再起動
.\Stop-Watcher.ps1
.\Start-DownloadsWatcher.ps1
.\Restart-Watcher.ps1

# 直前の移動を戻す（既定は 1 件。同名があっても上書きしない）
.\Undo-Last.ps1
.\Undo-Last.ps1 -Count 3

# いまダウンロード直下にあるものだけ整理して終了
.\Watch-Downloads.ps1 -Once

# ログオン時起動の再登録
.\Register-AutoStart.ps1
```

タスク スケジューラから最小化起動するときは `Start-DownloadsWatcher.cmd` を使います。

## 元に戻す

移動に成功すると、ダウンロード直下の `_downloads_watcher_journal.jsonl` に 1 行ずつ記録します。`Undo-Last.ps1` はその末尾から指定件数を、元の場所へ戻します。戻し先に同名があるときはタイムスタンプを付けて、既存ファイルは残します。戻せた行はジャーナルから取り除きます。

## 安全

- **ファイルは削除しません。** 移動だけです。
- 削除するのは、ダウンロード**直下**にある、カテゴリではない**空フォルダ**だけです。中身があるフォルダ、カテゴリフォルダ、ショートカットや再解析ポイントは残します。サブフォルダの中までは掃除しません。
- 同じ名前が行き先にあるときは、タイムスタンプ付きの名前にして**上書きしません。**
- ダウンロード途中（`.crdownload`、`.partial` など）や、`.` / `_` で始まる名前は無視します。ログとジャーナルもこの接頭辞のため、振り分け対象外です。
- ファイルはサイズが連続して変わらなくなるまで待ってから移動します。待ちきれない場合はスキップして、ファイルは元の場所に残します。
- 名前付きミューテックス `Global\DownloadsSorterWatcher` で、ウォッチャーの二重起動を防ぎます。`-Once` のときだけミューテックスを取りません。
- `settings.toastEnabled` が true のとき、移動後に通知を試みます。BurntToast があればそれを使い、無ければ簡易バルーンです。通知できなくても移動は成功のままです。

ログはダウンロード直下の `_downloads_watcher_log.txt` です。

## 初期カテゴリ

| フォルダ | 目安 |
| --- | --- |
| 01_インストーラー | exe / msi など |
| 02_アーカイブ | zip / 7z など（名前ルールのあと） |
| 03_音源・UST | UST / Vocaloid / SynthV / CeVIO など |
| 04_音声 | wav / mp3 など |
| 05_動画 | mp4 / mkv など |
| 06_3Dプリント | 3mf / stl / gcode / Bambu など |
| 07_ドキュメント | pdf / docx / txt など |
| 08_データ・CSV | csv / json など |
| 09_画像・スクショ | png / jpg など |
| 10_学習・回路 | LTspice / KiCad など |
| 11_ML・モデル | onnx / pt / safetensors など |
| 12_フォント・素材 | フォント / ttf など |
| 99_その他 | どれにも当てはまらないもの |

フォルダ名を増やすときは `categories` に追加し、対応する `rules` を足してください。

## ライセンス

[MIT License](LICENSE)
