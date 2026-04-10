// AlphaBIOS.swift - C-BIOS をベースにパッチを適用したカスタム BIOS
// α-BIOS: 高速ブート・ロゴ ROM 不要・MSX2/MSX2+ スタブ・ブランディング変更
//
// MAIN ROM エントリポイント一覧 (Appendix A.1 BIOS 一覧 準拠)
// ────────────────────────────────────────────────────────
// 0000H CHKRAM   MSX1   RAM チェック           ✅ C-BIOS
// 0008H SYNCHR   MSX1   文字同期化             ✅ C-BIOS
// 000CH RDSLT    MSX1   スロット読み込み       ✅ C-BIOS
// 0010H CHRGTR   MSX1   文字取得               ✅ C-BIOS
// 0014H WRSLT    MSX1   スロット書き込み       ✅ C-BIOS
// 0018H OUTDO    MSX1   出力処理               ✅ C-BIOS
// 001CH CALSLT   MSX1   他スロット呼び出し     ✅ C-BIOS
// 0020H DCOMPR   MSX1   HL/DE 比較             ✅ C-BIOS
// 0024H ENASLT   MSX1   スロット有効化         ✅ C-BIOS
// 0028H GETYPR   MSX1   DAC 型判定             ✅ C-BIOS
// 002EH CALLF    MSX1   別スロット呼び出し     ✅ C-BIOS (NOP×2→JP)
// 0030H (RST30)  MSX1   CALLF link             ✅ C-BIOS
// 0038H KEYINT   MSX1   キー割り込み           ✅ C-BIOS
// 003BH INITIO   MSX1   デバイス初期化         ✅ C-BIOS
// 003EH INIFNK   MSX1   ファンクションキー初期化 ✅ C-BIOS
// 0041H DISSCR   MSX1   画面非表示             ✅ C-BIOS
// 0044H ENASCR   MSX1   画面表示               ✅ C-BIOS
// 0047H WRTVDP   MSX1   VDP レジスタ書き込み   ✅ C-BIOS
// 004AH RDVRM    MSX1   VRAM 読み込み          ✅ C-BIOS
// 004DH WRTVRM   MSX1   VRAM 書き込み          ✅ C-BIOS
// 0050H SETRD    MSX1   VRAM 読みアドレス設定  ✅ C-BIOS
// 0053H SETWRT   MSX1   VRAM 書きアドレス設定  ✅ C-BIOS
// 0056H FILVRM   MSX1   VRAM 領域塗りつぶし    ✅ C-BIOS
// 0059H LDIRMV   MSX1   VRAM→RAM 転送          ✅ C-BIOS
// 005CH LDIRVM   MSX1   RAM→VRAM 転送          ✅ C-BIOS
// 005FH CHGMOD   MSX1   スクリーンモード変更   ✅ C-BIOS
// 0062H CHGCLR   MSX1   色設定                 ✅ C-BIOS
// 0066H NMI      MSX1   非マスカブル割り込み   ✅ C-BIOS
// 0069H CLRSPR   MSX1   スプライト初期化       ✅ C-BIOS
// 006CH INITXT   MSX1   TEXT1 モード初期化     ✅ C-BIOS
// 006FH INIT32   MSX1   TEXT2 モード初期化     ✅ C-BIOS
// 0072H INIGRP   MSX1   GRAPHIC1 初期化        ✅ C-BIOS
// 0075H INIMLT   MSX1   MULTI COLOR 初期化     ✅ C-BIOS
// 0078H SETTXT   MSX1   TEXT1 モード設定       ✅ C-BIOS
// 007BH SETT32   MSX1   TEXT2 モード設定       ✅ C-BIOS
// 007EH SETGRP   MSX1   GRAPHIC1 モード設定    ✅ C-BIOS
// 0081H SETMLT   MSX1   MULTI COLOR 設定       ✅ C-BIOS
// 0084H CALPAT   MSX1   スプライトパターン計算 ✅ C-BIOS
// 0087H CALATR   MSX1   スプライト属性計算     ✅ C-BIOS
// 008AH GSPSIZ   MSX1   スプライトサイズ取得   ✅ C-BIOS
// 008DH GRPPRT   MSX1   グラフィック文字表示   ✅ C-BIOS
// 0090H GICINI   MSX1   PSG 初期化             ✅ C-BIOS
// 0093H WRTPSG   MSX1   PSG レジスタ書き込み   ✅ C-BIOS
// 0096H RDPSG    MSX1   PSG レジスタ読み込み   ✅ C-BIOS
// 0099H STRTMS   MSX1   音声バッファ処理開始   ✅ C-BIOS
// 009CH CHSNS    MSX1   キーバッファ確認       ✅ C-BIOS
// 009FH CHGET    MSX1   文字入力               ✅ C-BIOS
// 00A2H CHPUT    MSX1   文字出力               ✅ C-BIOS
// 00A5H LPTOUT   MSX1   プリンタ出力           ✅ C-BIOS
// 00A8H LPTSTT   MSX1   プリンタ状態           ✅ C-BIOS
// 00ABH CNVCHR   MSX1   文字変換               ✅ C-BIOS
// 00AEH PINLIN   MSX1   行入力                 ✅ C-BIOS
// 00B1H INLIN    MSX1   BASIC 行入力           ✅ C-BIOS
// 00B4H QINLIN   MSX1   プロンプト付き入力     ✅ C-BIOS
// 00B7H BREAKX   MSX1   BREAK 検査             ✅ C-BIOS
// 00BAH ISCNTC   MSX1   CTRL+STOP 検査         ✅ C-BIOS
// 00BDH CKCNTC   MSX1   CTRL+STOP 直接検査     ✅ C-BIOS
// 00C0H BEEP     MSX1   ビープ音               ✅ C-BIOS
// 00C3H CLS      MSX1   画面クリア             ✅ C-BIOS
// 00C6H POSIT    MSX1   カーソル移動           ✅ C-BIOS
// 00C9H FNKSB    MSX1   ファンクションキー表示 ✅ C-BIOS
// 00CCH ERAFNK   MSX1   ファンクションキー消去 ✅ C-BIOS
// 00CFH DSPFNK   MSX1   ファンクションキー表示 ✅ C-BIOS
// 00D2H TOTEXT   MSX1   テキストモード移行     ✅ C-BIOS
// 00D5H GTSTCK   MSX1   ジョイスティック入力   ✅ C-BIOS
// 00D8H GTTRIG   MSX1   トリガボタン検査       ✅ C-BIOS
// 00DBH GTPAD    MSX1   パッド入力             ✅ C-BIOS
// 00DEH GTPDL    MSX1   パドル入力             ✅ C-BIOS
// 00E1H TAPION   MSX1   テープ読み込み開始     ✅ C-BIOS
// 00E4H TAPIN    MSX1   テープデータ読み込み   ✅ C-BIOS
// 00E7H TAPIOF   MSX1   テープ読み込み停止     ✅ C-BIOS
// 00EAH TAPOON   MSX1   テープ書き込み開始     ✅ C-BIOS
// 00EDH TAPOUT   MSX1   テープデータ書き込み   ✅ C-BIOS
// 00F0H TAPOOF   MSX1   テープ書き込み停止     ✅ C-BIOS
// 00F3H STMOTR   MSX1   モーター制御           ✅ C-BIOS
// 00F6H LFTQ     MSX1   キュー残量             ✅ C-BIOS
// 00F9H PUTQ     MSX1   キュー書き込み         ✅ C-BIOS
// 00FCH RIGHTC   MSX1   グラフィックカーソル右 ✅ C-BIOS
// 00FFH LEFTC    MSX1   グラフィックカーソル左 ✅ C-BIOS
// 0102H UPC      MSX1   グラフィックカーソル上 ✅ C-BIOS
// 0105H TUPC     MSX1   テスト付き上移動       ✅ C-BIOS
// 0108H DOWNC    MSX1   グラフィックカーソル下 ✅ C-BIOS
// 010BH TDOWNC   MSX1   テスト付き下移動       ✅ C-BIOS
// 010EH SCALXY   MSX1   座標クリップ           ✅ C-BIOS
// 0111H MAPXYC   MSX1   座標→アドレス変換      ✅ C-BIOS
// 0114H FETCHC   MSX1   カレント取得           ✅ C-BIOS
// 0117H STOREC   MSX1   カレント格納           ✅ C-BIOS
// 011AH SETATR   MSX1   属性設定               ✅ C-BIOS
// 011DH READC    MSX1   ドット読み             ✅ C-BIOS
// 0120H SETC     MSX1   ドット書き             ✅ C-BIOS
// 0123H NSETCX   MSX1   水平ドット描画         ✅ C-BIOS
// 0126H GTASPC   MSX1   アスペクト比取得       ✅ C-BIOS
// 0129H PNTINI   MSX1   ペイント初期化         ✅ C-BIOS
// 012CH SCANR    MSX1   右方向スキャン         ✅ C-BIOS
// 012FH SCANL    MSX1   左方向スキャン         ✅ C-BIOS
// 0132H CHGCAP   MSX1   CAPS 状態設定          ✅ C-BIOS
// 0135H CHGSND   MSX1   1bit 音声制御          ✅ C-BIOS
// 0138H RSLREG   MSX1   スロットレジスタ読み   ✅ C-BIOS
// 013BH WSLREG   MSX1   スロットレジスタ書き   ✅ C-BIOS
// 013EH RDVDP    MSX1   VDP ステータス読み     ✅ C-BIOS
// 0141H SNSMAT   MSX1   キーボード行スキャン   ✅ C-BIOS
// 0144H PHYDIO   MSX2   ディスク物理 I/O       ✅ C-BIOS
// 0147H FORMAT   MSX2   ディスクフォーマット   ✅ C-BIOS
// 014AH ISFLIO   MSX1   I/O 動作確認           ✅ C-BIOS
// 014DH OUTDLP   MSX1   プリンタ出力(タブ)     ✅ C-BIOS
// 0150H GETVCP   MSX1   VDP コマンドポインタ   ✅ C-BIOS
// 0153H GETVC2   MSX2   VDP コマンドポインタ2  ✅ C-BIOS
// 0156H KILBUF   MSX1   キーバッファクリア     ✅ C-BIOS
// 0159H CALBAS   MSX1   BASIC ルーチン呼び出し ✅ C-BIOS
//
// ──── 以下 MSX2/MSX2+ 拡張: α-BIOS で新規実装 ────
//
// 015CH SUBROM   MSX2   SUB ROM 呼び出し       🆕 α-BIOS stub
// 015FH EXTROM   MSX2   拡張 ROM 呼び出し      🆕 α-BIOS stub
// 0162H CHKSLZ   MSX1   スロット0チェック      🆕 α-BIOS stub
// 0165H CHKNEW   MSX2   新デバイスチェック     🆕 α-BIOS stub
// 0168H EOL      MSX2   行末処理               🆕 α-BIOS stub
// 016BH BIGFIL   MSX2   大容量 VRAM 塗りつぶし 🆕 α-BIOS → FILVRM
// 016EH NSETRD   MSX2   拡張 VRAM 読みアドレス 🆕 α-BIOS → SETRD
// 0171H NSTWRT   MSX2   拡張 VRAM 書きアドレス 🆕 α-BIOS → SETWRT
// 0174H NRDVRM   MSX2   拡張 VRAM 読み込み     🆕 α-BIOS → RDVRM
// 0177H NWRVRM   MSX2   拡張 VRAM 書き込み     🆕 α-BIOS → WRTVRM
// 017AH RDRES    MSX2+  RESET ポート読み込み   🆕 α-BIOS stub (→0)
// 017DH WRRES    MSX2+  RESET ポート書き込み   🆕 α-BIOS stub (NOP)

