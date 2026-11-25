<p align="center"><img src="docs/assets/readme-icon.png" width="128" alt="3ds2apple アイコン"></p>

<h1 align="center">3ds2apple</h1>

<p align="center">
  <a href="README.md">EN</a> · <a href="README.zh-CN.md">简体中文</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a>
</p>

<p align="center">
  <a href="#ダウンロード"><b>ダウンロード</b></a> ·
  <a href="https://hfykratos.github.io/3ds2apple/">公式サイト</a> ·
  <a href="https://hfykratos.github.io/3ds2apple/press/">プレスキット</a> ·
  <a href="https://github.com/HFYKratos/3ds2apple/releases">リリース</a> ·
  <a href="https://github.com/HFYKratos/3ds2apple/discussions">Discussions</a> ·
  <a href="CONTRIBUTING.md">コントリビュート</a>
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache--2.0-blue" alt="ライセンス: Apache-2.0"></a>
  <a href="https://github.com/HFYKratos/3ds2apple/releases/tag/v0.2.0"><img src="https://img.shields.io/badge/release-v0.2.0-brightgreen" alt="最新リリース: v0.2.0"></a>
  <a href="https://github.com/HFYKratos/3ds2apple/releases/latest"><img src="https://img.shields.io/badge/platforms-iOS%2016%2B%20%C2%B7%20Windows%2010%2F11%20%C2%B7%20macOS%2013%2B-blue" alt="対応プラットフォーム: iOS 16+、Windows 10/11、macOS 13+"></a>
  <a href="https://github.com/HFYKratos/3ds2apple/releases"><img src="https://img.shields.io/github/downloads/HFYKratos/3ds2apple/total?label=downloads" alt="GitHub ダウンロード数"></a>
  <a href="https://github.com/HFYKratos/3ds2apple/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/HFYKratos/3ds2apple/ci.yml?branch=main&label=CI" alt="CI の状態"></a>
</p>

> [!NOTE]
> これはコミュニティ翻訳です。基準となるのは英語版 [README.md](README.md) で、内容が食い違う場合は英語版が優先されます。

**自分で所有する Nintendo 3DS のゲームを iPhone と iPad でネイティブに動作——AOT コンパイルされた ARM64、MoltenVK 経由の Metal、CPU JIT なし、インタプリタのフォールバックなし。**

## ダウンロード

<p align="center">
  <a href="https://github.com/HFYKratos/3ds2apple/releases/download/v0.2.0/3ds2apple-0.2.0-windows-x64.zip"><img src="https://img.shields.io/badge/Download-Windows%20x64-0078D6?style=for-the-badge&logo=windows&logoColor=white" alt="Windows ランチャーをダウンロード"></a>
  <a href="https://github.com/HFYKratos/3ds2apple/releases/download/v0.2.0/3ds2apple-0.2.0-macos-universal.zip"><img src="https://img.shields.io/badge/Download-macOS%20universal-000000?style=for-the-badge&logo=apple&logoColor=white" alt="macOS ランチャーをダウンロード"></a>
  <a href="https://github.com/HFYKratos/3ds2apple/releases"><img src="https://img.shields.io/badge/All%20releases-GitHub-lightgrey?style=for-the-badge&logo=github&logoColor=white" alt="GitHub で全リリースを見る"></a>
</p>

<p align="center"><sub>Windows 10/11 ランチャー（検証済みの経路）· macOS 13+ ランチャー（開発者プレビュー、<a href="https://github.com/HFYKratos/3ds2apple/issues/1">#1</a> を参照）· iOS アプリはランチャーがあなた自身の Apple ID で構成・署名・インストールするため、iOS 単体のダウンロードはありません。</sub></p>

<p align="center">
  <img src="docs/assets/hero.png" width="880" alt="iPhone と iPad で動作する 3ds2apple、および Windows と macOS のランチャー">
</p>

> [!NOTE]
> 3ds2apple は無料のオープンソースソフトウェア（Apache-2.0）です。ランチャーと iOS アプリにはゲーム、キー、BIOS は一切含まれません。自分で所有し自分で吸い出した復号済み ROM から、自分のゲームライブラリを構築してください。

## 30秒でわかる3ds2apple

3ds2apple は、自分で所有する Nintendo 3DS ゲームのためのネイティブ移植パイプラインであり、エミュレーターアプリではありません。自分で吸い出した復号済み ROM を Windows または macOS ランチャーにインポートすると、3dsrecomp が 3DS のコードを C に変換し、ローカルの LLVM または Apple clang ツールチェーンがタイトルごとに 1 つの ARM64 `GamePack` をビルドします。ランチャーは ROM を含まないベース IPA を構成し、あなた自身の Apple ID で署名・インストールしたうえで、ゲームデータ（`GameRom.cci` + `GameInfo.json`）だけをアプリの Documents フォルダーへプッシュします。スマートフォン側では Zakuro HLE ランタイムがそのネイティブコードを直接実行し、MoltenVK が PICA200 GPU の呼び出しを Metal に変換します。1 つのアプリにライブラリ全体が収まり、ポーズメニューから画面レイアウト、コントロール、セーブステート、診断まで扱えます。ゲーム、キー、BIOS は含まれません。ゲームは自分で用意してください。

## デモ

<p align="center">
  <img src="docs/assets/demo.gif" width="720" alt="合成デモのループ：縦画面のコントロール、横画面のコントロール、ポーズメニューのバーチャルコントローラー、画面レイアウト設定">
</p>

<p align="center"><sub>合成プレビュー、ゲームデータなし：縦画面コントロール → 横画面コントロール → ポーズメニューのバーチャルコントローラー → 画面レイアウト設定。</sub></p>

