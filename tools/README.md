# tools

各スクリプトの使い方と、実装上の注意点。

---

## split-chrome.ps1

2 つの URL を**タブバーもアドレスバーも無い**ウィンドウで開き、画面の左右に並べて、一定間隔で自動リロードする。掲示用ダッシュボードや常時表示モニタ向け。

```powershell
.\split-chrome.ps1 -Left "https://a.example" -Right "https://b.example"
```

### オプション

| オプション | 既定値 | 説明 |
|---|---|---|
| `-Left` / `-Right` | (必須) | 左右それぞれに表示する URL |
| `-IntervalMinutes` | `30` | 自動リロードの間隔（分） |
| `-CoverTaskbar` | off | タスクバー領域まで使う。Windows 側の「タスクバーを自動的に隠す」と併用する |
| `-Port` | `9223` | DevTools のデバッグポート |
| `-ChromeProfile` | 空 | 開くプロファイル（例 `"Profile 1"`）。空なら Chrome が最後に使ったものを開く |
| `-ProfileDir` | 空 | 指定すると専用プロファイルを使う（後述）。空＝いつもの Chrome |
| `-Verbose` | off | 配置とリロードの経過を表示する。既定では何も出さない |

停止は `Ctrl+C`。

### 実行前に Chrome を閉じる必要がある

既定では**いつもの Chrome プロファイル**で開く。ログイン済みの状態なので Gmail などもそのまま表示できる。ただし自動リロードに使う DevTools のデバッグポートは、**すでに起動している Chrome には後から付けられない**（実測: フラグが黙って無視されポートが開かない）。

そのため、実行前に Chrome のウィンドウをすべて閉じておく。閉じ忘れている場合はブラウザを起動せずエラーで止まるので、閉じてから実行し直せばよい。閉じたタブは起動後に `Ctrl+Shift+T` で戻せる。

スクリプトが起動した Chrome は普通の Chrome として使える。別ウィンドウを開いても構わない。

### Chrome を閉じたくない場合

`-ProfileDir` を指定すると独立したプロファイルで起動するので、いつもの Chrome を開いたまま使える。

```powershell
.\split-chrome.ps1 -Left "https://a.example" -Right "https://b.example" -ProfileDir "$env:LOCALAPPDATA\ChromeDashboard"
```

ただしこのプロファイルには**ログイン情報が無い**。Gmail のようなページはサインイン画面や検索結果に飛ぶため、初回だけそのウィンドウでログインする。以降はプロファイルに残る。

### プロファイルの確認方法

`-ChromeProfile` に何を渡すか分からないときは、いつもの Chrome で `chrome://version` を開き「プロフィール パス」の末尾を見る。`...\User Data\Profile 1` なら `-ChromeProfile "Profile 1"`。

### ショートカットから起動する

デスクトップのショートカットのリンク先を次のようにする。ウィンドウを出さずに常駐する。

```
powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\path\to\tools\split-chrome.ps1" -Left "https://a.example" -Right "https://b.example"
```

### 使う前に知っておくこと

**専用プロファイルで起動する。** DevTools のデバッグポートは起動済みの Chrome に後から付けられないため、`-ProfileDir` に独立したプロファイルを作る。ログインが必要なページは初回だけ手動でログインすれば、以降はプロファイルに残る。普段使いの Chrome とはブックマークも拡張機能も共有しない。

**デバッグポートが開く。** `127.0.0.1` のみのバインドなので外部からは接続できないが、同じ PC 上の他プロセスはこのブラウザを操作できる。スクリプトの実行中だけ開く。

---

## reload-now.ps1

`split-chrome.ps1` が開いているページを、間隔を待たずに今すぐリロードする。別のウィンドウから実行する。

```powershell
.\reload-now.ps1                      # 全ページ
.\reload-now.ps1 -Match 'example.com' # URL に部分一致するものだけ
.\reload-now.ps1 -Port 9223           # ポートを変えて起動している場合
```

`split-chrome.ps1` が動いていない（＝デバッグポートが開いていない）ときはエラーで終わる。

---

## auto-reload-extension/

スクリプトを常駐させずに定期リロードしたいとき用の、最小構成の Chrome 拡張。ページ自身がリロードするので、デバッグポートもリロード役のプロセスも要らない。ウィンドウの配置はしないので、左右分割が要るなら `split-chrome.ps1` を使う。

### 設定

`manifest.json` の `matches` を対象 URL に、`reload.js` の `INTERVAL_MINUTES` を間隔に書き換える。

### インストール

**起動オプションでは入れられない**（後述）。プロファイルに 1 回だけ手動で入れる。

```powershell
& "$env:ProgramFiles\Google\Chrome\Application\chrome.exe" --user-data-dir="$env:LOCALAPPDATA\ChromeDashboard"
```