import Foundation

enum AlphaBIOS {

    /// バンドル C-BIOS からパッチ済み α-BIOS ROM を生成する。
    /// slot 0 にそのままロードできる 64KB イメージで返す。
    static func generate() -> [UInt8]? {
        guard let mainURL = Bundle.main.url(forResource: "cbios_main_msx1", withExtension: "rom"),
              let mainData = try? Data(contentsOf: mainURL) else {
            print("[α-BIOS] C-BIOS main ROM not found")
            return nil
        }

        // 64KB slot image (0x0000-0xFFFF)
        var rom = [UInt8](repeating: 0xFF, count: 0x10000)

        // ── Base: C-BIOS main ROM (32KB → 0x0000-0x7FFF) ──
        let mainBytes = [UInt8](mainData)
        let mainLen = min(mainBytes.count, 0x8000)
        rom[0..<mainLen] = mainBytes[0..<mainLen]

        // ============================================================
        //  Patch 1: ブランディング文字列
        // ============================================================
        patchString(&rom, at: 0x2556,
                    old: "C-BIOS 0.29      cbios.sf.net",
                    new: "a-BIOS 1.0           EMuSX")
        patchString(&rom, at: 0x264A,
                    old: "This version of C-BIOS can",
                    new: "This version of a-BIOS can")

        // ============================================================
        //  Patch 2: 高速ブート (ロゴ表示遅延 120→1 フレーム)
        // ============================================================
        // 0x0DD3: LD B,0x78 → LD B,0x01
        if rom[0x0DD3] == 0x06 && rom[0x0DD4] == 0x78 {
            rom[0x0DD4] = 0x01
        }

        // ============================================================
        //  Patch 3: ミニマルロゴ ROM (0x8000)
        // ============================================================
        // C-BIOS はスロット0の 0x8000 で "C-" (0x43,0x2D) ヘッダを検索する。
        // ロゴ ROM が無いと起動時にエラー表示される。
        // ヘッダ＋即 RET の最小データを配置してチェックをパスさせる。
        rom[0x8000] = 0x43  // 'C'
        rom[0x8001] = 0x2D  // '-'
        rom[0x8002] = 0x06  // INIT vector low  → 0x8006
        rom[0x8003] = 0x80  // INIT vector high
        rom[0x8004] = 0x00  // STATEMENT vector = 0
        rom[0x8005] = 0x00
        rom[0x8006] = 0xC9  // RET (ロゴは何も描画しない)

        // ============================================================
        //  Patch 11: MSXVER = 1 (MSX2) を報告
        // ============================================================
        // C-BIOS MSX1 は 0x002D = 0x00 (MSX1) だが、Metal Gear 等の
        // MSX2 ゲームはこのバイトを読んで MSX2 以上でなければ起動を中止する。
        // α-BIOS は V9938 VDP パッチ (Patch 10) で SCREEN 5 をサポートするため、
        // MSX2 を名乗っても整合性がある。
        rom[0x002D] = 0x01  // MSX2

        // ============================================================
        //  Patch 4: MSX2/MSX2+ BIOS エントリポイント (MAIN ROM)
        // ============================================================
        // 0x015C-0x017F の未実装エントリにスタブ/リダイレクトを配置。
        // 実コードは 0x3F00- の空き領域 (ページ0内) に配置する。
        // ※ ページ0 (0x0000-0x3FFF) はBIOS呼び出し時に常にスロット0にマップされるため、
        //    カートリッジがページ1にロードされていてもパッチコードにアクセスできる。

        // --- 0x015C SUBROM: SUB ROM 呼び出し ---
        // IX にサブルーチンアドレスが入る。SUB ROM が無いので安全に RET。
        // ただし呼び出し元がスタックに余分なデータを積む場合があるため、
        // 標準的な SUBROM プロトコルに従い EX (SP),IX → JP (IX) で処理。
        writeJP(&rom, at: 0x015C, to: 0x3F00)
        // SUBROM stub at 0x3F00:
        //   EX (SP),HL      ; E3        - return addr を HL に
        //   PUSH HL          ; E5        - return addr を退避
        //   LD L,(IX+0)      ; DD 6E 00  - (unused, keep stack balanced)
        //   POP HL           ; E1
        //   EX (SP),HL       ; E3
        //   RET              ; C9
        // 簡易版: IXの内容は無視して即 RET (スタック消費は呼び出し側で管理)
        let subromStub: [UInt8] = [0xC9]  // RET
        writeBytes(&rom, at: 0x3F00, bytes: subromStub)

        // --- 0x015F EXTROM: 拡張 ROM 呼び出し ---
        writeRET(&rom, at: 0x015F)

        // --- 0x0162 CHKSLZ: スロット0のサブスロット状態チェック ---
        // A=0 (サブスロットなし) を返して RET
        writeJP(&rom, at: 0x0162, to: 0x3F10)
        let chkslzStub: [UInt8] = [0xAF, 0xC9]  // XOR A; RET
        writeBytes(&rom, at: 0x3F10, bytes: chkslzStub)

        // --- 0x0165 CHKNEW: 新デバイスチェック ---
        writeRET(&rom, at: 0x0165)

        // --- 0x0168 EOL: 行末消去 ---
        // HL=VRAM 上の位置。CLS の部分処理だが、スタブとして RET。
        writeRET(&rom, at: 0x0168)

        // --- 0x016B BIGFIL: 大容量 VRAM 塗りつぶし ---
        // MSX2 の 128KB VRAM 対応版 FILVRM。MSX1 VDP では FILVRM へ転送。
        // 入力: HL=VRAM アドレス, BC=長さ, A=データ → FILVRM と同じ
        writeJP(&rom, at: 0x016B, to: 0x0056)  // → FILVRM

        // --- 0x016E NSETRD: 拡張 VRAM 読みアドレス設定 ---
        // MSX2 の 17bit アドレス対応。MSX1 VDP では上位ビット無視→ SETRD。
        writeJP(&rom, at: 0x016E, to: 0x0050)  // → SETRD

        // --- 0x0171 NSTWRT: 拡張 VRAM 書きアドレス設定 ---
        writeJP(&rom, at: 0x0171, to: 0x0053)  // → SETWRT

        // --- 0x0174 NRDVRM: 拡張 VRAM 読み込み ---
        // HL=VRAM アドレス → A=データ。MSX1 VDP → RDVRM。
        writeJP(&rom, at: 0x0174, to: 0x004A)  // → RDVRM

        // --- 0x0177 NWRVRM: 拡張 VRAM 書き込み ---
        // HL=VRAM アドレス, A=データ。MSX1 VDP → WRTVRM。
        writeJP(&rom, at: 0x0177, to: 0x004D)  // → WRTVRM

        // --- 0x017A RDRES: RESET ポート読み込み (MSX2+) ---
        // A=0 を返す
        writeJP(&rom, at: 0x017A, to: 0x3F10)  // → XOR A; RET (CHKSLZ と共用)

        // --- 0x017D WRRES: RESET ポート書き込み (MSX2+) ---
        writeRET(&rom, at: 0x017D)

        // ============================================================
        //  Patch 5 & 6: C-BIOS ブートコード共通修正
        // ============================================================
        AlphaBIOS.applyBootFixes(&rom)

        print("[α-BIOS] Generated: 64KB image with MSX2/MSX2+ stubs + boot fixes")
        return rom
    }