## 0.2.0 の新機能（2026-11-25）

- **刷新された iOS 体験。** 設定は iOS 26/27 のグループ表示になり、ゲーム内メニューは刷新されました：ネイティブの push/pop サブページ、ヘッダーに実行中のゲーム名、電源 / 再起動 / 閉じるボタンのみ、オプションはグループ化して表示。
- **ひと目で読める設定説明。** 各設定の説明は 2 行の平易な文に整理され、タイトルは中央寄せの inline に。分類は General / System / Gamepad / Graphics / Layout / Sound / Debug / Other。
- **グラフィック設定の追加。** 「Screen aspect」（Fit / 4:3 / Stretch）と「Integer scaling」を追加、「Renderer」行は削除。
- **本物の速度制御。** 「Run speed limit」と「Turbo limit」が実際の制限として機能（制限オフで本当に無制限）。「Default speed」/「Turbo speed」は 1x〜4x から選択可能。
- **更新とコントローラー。** GitHub 更新チャンネル（Stable / Beta）と毎日のバックグラウンド確認＋ローカル通知。Gamepad にスティックのデッドゾーン、物理ボタンの完全な再マッピング、2〜4 ボタンのホットキー、Standard / High contrast のコントロール表示、アプリ別 Gamepad プロファイルを追加。
- **アプリ別設定（Per-Application Settings）。** グローバルの既定値を変えずに、タイトルごとに一部の設定だけを上書きできます。
- **未対応：** Delta スキンのインポート、チート、マニュアル、amiibo、マイク、カメラ、ネットワーク/オンラインプレイ、JIT。

## 機能一覧

<table>
  <tr>
    <td align="center" width="25%">⚡<br><b>エミュレーションではなくネイティブ AOT</b><br><sub>各ゲームは実行前に ARM64 へ再コンパイルされます。出荷経路に CPU JIT もインタプリタのフォールバックもありません。</sub></td>
    <td align="center" width="25%">📚<br><b>1 つのアプリにライブラリ全体</b><br><sub>選択した各タイトルは 1 つの署名済みアプリ内の GamePack です。プッシュしたゲームデータは更新後も残ります。</sub></td>
    <td align="center" width="25%">🎮<br><b>New 3DS のコントロールを網羅</b><br><sub>十字キー、A/B/X/Y、L/R、ZL/ZR、Start/Select、本物のアナログ Circle Pad、C スティック。編集可能な早送り、クイックセーブ、クイックロード、画面入れ替えボタン。MFi、Xbox、DualSense コントローラーに対応。</sub></td>
    <td align="center" width="25%">🧭<br><b>横 6 種 + 縦 3 種、すべて GPU</b><br><sub>横 6 種・縦 3 種のプリセットに任意のカスタム矩形を加えたすべてを GPU プレゼンターが毎フレームのリードバックなしで描画。四方向の回転と上下画面の入れ替えにも対応。</sub></td>
  </tr>
  <tr>
    <td align="center" width="25%">✏️<br><b>ゲーム内でコントロールを編集</b><br><sub>ポーズして画面の上でコントロールをドラッグし「完了」をタップ。ボタンごとの表示、10%〜200% のサイズ、透明度に対応。</sub></td>
    <td align="center" width="25%">💾<br><b>セーブとセーブステート</b><br><sub>バッテリーセーブはアプリのコンテナに保存、ゲームごとに 3 つのセーブステートスロット、セーブマネージャーでエクスポートとインポート。</sub></td>
    <td align="center" width="25%">⏩<br><b>早送り、FPS、HUD</b><br><sub>2x 早送りトグル、編集可能なクイックセーブとクイックロード、任意の FPS ピル、システム Metal HUD（デフォルトはオフ）、ワンタップの診断エクスポート。</sub></td>
    <td align="center" width="25%">🖥️<br><b>Windows と macOS のランチャー</b><br><sub>1 つのウィンドウでインポート → コンパイル → 署名 → インストール → プッシュ。Windows 経路なら Mac は不要で、ゲームデータを保つ増分デプロイに対応。</sub></td>
  </tr>
</table>

## 画面レイアウト：横 6 種、縦 3 種

**設定 → ディスプレイ → 画面レイアウト** では、横画面と縦画面を独立して設定できます。

- **横画面レイアウト（6 種）**：大画面 · 単一画面 · 並列画面 · ハイブリッド · オリジナル · カスタムレイアウト。
- **縦画面レイアウト（3 種）**：デフォルト · オリジナル · カスタムレイアウト。

**ハイブリッド**は大きな上画面の横に小さな画面 2 つを上下に並べる構成、縦画面の**デフォルト**は上画面を全幅で下画面の上に置く構成です。

横画面ではピクチャーボックスが上寄せになります：**大画面**・**並列画面**・**ハイブリッド**は画面の上端に密着し（画面上部の黒帯がなくなり）、水平方向は中央のまま、アスペクト比と整数スケーリングも変わりません。

プリセットの配置はすべて GPU プレゼンターが描画します。Metal 経路で毎フレームの画面リードバックはありません。**カスタムレイアウト**は 2 つの画面を任意の矩形に配置します。X/Y/幅/高さをパーセントで編集でき（フィールドの下にライブプレビュー）、画面をドラッグして編集することもできます。カスタムレイアウトも GPU プレゼンターが描画し（任意の矩形、四方向の回転、上下画面の入れ替え）、低速なリードバック経路には戻りません。カスタムレイアウトは引き続き次回のゲーム読み込みから適用されます。

画面の回転とインターフェースの向きは保持され、レンダリング解像度（1x〜4x）は次回のゲーム読み込み時に適用されます。0.1.5 で従来のアスペクト比と整数スケーリングのスイッチは削除されました。

