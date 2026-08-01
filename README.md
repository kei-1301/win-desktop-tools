# win-desktop-tools

Windows のデスクトップ操作まわりで使っている PowerShell スクリプト置き場。別の PC へ持ち出しやすいよう public にしている。

## 収録ツール

| ツール | 概要 |
|---|---|
| [`tools/split-chrome.ps1`](tools/) | 2 つの URL をタブバー無しのウィンドウで左右に並べ、一定間隔で自動リロードする |
| [`tools/reload-now.ps1`](tools/) | 上で開いたページを、間隔を待たずに即座にリロードする |

使い方とオプションは [tools/README.md](tools/README.md) にまとめてある。

## 取得

```powershell
git clone https://github.com/kei-1301/win-desktop-tools.git
```

1 ファイルだけ欲しいとき:

```powershell
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/kei-1301/win-desktop-tools/main/tools/split-chrome.ps1" -OutFile split-chrome.ps1
```

## 動作要件

- Windows / Windows PowerShell 5.1 以降
- ツールによって追加要件あり（Chrome など）。各ツールの説明を参照

## 実行ポリシー

署名していないため、環境によっては実行がブロックされる。その場合はスクリプト単位で許可する。

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\tools\split-chrome.ps1 ...
```

## リポジトリ構成

```
win-desktop-tools/
├── tools/            スクリプト本体と詳細な使い方
└── README.md         このファイル（一覧）
```

## 追加するときのルール

- **public リポジトリなので、社内 URL・ホスト名・認証情報を含めない。** 環境依存の値は引数か環境変数で受け取る
- 文字コードは UTF-8（BOM なし）、改行は LF
- 作業ブランチは `develop`。機能追加は `feature/*` を切って `develop` へマージする

## ライセンス

MIT