    // MARK: - C-BIOS ブートコード共通修正

    /// C-BIOS のブートコードに存在するバグを修正する。
    /// α-BIOS と Default BIOS (C-BIOS) の両方に適用される。
    /// ROM イメージは 64KB (slot 0 全体) を想定。
    static func applyBootFixes(_ rom: inout [UInt8]) {
        guard rom.count >= 0x8000 else { return }

        // ── Patch 7: 高速ブート (ロゴ表示遅延 120→1 フレーム) ──
        // 0x0DD3: LD B,0x78 → LD B,0x01
        // α-BIOS は Patch 2 で既に適用済み (0x78→0x01) のため、
        // Default BIOS (C-BIOS) のみに効果がある。
        if rom[0x0DD3] == 0x06 && rom[0x0DD4] == 0x78 {
            rom[0x0DD4] = 0x01
        }

        // ── Patch 8: ロゴ ROM シグネチャ無効化 ──
        // C-BIOS は 0x8000 から 15 バイト "C-BIOS Logo ROM" をチェックし、
        // 一致すればロゴ ROM を実行してロゴを表示する。
        // 先頭の 'C' (0x43) を破壊してチェックを失敗させ、ロゴ表示をスキップ。
        if rom[0x8000] == 0x43 {  // 'C'
            rom[0x8000] = 0x00
        }

        // ── Patch 9: ゲーム開始フック呼び出し ──
        // C-BIOS のアイドルループ (0x1A65: JR -2) は永久ループで、
        // ゲームが INIT 中にインストールするフック (0xFEDA = H.STKE) を
        // 呼び出さない。King's Valley II 等のゲームが起動しない原因。
        //
        // 修正: 0x1A65 の 2 バイト JR ループを 12 バイトのフックチェック付き
        // ループに書き換える。0x1A67-0x1A70 は元々デッドコードなので上書き可。
        //
        //   1A65: LD A,(0xFEDA)   ; フック先頭バイトを読む
        //   1A68: CP 0xC9         ; RET (未変更) かチェック
        //   1A6A: JR Z,0x1A65     ; 未変更なら再ループ
        //   1A6C: CALL 0xFEDA     ; ゲーム開始フック呼び出し
        //   1A6F: JR 0x1A65       ; (安全策) フック復帰時は再ループ
        if rom[0x1A65] == 0x18 && rom[0x1A66] == 0xFE {
            let hookPatch: [UInt8] = [
                0x3A, 0xDA, 0xFE,   // LD A,(0xFEDA)
                0xFE, 0xC9,         // CP 0xC9
                0x28, 0xF9,         // JR Z,-7  → 0x1A65
                0xCD, 0xDA, 0xFE,   // CALL 0xFEDA
                0x18, 0xF4,         // JR -12   → 0x1A65
            ]
            writeBytes(&rom, at: 0x1A65, bytes: hookPatch)
        }

        // ── Patch 5: ワークエリア初期化修正 ──
        // C-BIOS はブート時に F380-FFFC を一括ゼロ初期化するが、
        // 一部の変数がデフォルト値のまま放置される。
        //
        // 修正対象:
        //   F3B2 CLMLST = 14 (TAB列境界。0のままだとTAB計算が異常)
        //   F3DE CSRX   = 1  (カーソルX座標。MSXは1始まり、0は範囲外)
        //
        // 方法: カートリッジスキャン呼び出し (0x0DF5: CALL 0x0E22) を
        //        0x3F20 の修正ルーチン経由に変更。0x0E22 の先頭で
        //        A, HL, BC 等は即座に上書きされるためレジスタ破壊は安全。
        if rom[0x0DF5] == 0xCD && rom[0x0DF6] == 0x22 && rom[0x0DF7] == 0x0E {
            // Redirect: CALL 0x0E22 → CALL 0x3F20
            rom[0x0DF6] = 0x20  // low byte
            rom[0x0DF7] = 0x3F  // high byte

            // 0x3F20: ワークエリア修正 → JP 0x0E22 (本来のカートリッジスキャン)
            let fixCode: [UInt8] = [
                0x3E, 0x0E,             // LD A, 14
                0x32, 0xB2, 0xF3,       // LD (0xF3B2), A  ; CLMLST = 14
                0x3E, 0x01,             // LD A, 1
                0x32, 0xDE, 0xF3,       // LD (0xF3DE), A  ; CSRX = 1
                0xC3, 0x22, 0x0E,       // JP 0x0E22        ; cart scan
            ]
            writeBytes(&rom, at: 0x3F20, bytes: fixCode)
        }

        // ── Patch 11b: MSXVER = 1 (MSX2) を報告 ──
        // C-BIOS MSX1 は 0x002D = 0x00 (MSX1) だが、Metal Gear 等の
        // MSX2 ゲームはこのバイトを読んで MSX2 以上でなければ INIT から即 RET する。
        // α-BIOS では generate() でも設定されるが、Default C-BIOS にも必要。
        // V9938 パッチ (Patch 10) で SCREEN 5 をサポートするため整合性がある。
        if rom[0x002D] == 0x00 {
            rom[0x002D] = 0x01  // MSX2
            print("[Patch 11b] MSXVER set to 1 (MSX2)")
        }

        // ── Patch 6: LINL32 デフォルト値修正 (32 → 29) ──
        // C-BIOS のシステム初期化 (0x1007) で LINL32 が 32 に設定されるが、
        // MSX 標準のデフォルト値は 29 (SCREEN 1 の左右マージン考慮)。
        // ブートコードの後半 (0x0DE9) で 29 に上書きされるものの、
        // それ以前に INIT32 が呼ばれた場合、LINLEN が 32 になってしまう。
        if rom.count > 0x1008 && rom[0x1007] == 0x3E && rom[0x1008] == 0x20 {
            rom[0x1008] = 0x1D  // 29
        }

        // ── Patch 10: CHGMOD V9938 拡張 (SCREEN 5 対応) ──
        // C-BIOS (MSX1) の CHGMOD 実装 (0x02AD) は CP 4; RET NC で
        // A ≧ 4 のモードを全て無視する。Metal Gear 等の MSX2 ゲームは
        // CHGMOD(5) で SCREEN 5 (Graphic 4: 256×212, 4bpp) を設定するが、
        // C-BIOS では R#0 の M5 ビットが設定されないため画面が表示されない。
        //
        // 修正: 0x02AD の 3 バイト (FE 04 D0) を JP 0x3F30 に書き換え、
        // 0x3F30 に V9938 モード判定ルーチンを配置する。
        // A < 4 なら元の MSX1 ディスパッチャにフォールスルー。
        // A = 5 なら SCREEN 5 用 VDP レジスタを設定して RET。
        //
        // SCREEN 5 で設定するレジスタ:
        //   R#0  = 0x08 (M5=1 → Graphic 4 モード)
        //   R#2  = 0x1F (VRAM ページ 0)
        //   R#9  = 0x80 (212 ライン, NTSC)
        //   ワークエリア: F3DF (RG0SAV), F3E1 (RG2SAV), FCAF (SCRMOD)
        if rom[0x02AD] == 0xFE && rom[0x02AE] == 0x04 && rom[0x02AF] == 0xD0 {
            // Redirect: CP 4; RET NC → JP 0x3F30
            rom[0x02AD] = 0xC3  // JP
            rom[0x02AE] = 0x30  // low
            rom[0x02AF] = 0x3F  // high

            // 0x3F30: CHGMOD V9938 extension handler
            //
            //   3F30: CP 4
            //   3F32: JR C, msx1       → 0x3F63 (offset +0x2F)
            //   3F34: CP 5
            //   3F36: JR NZ, ret_only  → 0x3F62 (offset +0x2A)
            //   ---- SCREEN 5 setup ----
            //   3F38: IN A, (0x99)                                                  ← VDP latch reset
            //   3F3A: LD A, 0x08 ; OUT (0x99), A ; LD A, 0x80 ; OUT (0x99), A  → R#0 = 0x08
            //   3F42: LD A, 0x08 ; LD (0xF3DF), A                              → RG0SAV
            //   3F47: LD A, 0x1F ; OUT (0x99), A ; LD A, 0x82 ; OUT (0x99), A  → R#2 = 0x1F
            //   3F4F: LD A, 0x1F ; LD (0xF3E1), A                              → RG2SAV
            //   3F54: LD A, 0x80 ; OUT (0x99), A ; LD A, 0x89 ; OUT (0x99), A  → R#9 = 0x80
            //   3F5C: LD A, 0x05 ; LD (0xFCAF), A                              → SCRMOD = 5
            //   3F61: RET
            //   ---- unsupported V9938 mode ----
            //   3F62: RET
            //   ---- MSX1 fallthrough ----
            //   3F63: LD HL, 0x02B6 ; JP 0x0200
            let chgmodPatch: [UInt8] = [
                0xFE, 0x04,                 // CP 4
                0x38, 0x2F,                 // JR C, msx1 (+0x2F → 0x3F63)
                0xFE, 0x05,                 // CP 5
                0x20, 0x2A,                 // JR NZ, ret_only (+0x2A → 0x3F62)
                // ── SCREEN 5 (Graphic 4) register setup ──
                0xDB, 0x99,                 // IN A, (0x99)     ; reset VDP latch
                0x3E, 0x08,                 // LD A, 0x08       ; R#0 value: M5=1
                0xD3, 0x99,                 // OUT (0x99), A
                0x3E, 0x80,                 // LD A, 0x80       ; write R#0
                0xD3, 0x99,                 // OUT (0x99), A
                0x3E, 0x08,                 // LD A, 0x08
                0x32, 0xDF, 0xF3,           // LD (0xF3DF), A   ; RG0SAV mirror
                0x3E, 0x1F,                 // LD A, 0x1F       ; R#2 value: page 0
                0xD3, 0x99,                 // OUT (0x99), A
                0x3E, 0x82,                 // LD A, 0x82       ; write R#2
                0xD3, 0x99,                 // OUT (0x99), A
                0x3E, 0x1F,                 // LD A, 0x1F
                0x32, 0xE1, 0xF3,           // LD (0xF3E1), A   ; RG2SAV mirror
                0x3E, 0x80,                 // LD A, 0x80       ; R#9 value: 212 lines
                0xD3, 0x99,                 // OUT (0x99), A
                0x3E, 0x89,                 // LD A, 0x89       ; write R#9
                0xD3, 0x99,                 // OUT (0x99), A
                0x3E, 0x05,                 // LD A, 0x05
                0x32, 0xAF, 0xFC,           // LD (0xFCAF), A   ; SCRMOD = 5
                0xC9,                       // RET
                // ── unsupported V9938 mode (A≠5, A≧4) ──
                0xC9,                       // RET
                // ── MSX1 fallthrough (A < 4) ──
                0x21, 0xB6, 0x02,           // LD HL, 0x02B6    ; mode jump table
                0xC3, 0x00, 0x02,           // JP 0x0200        ; original dispatcher
            ]
            writeBytes(&rom, at: 0x3F30, bytes: chgmodPatch)
            print("[Patch 10] CHGMOD V9938 patch applied at 0x02AD → JP 0x3F30")
        } else {
            print(String(format: "[Patch 10] CHGMOD bytes mismatch: %02X %02X %02X (expected FE 04 D0)",
                         rom[0x02AD], rom[0x02AE], rom[0x02AF]))
        }
    }