1. 上のように対象プロファイルで Chrome を開く
2. `chrome://extensions` でデベロッパーモードを ON
3. 「パッケージ化されていない拡張機能を読み込む」で `auto-reload-extension` フォルダを選ぶ

以降はこのプロファイルで起動するかぎり有効。

### 実測できていない点

`--load-extension` が塞がれていて自動テストに載せられないため、**手動インストール後の動作は未検証**。`--app` ウィンドウでもコンテンツスクリプトが動くのは Chrome の通常挙動だが、この repo の他の記述と違ってここだけは実測の裏付けが無い。

---

## 実装メモ

素直に書くと動かない箇所があり、いずれも実測して回避している。同じ罠を踏まないための記録。

### `--window-position` / `--window-size` は当てにできない

Chrome が既に起動していると、新しい起動は既存のブラウザセッションに委譲され（"既存のブラウザ セッションで開いています"）、ジオメトリ指定が捨てられる。実測では 2 つとも `X=10 Y=10 W=1050 H=893` に開いた。そのため起動後に `SetWindowPos` で配置している。

### F5 のキー送信は背面ウィンドウに効かない

`PostMessage(WM_KEYDOWN, VK_F5)` は前面のウィンドウならリロードできるが、背面では Chromium が無視する（実測: タイトルのタイムスタンプが変化しない）。定期リロードをキー送信でやると毎回フォーカスを奪うことになるため、DevTools Protocol の `Page.reload` を使っている。フォーカス不要で、ページ側の自動更新スクリプトが動いていなくても確実にリロードできる。

### Chrome の翻訳バブルは「本物のウィンドウ」に見える

「このページを翻訳しますか？」のバブルもクラス名が `Chrome_WidgetWin_1` でタイトルを持つため、新規ウィンドウ検出がバブルを掴んで画面半分に引き伸ばす事故が起きた。次の違いで除外している。

| | owner | WS_CAPTION | WS_EX_TOOLWINDOW |
|---|---|---|---|
| 本物のウィンドウ | 0 | あり | なし |
| 翻訳バブル | 非 0 | なし | あり |

### `Invoke-RestMethod` を直接パイプすると JSON 配列が展開されない

`Object[]` 1 個としてパイプに流れるため、`Where-Object` のフィルタが黙って無効化される。いったん変数に代入してからパイプすること。

```powershell
# 誤り: count=1（配列全体が 1 要素として流れる）
@(Invoke-RestMethod $url | Where-Object { $_.type -eq 'page' })

# 正しい: count=2
$response = Invoke-RestMethod $url
@($response | Where-Object { $_.type -eq 'page' })
```

### 背面ウィンドウでは JS タイマーが間引かれる

ページ自身の `setInterval` による自動更新が止まる原因になる。`--disable-background-timer-throttling` ほか 2 つのフラグを付けて起動している。ページ側の自動更新が効かない場合はこれを疑うとよい。

### `--load-extension` は Stable の Chrome では無視される

拡張機能を起動オプションだけで差し込むことはできない。Chrome 150 での実測結果:

| 確認したこと | 結果 |
|---|---|
| コンテンツスクリプトの実行 | 一度も動かない |
| プロファイルの `Preferences` への登録 | 記録なし（読み込まれてすらいない） |
| デベロッパーモードを事前に ON にして再試行 | 変化なし |

エラーも警告も出さずに黙って無視される。Chrome 137 前後で Stable / Beta では無効化された。そのため拡張機能はプロファイルへ手動で入れておくしかなく、起動から定期リロードまでを完全に自動化したいなら DevTools Protocol 経由（`split-chrome.ps1` の方式）になる。

### ダウンロードした `.ps1` の文字コード

`Invoke-WebRequest -OutFile` はレスポンスをバイト列のまま書き出すので、文字コードの指定は要らない（指定するパラメータも無い）。実測でも raw.githubusercontent.com から取得したファイルはローカルと SHA256 まで一致し、UTF-8 (BOM なし) / LF が保たれた。

注意点が 2 つある。

**パイプで保存しない。** `Invoke-WebRequest ... | Out-File x.ps1` は本文をいったん文字列にしてから書き直すため、Windows PowerShell 5.1 では既定の UTF-16LE で保存されて壊れる。`-OutFile` を使うこと。

**Windows PowerShell 5.1 は BOM 無しのスクリプトを ANSI (CP932) として読む。** 非 ASCII 文字を含む `.ps1` はそれだけで化ける。この repo の `.ps1` は非 ASCII バイトを 1 つも含めないことで回避している（日本語は `README.md` 側に置く）。スクリプトを足すときも、コメントと出力は ASCII に保つこと。