## バーチャルコントローラーとポーズメニュー

画面上のパッドは New 3DS のフルセットです。十字キー、A/B/X/Y、L/R、ZL/ZR、Start/Select、本物のアナログ Circle Pad、New 3DS の C スティックを備えます。Circle Pad は（軸ごとに -1〜1、小さなデッドゾーン付きで指を休めると正確に 0）本物のアナログ値を報告し、2 つ目の十字キーにはなりません。C スティックも同様です。位置とサイズは 2 つの Delta リファレンススキンのジオメトリに基づきます（ジオメトリのみ、アートワークは含みません）：縦画面は **ModernFS**、横画面は **ModernHybrid**。スキンの HOME スロットは **設定** ボタン 1 つで、ゲーム内メニューを開きます（設定ページ本体はメニューの「グローバル設定」行にあります）。スキンの音量キーは実装していません。縦画面では本体のコントロールが画面下の黒い帯に収まり（ショルダー行、その下にメインセット。D-pad は 4 つの独立ボタンではなく 1 つの十字（4 方向の押圧領域、押したままスライドで方向変更）として描画されます）、クイックセーブ／クイックロードはノッチ直下の左右の角（左 LOAD、右 SAVE）にあります。横画面のコントロールのジオメトリは従来どおりで、クイックセーブ／クイックロードは左のノッチ脇（上 SAVE、下 LOAD）にあります。スキンが描かない 5 つのコントロール——ZL、ZR、C スティック、早送り、画面入れ替え——は両方向でデフォルト非表示です。**コントロールの切り替え**で有効にすると、ゲーム画面上部の 1 行（左から ZL、早送り、C スティック、画面入れ替え、ZR）に現れ、レイアウト編集モードで任意の位置へドラッグできます。ゲーム実行中はシステムのステータスバー（時刻・バッテリー・電波）を非表示にします。

ハードウェアコントローラーの左スティックは Circle Pad、右スティックは C スティックに割り当てられ、L2/R2 は ZL/ZR に対応します。複数の指でボタンを押しながらスティックを操作できます。

ポーズしたゲームの **バーチャルコントローラー** カードでパッドをカスタマイズします。

- **パッドの表示/非表示**、FPS 表示、ハプティクス。
- **オンスクリーンボタン**——設定ボタン（ゲーム内メニューを開く）、早送りトグル（2x オン/オフ）、クイックセーブ、クイックロード、画面入れ替え。いずれも本体のコントロールと同じように移動・サイズ変更・表示/非表示ができます。
- **レイアウトを編集**——ポーズ中の画面の上でコントロールをドラッグし、中央の **完了** で現在の向きを保存して再開。
- **コントロールの切り替え**——向きごとの表示設定：ZL、ZR、C スティック、早送り、画面入れ替えは両方向でデフォルト非表示、既定スキンが描くその他のコントロール（縦画面の D-pad と設定ボタンを含む）はデフォルト表示。変更していない 0.2.0、0.2.1-beta1、0.2.1-beta2 の既定表示セットは一度だけ新しい既定へ移行し、ユーザーが変更したセットは保持されます。
- **サイズを調整**——ボタンまたはグループごとに 10%〜200%、デフォルトは 100%（グローバル）。
- **透明度を調整** と **リセット**。

表示は向きごとに設定します（「コントロールの切り替え」は現在の向きを編集）。サイズと透明度はグローバルで、縦画面と横画面の位置はそれぞれ独立しています。C スティックは New 3DS のヌブを読むゲームで、かつ現在のランタイムでビルドされたシェルが必要です（`scripts/build-zakuro-ios.sh` をソースからビルドしたシェルに含まれます）。

## ゲーム内でレイアウトを編集

ゲームをポーズして **バーチャルコントローラー → レイアウトを編集** を開きます。各コントロールには独自のヒット領域があるため、掴んだコントロールだけをポーズ中の画面の上でドラッグでき、中央の **完了** で現在の向きを保存して再開します。同じカードでボタンごとの表示、10%〜200% のサイズ、透明度、**リセット** も扱えます。縦画面と横画面の位置は別々に保存されます。

画面レイアウトは **設定 → ディスプレイ → 画面レイアウト** で別に編集します。パーセントのフィールド（ライブプレビュー付き）か、全画面のドラッグエディター（ドラッグで移動、ピンチでサイズ変更。プレビューは指に追従し、ジェスチャー終了時に確定するためレイアウトが揺れません）を使います。横画面のカスタムレイアウトを編集している間は横画面に固定されます。プリセットは即時適用、カスタム画面レイアウトは次回のゲーム読み込みから適用されます。

## スクリーンショット

**デスクトップランチャー**——実際のアプリのスクリーンショットです。ライブラリの項目は合成のデモ項目で、ゲームの画像は含まれません。

| Windows ランチャー | Windows ランチャー（简体中文） | macOS ランチャー |
|:---:|:---:|:---:|
| <img src="launcher/windows/docs/ui/v4-library-en.png" width="330" alt="Windows ランチャーのライブラリ、英語 UI"> | <img src="launcher/windows/docs/ui/v4-library-zh.png" width="330" alt="Windows ランチャーのライブラリ、中国語 UI"> | <img src="launcher/macos/screenshots/launcher-library-empty-dark-en.png" width="330" alt="macOS ランチャーの空のライブラリ、ダークテーマ"> |
| ライブラリ（English） | ライブラリ（中文） | 空のライブラリ（ダーク） |

**iOS アプリ**——オンスクリーンコントロールの合成プレビューです。ゲームデータは含まれません。