    // MARK: - Z80 Code Helpers

    /// JP nn (3 bytes: C3 lo hi) を書き込む
    private static func writeJP(_ rom: inout [UInt8], at offset: Int, to target: Int) {
        rom[offset]     = 0xC3              // JP
        rom[offset + 1] = UInt8(target & 0xFF)
        rom[offset + 2] = UInt8((target >> 8) & 0xFF)
    }

    /// RET + NOP×2 (3 bytes) を書き込む
    private static func writeRET(_ rom: inout [UInt8], at offset: Int) {
        rom[offset]     = 0xC9              // RET
        rom[offset + 1] = 0x00              // NOP (padding)
        rom[offset + 2] = 0x00              // NOP (padding)
    }

    /// 任意のバイト列を書き込む
    private static func writeBytes(_ rom: inout [UInt8], at offset: Int, bytes: [UInt8]) {
        for (i, b) in bytes.enumerated() {
            rom[offset + i] = b
        }
    }

    /// ROM 内の ASCII 文字列をパッチ（同じ長さ以下で上書き、余りは 0x20 埋め）
    private static func patchString(_ rom: inout [UInt8], at offset: Int,
                                     old: String, new: String) {
        let oldBytes = [UInt8](old.utf8)
        let newBytes = [UInt8](new.utf8)
        guard offset + oldBytes.count <= rom.count else { return }

        let actual = Array(rom[offset..<(offset + oldBytes.count)])
        guard actual == oldBytes else { return }

        for i in 0..<oldBytes.count {
            rom[offset + i] = i < newBytes.count ? newBytes[i] : 0x20
        }
    }
}
