# win-desktop-tools

Windows デスクトップ操作まわりの PowerShell スクリプト置き場。

## split-chrome.ps1

2 つの URL を**タブバーもアドレスバーも無い**ウィンドウで開き、画面の左右に並べて、一定間隔で自動リロードする。掲示用ダッシュボードや常時表示モニタ向け。

```powershell
.\split-chrome.ps1 -Left "https://a.example" -Right "https://b.example"
```

| オプション | 既定値 | 説明 |
|---|---|---|
| `-Left` / `-Right` | (必須) | 左右それぞれに表示する URL |
| `-IntervalMinutes` | `30` | 自動リロードの間隔（分） |
| `-CoverTaskbar` | off | タスクバー領域まで使う。Windows 側の「タスクバーを自動的に隠す」と併用する |
| `-Port` | `9223` | DevTools のデバッグポート |
| `-ProfileDir` | `%LOCALAPPDATA%\ChromeDashboard` | 専用 Chrome プロファイルの場所 |

停止は `Ctrl+C`。

デスクトップのショートカットから起動する場合はリンク先を次のようにする。

```
powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\path\to\split-chrome.ps1" -Left "https://a.example" -Right "https://b.example"
```

## reload-now.ps1

`split-chrome.ps1` が開いているページを、間隔を待たずに今すぐリロードする。

```powershell
.\reload-now.ps1                      # 全ページ
.\reload-now.ps1 -Match 'example.com' # URL に部分一致するものだけ
```

## 動作要件

- Windows / Windows PowerShell 5.1 以降
- Google Chrome

## 使う前に知っておくこと

**専用プロファイルで起動する。** DevTools のデバッグポートは起動済みの Chrome に後から付けられないため、`-ProfileDir` に独立したプロファイルを作る。ログインが必要なページは初回だけ手動でログインすれば、以降はプロファイルに残る。普段使いの Chrome とはブックマークも拡張機能も共有しない。

**デバッグポートが開く。** `127.0.0.1` のみのバインドなので外部からは接続できないが、同じ PC 上の他プロセスはこのブラウザを操作できる。スクリプトの実行中だけ開く。

## 実装メモ

素直に書くと動かない箇所があり、いずれも実測して回避している。

**`--window-position` / `--window-size` は当てにできない。** Chrome が既に起動していると新しい起動は既存セッションに委譲され、ジオメトリ指定が捨てられる。そのため起動後に `SetWindowPos` で配置している。

**F5 のキー送信は背面ウィンドウに効かない。** `PostMessage(WM_KEYDOWN, VK_F5)` は前面のウィンドウならリロードできるが、背面では Chromium が無視する。定期リロードをキー送信でやると毎回フォーカスを奪うことになるため、DevTools Protocol の `Page.reload` を使っている。こちらはフォーカス不要で、ページ側の自動更新スクリプトが動いていなくても確実にリロードできる。

**Chrome の翻訳バブルは「本物のウィンドウ」に見える。** クラス名は `Chrome_WidgetWin_1` でタイトルも持つため、新規ウィンドウ検出がバブルを掴んで画面半分に引き伸ばす事故が起きた。オーナーの有無・`WS_CAPTION`・`WS_EX_TOOLWINDOW` で除外している。

**`Invoke-RestMethod` を直接パイプすると JSON 配列が展開されない。** `Object[]` 1 個としてパイプに流れるため `Where-Object` のフィルタが黙って無効化される。いったん変数に代入してからパイプすること。

```powershell
# 誤り: count=1（配列全体が 1 要素として流れる）
@(Invoke-RestMethod $url | Where-Object { $_.type -eq 'page' })

# 正しい: count=2
$response = Invoke-RestMethod $url
@($response | Where-Object { $_.type -eq 'page' })
```

**背面ウィンドウでは JS タイマーが間引かれる。** ページ自身の `setInterval` による自動更新が止まる原因になるため、`--disable-background-timer-throttling` ほか 2 つのフラグを付けて起動している。

## ライセンス

MIT