| 縦画面 | 横画面 |
|:---:|:---:|
| <img src="docs/assets/portrait.png" width="280" alt="オンスクリーンコントロール付きの縦画面合成プレビュー"> | <img src="docs/assets/landscape.png" width="520" alt="オンスクリーンコントロール付きの横画面合成プレビュー"> |
| 縦画面コントロール | 横画面コントロール |

## クイックスタート

**必要条件**：自分で所有する復号済み 3DS ROM、開発者モードを有効にした iOS 16+ の iPhone/iPad、USB ケーブル、署名用の自分自身の Apple ID。ゲームデータは含まれません。

1. **ランチャーをダウンロード。** Windows 10/11：zip を書き込み可能なフォルダー（`Program Files` 以外）に展開し、`3ds2apple-launcher.exe` を実行します。USB でスマートフォンに接続できるよう *Apple Devices* をインストールしてください。macOS 13+：`3ds2apple-launcher.app` を展開します（開発者プレビュー。Xcode 15+、`xcodegen`、リポジトリのチェックアウト、ビルド済みツールも必要です）。
2. **インポートしてデプロイ。** 自分で吸い出した復号済みの `.3ds`/`.cci` をインポートし、ゲームを選択して唯一のデプロイボタンを押します。ランチャーはゲームごとに GamePack をコンパイルし、ROM を含まない IPA を構成し、あなた自身の Apple ID で署名・インストールしてから、ゲームデータだけをプッシュします。
3. **プレイ。** スマートフォンでアプリを開きます。ゲームの追加・削除は再デプロイで行い、プッシュしたゲームデータは再インストールや更新後も残ります（完全なアンインストールで消去されます）。

macOS のセットアップと署名の制限を含む詳細な手順は[セットアップ](#セットアップ)にあります。

## FAQ

### 3ds2apple はエミュレーターですか？

いいえ。ネイティブ移植と再コンパイルのパイプラインです。各ゲームは C に変換され、事前に ARM64 へコンパイルされ、Zakuro HLE ランタイムを通して直接実行されます。出荷経路に CPU JIT もインタプリタのフォールバックもありません。

### すべてのゲームが動きますか？

互換性はゲームごとに異なります。起動できないタイトルや描画がおかしくなるタイトルがあり、一部のタイトルの一部メニューが正しく描画されないことがあります（[#2](https://github.com/HFYKratos/3ds2apple/issues/2) で追跡）。互換性や性能の保証はありません。16 桁のタイトル ID を添えた報告を歓迎します。

### ROM、キー、BIOS はどこで入手できますか？

このプロジェクトでは提供しません。3ds2apple はゲームデータを同梱せず、ROM、BIOS、キーのダウンロードや海賊版の支援も行いません。サポート対象は、あなたが合法的に所有し自分で吸い出した復号済み ROM のみです。

### Mac は必要ですか？

検証済みの Windows 経路では不要です。macOS ランチャーは**開発者プレビュー**です。macOS 13+、Apple ID でサインインした Xcode 15+、`xcodegen`、リポジトリのチェックアウト、ビルド済みツールが必要で、実機へのインストールはまだメンテナーによって検証されていません（issue [#1](https://github.com/HFYKratos/3ds2apple/issues/1)）。

### App Store で配信されていますか？

いいえ。ランチャーがあなた自身の Apple ID でアプリを構成・署名し（Windows は同梱の公式 Impactor、macOS は Xcode の自動署名）、USB 経由でインストールします。3ds2apple は Nintendo や Apple と提携しておらず、承認も受けていません。

### 1 週間ほどでアプリが起動しなくなるのはなぜですか？

無料の Apple ID では 1 デバイスあたり 3 アプリ、署名は約 7 日間に制限されます。再デプロイで署名を更新してください。有料の開発者アカウントならこの制限はありません。

### 再デプロイするとセーブやゲームデータは消えますか？

ゲームデータは `Documents/Games/<TITLEID>/`、セーブとセーブステートはアプリのコンテナにあります。プッシュ済みデータとセーブは再インストールや更新後も残り、完全なアンインストールで削除されます。残したいものは事前にバックアップしてください。パソコン上の ROM は影響を受けません。

### 性能はどのくらいですか？

メンテナーが実機 iPhone で Windows ランチャー経路を使い、**ある市販タイトル 1 本**を計測したところ約 57〜60 fps、AOT 100%、Metal GPU レンダラーでした。これはその 1 本の計測結果であり保証ではありません。互換性と性能はゲームごとに異なります。

### カスタム画面レイアウトはプリセットより遅いですか？

いいえ、もう遅くありません。0.1.6 からカスタムレイアウトも GPU プレゼンターが描画します（任意の矩形、四方向の回転、上下画面の入れ替え）。プリセットと同じ、毎フレームのリードバックがない Metal 経路のままです。カスタムレイアウトは引き続き次回のゲーム読み込みから適用されます。

## 法的情報と制限

- **ゲームは自分で用意。** ROM、キー、BIOS、システムファイル、ゲームアセットは提供もリンクもしません。海賊版の支援もありません。合法的に所有し自分で吸い出した復号済み ROM のみを使用してください。
- **提携・承認はありません。** 3ds2apple は Nintendo や Apple と提携しておらず、スポンサーや承認も受けていません。App Store でも配信されません。あなた自身の Apple ID で署名してインストールします。
- **保証はありません。** 互換性と性能はゲームごとに異なります。起動できないタイトルや描画がおかしいタイトルがあり、一部のタイトルの一部メニューが正しく描画されないことがあります（issue [#2](https://github.com/HFYKratos/3ds2apple/issues/2)）。互換性や性能の保証はありません。
- **macOS は開発者プレビュー。** パッケージは自己完結しておらず、実機へのインストールもまだメンテナーによって検証されていません（issue [#1](https://github.com/HFYKratos/3ds2apple/issues/1)）。Windows が検証済みの経路です。
- **カスタム画面レイアウトは 0.1.6 から GPU 経路です。** 任意の矩形、四方向の回転、上下画面の入れ替えを GPU プレゼンターが描画します（0.1.5 以前は低速なリードバック経路でした）。適用は引き続き次回のゲーム読み込みからです。
- **設計上 CPU JIT はありません。** 出荷経路は AOT コードと Zakuro HLE ランタイムで、インタプリタのフォールバックはありません。

## プロジェクトリンク

| | |
|---|---|
| **公式サイト** | <https://hfykratos.github.io/3ds2apple/> |
| **プレスキット** | <https://hfykratos.github.io/3ds2apple/press/> |
| **ダウンロード** | [GitHub Releases](https://github.com/HFYKratos/3ds2apple/releases) |
| **Issues** | <https://github.com/HFYKratos/3ds2apple/issues> |
| **Discussions** | <https://github.com/HFYKratos/3ds2apple/discussions> |
| **コントリビュート** | [CONTRIBUTING.md](CONTRIBUTING.md) |
| **ライセンス** | [Apache-2.0](LICENSE) |

## 対応プラットフォーム

| プラットフォーム | サポート |
|---|---|
| **iPhone / iPad** | iOS 16 以降。1 つのアプリにライブラリ、刷新されたゲーム内メニュー、ゲーム内レイアウト編集付きの New 3DS フルコントロール、横 6 種/縦 3 種の画面レイアウト、セーブステート、FPS 表示、アプリ別設定が入ります。 |
| **Windows** | Windows 10/11 x64。自己完結の単一ファイルランチャー。Mac なしでビルド、署名、インストール、プッシュができます。**検証済みの経路。** |
| **macOS** | macOS 13+（Intel + Apple シリコン）。Xcode 署名を使う SwiftUI ランチャー。パッケージはまだ自己完結しておらず、実機へのインストールはメンテナーによって検証されていません。**開発者プレビュー。** |
| **ビルドホスト** | Windows（同梱の LLVM/LLD）または macOS（Apple clang + Xcode）。 |

## セットアップ

**必要条件**：自分で所有する復号済み 3DS ROM、開発者モードを有効にした iOS 16+ の iPhone/iPad、USB ケーブル、署名用の自分自身の Apple ID。ゲームデータは含まれません。

### Windows ランチャー

1. `3ds2apple-<version>-windows-x64.zip` をダウンロードし、書き込み可能なフォルダー（`Program Files` 以外）に展開します。USB でスマートフォンに接続できるよう *Apple Devices* をインストールしてください。
2. `3ds2apple-launcher.exe` を実行します（コード署名なし。ダイジェストを確認し、*詳細情報 → 実行* を選びます）。設定 → セルフテストを一度実行し、緑になることを確認してください。
3. **ライブラリ → インポート**で、自分で吸い出した復号済みの `.3ds`/`.cci` を読み込みます。読み取るのは ROM ヘッダーと SMDH のアイコン/メタデータのみです。
4. **デプロイ**：ゲームを選択して唯一のデプロイボタンを押します。ランチャーはゲームごとに GamePack をコンパイルし、ROM を含まない IPA を構成し、同梱の Impactor（自分自身の Apple ID でサインイン）で署名・インストールしてから、ゲームデータだけをプッシュします。ランチャーはまずスマートフォンの状態を確認します。インストール済みのアプリと選択したゲームが最新ならデプロイを完全にスキップし、上書き更新ではゲームデータ、セーブ、ROM を保持します。ローカルライブラリにないゲームがスマートフォンにある場合は一覧を示して更新前に確認し、決して削除しません。
5. スマートフォンでアプリを開いてプレイします。ゲームの追加・削除は再デプロイで行い、プッシュ済みデータは再インストール後も残ります（完全なアンインストールで消去されます）。

### macOS ランチャー

1. `3ds2apple-<version>-macos-universal.zip` をダウンロードすると `3ds2apple-launcher.app` が得られます（公証なし。初回起動時は右クリック → *開く*）。
2. パッケージは**まだ自己完結していません**。macOS 13+、Apple ID でサインインした Xcode 15+、`xcodegen`、リポジトリのチェックアウト、ビルド済みツール（`scripts/build-zakuro-ios.sh`、`builder` の pack CLI、`tools/devpush`）が必要です。ランチャーは自身のバンドル、チェックアウト、`PATH` を探します。
3. インポート → デプロイ：Apple clang が GamePack をコンパイルし、Xcode の自動署名 + `devicectl` が構成済み IPA をインストールし、続いてゲームデータをプッシュします。選択ルールは Windows と同じです。

### スマートフォン上のデータ、セーブ、制限

- ゲームデータは `Documents/Games/<TITLEID>/` にあります（ファイル App で表示可能）。セーブとセーブステートはアプリのコンテナにあります。
- オンスクリーンコントロールはポーズメニューの **バーチャルコントローラー → レイアウトを編集** で編集します（ポーズ中の画面の上でドラッグし、**完了** をタップ）。画面レイアウトは **設定 → ディスプレイ → 画面レイアウト** にあります。プリセットは即時適用、カスタム画面レイアウトは次回のゲーム読み込みから適用されます。
- 無料の Apple ID では 1 デバイスあたり 3 アプリ、署名は約 7 日間に制限されます。再デプロイで更新してください。有料の開発者アカウントならこの制限はありません。
- アプリをアンインストールするとそのデータは削除されます。パソコン上の ROM は影響を受けません。

## ダウンロードパッケージとポリシー

公開ビルドは [GitHub Releases](https://github.com/HFYKratos/3ds2apple/releases) で公開されます。各リリースにはプラットフォームパッケージがちょうど 2 つ含まれます。

- `3ds2apple-<version>-windows-x64.zip` —— Windows 10/11 ランチャー：自己完結の `3ds2apple-launcher.exe` と `LICENSE`、`NOTICE`、`THIRD_PARTY.md`。
- `3ds2apple-<version>-macos-universal.zip` —— macOS 13+ ランチャー：`3ds2apple-launcher.app`（Intel + Apple シリコン）と `LICENSE`、`NOTICE`、`THIRD_PARTY.md`。

0.1.1 以降、両方の zip のルートにこれら 3 つのライセンス文書がリポジトリ内のコピーとバイト単位で一致する形で含まれるため、ダウンロードしたパッケージは自己完結しています。これらは個別のリリースアセットとしては公開されず、[THIRD_PARTY.md](THIRD_PARTY.md) に記載された GPL プロジェクトは読み取り専用の参照のままで、GPL のコードや文書は一切パッケージされません。0.1.0 のパッケージはこれより前のもので、リポジトリ内のコピーに依存します。ROM を含まないシェルテンプレートは両方のランチャーに埋め込まれており、個別のダウンロードにはなりません。GitHub は各リリースアセットの SHA-256 ダイジェストを表示します。ゲームデータが添付されることはありません。

## ソースからビルド

| コンポーネント | ビルド / テスト |
|---|---|
| Windows ランチャー | `cd launcher/windows && dotnet build Launcher.slnx -c Release` / `dotnet test Launcher.slnx -c Debug` —— [launcher/windows/README.md](launcher/windows/README.md) を参照 |
| macOS ランチャー | macOS で XcodeGen + `xcodebuild` —— [launcher/macos/README.md](launcher/macos/README.md) を参照 |
| iOS アプリ / シェル | `scripts/build-zakuro-ios.sh` → `scripts/build-ios-app.sh` → `scripts/package-ipa.sh` —— [scripts/README.md](scripts/README.md) を参照 |
| Pack CLI（`3ds2apple-pack`） | `cd builder && cargo build --workspace` / `cargo test --workspace` —— [builder/README.md](builder/README.md) を参照 |
| デバイスブリッジ（`devpush`） | `cargo build --release --manifest-path tools/devpush/Cargo.toml` —— [tools/devpush/README.md](tools/devpush/README.md) を参照 |

ホスト側のセルフチェックは ROM、スマートフォン、Xcode を必要としません。

```bash
cd builder && cargo test --workspace
cd launcher/windows && dotnet test Launcher.slnx -c Debug
bash scripts/tests/perf-selfcheck.sh
bash scripts/tests/aot-selfcheck.sh
bash scripts/tests/game-catalog-selfcheck.sh
bash scripts/tests/desktop-aot-selfcheck.sh
```

## 内部の仕組み

### エミュレーターではなくネイティブ移植

各ゲームは事前に再コンパイルされます。3DS のコードは 3dsrecomp によって C に変換され、ローカルの LLVM または Apple clang ツールチェーンで ARM64 の `GamePack` にビルドされます。スマートフォンは Zakuro HLE ランタイムを通してそのネイティブコードを直接実行します。CPU JIT もインタプリタのフォールバックもありません。PICA200 GPU 経路は MoltenVK によって Metal に変換され、GPU プレゼンターがすべての画面レイアウト（プリセットとカスタム矩形）を `CAMetalLayer` に直接描画します（毎フレームの画面リードバックはありません）。

### 1 つのアプリにライブラリ全体

選択した各ゲームは独自の `GamePack<TITLEID>.dylib` にコンパイルされ、`GameCatalog.json` とともに 1 つの署名済みアプリへ構成されます。1 つのアプリをインストールすればライブラリ全体が付いてきます。ゲームの追加・削除は再デプロイで行い、プッシュしたゲームデータは再インストールや更新後も残ります。ゲームごとのコードは署名済み IPA の中に置く必要があります。iOS は `Documents` から未署名のコードを読み込まないためです。

ライブラリカードは、ランチャーがインポート時に ROM から読み取った情報だけから作られます。ゲーム自身の SMDH アイコン、アプリの言語でのタイトル、パブリッシャー、プッシュしたゲームサイズです。ランチャーはそのメタデータを `GameInfo.json` に入れてゲームデータと一緒にプッシュするため、スマートフォンが ROM を解析することはありません。古いランチャーがプッシュしたライブラリもそのまま使えます。カードはカタログ名にフォールバックし、パブリッシャー行を隠し、プレースホルダーのアイコンを表示します。再デプロイすれば完全な表示に戻ります。

### ほぼ設定不要のグラフィカルランチャー

Windows 用と macOS 用のランチャーがあります。自分で吸い出した復号済みの `.3ds`/`.cci` をインポートし、ゲームを選んで唯一のデプロイボタンを押すだけです。ランチャーは GamePack をコンパイルし、ROM を含まないベース IPA を構成し、あなた自身の Apple ID で署名・インストールし（Windows は同梱の公式 Impactor/plumesign、macOS は Xcode の自動署名）、`GameRom.cci` + `GameInfo.json` だけをアプリの Documents フォルダーへプッシュします。

ランチャーは実行ファイル/.app の隣にポータブルなデータフォルダーを保持し、ROM の SMDH メタデータ（アイコン、ローカライズされた名前、パブリッシャー）を読み取り、ビルド用ハードウェアを検出して 3dsrecomp を自動的に並列化します。さらに起動時のレディネスランプとセルフテストを表示するため、ツールの不足がデプロイ中に静かに失敗することはありません。Windows のデプロイはデバイスを認識します。インストール済みのアプリとゲームを先に読み取り、最新ならスキップし、上書き更新ではゲームデータとセーブを保持します。ローカルライブラリにないゲームがスマートフォンにある場合は一覧を示して更新前に確認し、そのデータを削除することはありません。

### プレイ中にスマートフォンが表示するもの

画面はフルブリードです。タイトルバー、カードの枠、ゲーム名はありません。ゲーム実行中はシステムのステータスバー（時刻・バッテリー・電波）を非表示にします。アプリ自身のゲームビュー上のオーバーレイは、**FPS ピル**（デフォルトで有効、画面の上部に浮かぶ——縦画面ではノッチ直下の中央、横画面では右上のセーフエリア）と、オンスクリーンコントロール（スキンの HOME スロットは **設定** ボタンで、ゲーム内メニューを開きます。このコントロールを非表示にしたときだけ、代替として浮遊ポーズボタンが出ます）だけです。FPS ピルはポーズメニューの **バーチャルコントローラー** カードでオフにできます。それ以外はゲームビューの外に保たれます。AOT の状態、レンダラーの経路、Metal HUD の状態、フェーズごとのフレーム時間はデバイスログと診断レポートに記録されます（「情報」ページは診断用にランタイムの概要を繰り返しますが、ゲームの上には何も描画しません）。

設定ページには以前の「Metal backend」情報行と初回読み込み時のグラフィックスのウォームアップスイッチがなくなりました。ゲームは読み込みが終わるとすぐに表示され、ランタイムのパイプラインキャッシュは同じタイトルの次回以降の読み込みをウォームにします。Apple 独自のシステム Metal HUD スイッチ（GPU/FPS オーバーレイ）は 0.1.6 からデフォルトでオフで、設定 → パフォーマンス にあります。

### 実測値

メンテナーが実機 iPhone で Windows ランチャー経路を使い、**ある市販タイトル 1 本**を計測した結果は約 **57〜60 fps**、**AOT 100%**、**Metal GPU** レンダラーでした。`zk_perf` は 1 フレームあたり GPU 4〜6 ms、present 10〜11 ms、画面リードバック 0 を報告します。これはメンテナーがその 1 本を計測した値です。互換性と性能はゲームごとに異なり、保証されません。

## リポジトリ構成

```text
assets/            この README で使うアプリアイコン
.github/           問題報告とプルリクエストのテンプレート
ios/app/           iOS アプリ：ライブラリ、ゲーム内メニュー、タッチコントロール、セーブステート
ios/zakuro-ios/    Zakuro iOS C ABI：GamePack ローダー、Metal プレゼンター、パフォーマンスカウンター
launcher/windows/  Windows ランチャー（C#/Avalonia）、単一ファイルパッケージング
launcher/macos/    macOS ランチャー（SwiftUI）、Xcode 署名とインストール
builder/           3ds2apple-pack：ROM インポート、SMDH メタデータ、パッケージ、GameCatalog
tools/devpush/     デバイスブリッジ：usbmuxd/house_arrest/AFC プッシュ、インストール検証
tools/winbuild/    Apple SDK 不要の LLVM/LLD GamePack クロスビルドツール
scripts/           ビルド、パッケージ、リリース、セルフチェックのスクリプト
licenses/          サードパーティのライセンス文書（Impactor MIT、apple-codesign MPL-2.0）
```

## 正直な限界

- **互換性はゲームごと。** 起動できないタイトルや描画がおかしくなるタイトルがあり、一部のタイトルの一部メニューが正しく描画されないことがあります（issue [#2](https://github.com/HFYKratos/3ds2apple/issues/2)）。タイトル ID を添えた報告を歓迎します——[問題報告とパフォーマンスデータ](#問題報告とパフォーマンスデータ)を参照。
- **カスタム画面レイアウトは 0.1.6 から GPU 経路です。** 任意の矩形、四方向の回転、上下画面の入れ替えを GPU プレゼンターが描画します。0.1.5 以前は画面リードバック経路でした。適用は引き続き次回のゲーム読み込みからです。
- **C スティックはゲームに依存。** New 3DS のヌブ API を通して報告されるため、ヌブを読まないタイトルは無視します。古いランタイムでビルドされたシェルでは利用できません。
- **中国本土の iPhone では、最初のテキスト入力時に「モバイルデータ通信」を尋ねられることがあります。** これは iOS の既知の癖です。システムのテキスト入力が最初に表示されたとき（たとえばゲーム内キーボードのオーバーレイ）、UIKit 自身のディクテーション/ネットワーク経路のチェックがアプリに帰属され、iOS が「モバイルデータ通信を許可」のアラートを表示します。3ds2apple はネットワーク要求を一切行わず、モバイルデータ通信の使用量は 0 のままです。*許可しない* または *Wi-Fi のみ* を選んでもすべて動作します（再インストールで再度表示されることがあります）。詳細は [ios/app/README.md](ios/app/README.md)。
- **古いインストールと古いプッシュも動作。** `GameInfo.json` は任意フィールドを追加しただけ（スキーマバージョンは 1 のまま）なので、0.1.0 のランチャーがプッシュしたゲームデータも検証に通り、動作します。再デプロイするまでカードにはパブリッシャー、実際の SMDH アイコン、サイズがありません。0.1.0 から更新したアプリはライブラリとセーブを保持します。
- **macOS パッケージは開発者プレビュー。** 自己完結しておらず、実機へのインストールもまだメンテナーによって検証されていません。実機受け入れの募集は [#1](https://github.com/HFYKratos/3ds2apple/issues/1) で追跡しています。Windows パッケージが検証済みの経路です。
- **ROM、キー、BIOS は提供しません。** サポート対象は自分で所有する復号済み ROM のみです。
- **設計上 CPU JIT はありません。** 出荷経路は AOT コードと Zakuro HLE ランタイムで、インタプリタのフォールバックはありません。

## 問題報告とパフォーマンスデータ

バグ報告と互換性報告を歓迎します。まず[互換性報告フォーム](.github/ISSUE_TEMPLATE/compatibility-report.yml)から始めてください（GitHub の **New issue** に用意されています）。ゲーム名、16 桁のタイトル ID、リージョンとバージョン（base/update/DLC）、デバイスモデルと iOS バージョン、使用した 3ds2apple のバージョンまたはコミット、AOT の状態、何が起きるか、再現手順を求められます。ROM、復号キー、BIOS/ファームウェア、生成された C、ゲームの画像を含むスクリーンショットや録画、署名済み IPA、Apple の資格情報、デバイスの UDID は決して添付しないでください。

各ビルドは診断レポートをエクスポートできます。ゲーム内メニューを開いて **Export logs / ログを書き出す** を押し（メニューはフレームループを停止するため、押した瞬間にスタッターカウンターが止まります）、システムの共有シートで `.txt` を共有します。ホーム画面の **設定 → その他 → ログを書き出す** からもエクスポートできますが、ゲームをアンロードするとフレームとスタッターのカウンターがリセットされます。これらの数値が重要なときはゲーム内メニューを使ってください（設定側のコピーにも完全なセッションログは含まれます）。0.1.1 以降のビルドでは、エクスポートのたびにアプリコンテナの `Documents/Diagnostics/<timestamp>.txt` に書き出され（最新 5 件を保持）、同じフォルダーがファイル App の **この iPhone 内 → 3ds2apple → Diagnostics** に表示されます。デバイスブリッジで USB 経由で取得することもできます。

```bash
devpush ls  --bundle-id com.kratos.3ds2apple --remote Documents/Diagnostics
devpush get --bundle-id com.kratos.3ds2apple --remote Documents/Diagnostics/<timestamp>.txt --local diagnostics.txt
```

レポートにはビルドとデバイスの状態、AOT の証明（`aot_percent`、`aot_fallbacks`）、レンダラーの経路、フレームキャップ/早送り/レンダースケールの設定、フェーズごとのフレーム時間、両方のアプリログが含まれます。0.1.1 以降ではスタッター（`>33.3 ms` のフレーム）と深刻なスタッター（`>100 ms`）の回数、毎分の発生率、最悪フレーム、フェーズごとの帰属、直近 20 件のスパイクも記録されます。スタッターの報告（「おおむね 57〜60 fps だが時々引っかかる」など）では、いつどこで起きるか（タイトル + シーン/メニュー）、2 回目の実行で改善するか、使用したランチャー経路と設定も添えてください。**診断ファイルを添付してください**。カウンターとスパイクが測定データそのものであり、ファイルのないスタッター報告は通常、添付を求められるだけです。

Mac と iPhone/iPad を持つテスターは特に歓迎します。[macOS 実機受け入れフォーム](.github/ISSUE_TEMPLATE/macos-acceptance.yml)は [launcher/macos/README.md](launcher/macos/README.md#real-device-acceptance) のチェックリスト（Xcode 署名、`devicectl` インストール、`devpush` プッシュ）を順に確認し、結果を記録します。

## コントリビュートとリリース

- [CONTRIBUTING.md](CONTRIBUTING.md) —— コントリビューションのルール、問題報告、リリースポリシー。
- [Issue テンプレート](.github/ISSUE_TEMPLATE) —— 互換性レポートと macOS 実機受け入れチェックリスト。
- [LICENSE](LICENSE) —— Apache-2.0。
- [THIRD_PARTY.md](THIRD_PARTY.md) と [NOTICE](NOTICE) —— サードパーティコンポーネントと法的通知。

## 謝辞

3ds2apple はオープンソースの成果の上に立っています。**Zakuro**（MIT、HLE ランタイムと PICA200 レンダラー）、**3dsrecomp**（MIT、静的リコンパイラー）、**MoltenVK**（Apache-2.0、Metal 上の Vulkan）、**Impactor**（MIT）と **apple-codesign**（MPL-2.0、Windows からの署名）、**pocket-native**（MIT、iOS ネイティブ移植の参考）、そして LLVM プロジェクトのコンパイルツールチェーンに感謝します。実機でビルドをテストしてくれたすべての人にも感謝します。

## ライセンスと法的情報

3ds2apple は **Apache-2.0** でライセンスされています（[LICENSE](LICENSE) を参照）。Nintendo の ROM、復号キー、BIOS、システムファイル、ゲームアセット、ゲームプレイのスクリーンショットは同梱せず、ROM のダウンロードや海賊版の支援も提供しません。合法的に所有し自分で吸い出したゲームのみを使用してください。3ds2apple は Nintendo や Apple と提携しておらず、スポンサーや承認も受けていません。

サードパーティのコンポーネントとライセンスは [THIRD_PARTY.md](THIRD_PARTY.md) と [NOTICE](NOTICE) に記載されています。Windows ランチャーは公式 Impactor v2.7.3 + plumesign のリリースファイルを未改変で同梱し（MIT。埋め込まれた apple-codesign 0.29.0 は MPL-2.0）、ライセンス文書を [licenses/impactor](licenses/impactor) に保持しています。macOS ランチャーは代わりに Xcode で署名し、Impactor を同梱しません。iOS シェルテンプレートと macOS ランチャーは未改変の MoltenVK 1.4.2 フレームワーク（Apache-2.0）を埋め込んでいます。GPL プロジェクトはアーキテクチャの参考として読むだけで、GPL のコードや文書をこのリポジトリへコピーしたり、パッケージに含めたりすることはありません。
