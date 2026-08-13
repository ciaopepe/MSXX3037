// CassetteTape.swift - カセットテープ (データレコーダ) エミュレーション
//
// MSX の一部のゲームはセーブデータをカセットテープに記録する。
// (例: Knightmare III - Shalom は SAVE / CONTINUE をテープ BIOS で行う)
// C-BIOS のテープルーチンはルーチン名を表示して CF=1 を返すだけのスタブなので、
// MSXMachine 側で BIOS エントリを PC 捕捉し、このクラスで内容を保持・永続化する。
//
// 実機のテープは連続した「ブロック」の並びで、1 ブロックが
//   TAPOON (ヘッダ書き込み) → TAPOUT × n (データ) → TAPOOF (終了)
// に対応する。読み出しは
//   TAPION (ヘッダ検出) → TAPIN × n (データ) → TAPIOF (終了)
// となる。ゲームは 1 回のセーブで複数ブロック (ファイルヘッダ + 本体) を書く。

import Foundation

final class CassetteTape {

    /// テープ上の 1 ブロック
    struct Block: Codable {
        var longHeader: Bool    // TAPOON の A≠0 (ロングヘッダ) か
        var data: [UInt8]
    }

    private(set) var blocks: [Block] = []

    // 読み出し位置
    private var readBlock = 0
    private var readPos   = 0

    // 書き込み中のブロック
    private var writeBuffer: [UInt8] = []
    private var writeLong = false
    private var isWriting = false

    /// 直前のテープ操作の種別。セッション境界（巻き戻し）の判定に使う。
    private enum LastOp { case none, read, write }
    private var lastOp: LastOp = .none

    /// 書き込み位置（実機の「テープを巻き戻して録音し直す」に相当）
    private var writeBlock = 0

    /// 現在の探索中に一度でも終端から先頭へ巻き戻したか（無限ループ防止）
    private var searchWrapped = false

    /// 永続化先。nil の間はメモリ上のみ（カートリッジ未ロード時）。
    var fileURL: URL?

    // MARK: - セッション判定
    //
    // 実機のテープは「巻き戻さない限り前へ進む」。1 回のセーブ/ロードで
    // ゲームは複数ブロックを連続して処理する（例: Shalom のセーブは
    // ヘッダブロック(0xEA×10 + ファイル名) とデータブロックの 2 つ）。
    //
    // 以前は「一定フレーム以上間隔が空いたら新セッション」というヒューリスティック
    // を使っていたが、ブロック間の待ち時間が長いとセッションが切れたと誤判定して
    // 先行ブロックを消してしまい、ヘッダブロックが失われてロードできなくなっていた。
    // 時間ではなく「読み↔書きの切り替わり」だけで巻き戻しを判定する。

    private func isNewSession(_ op: LastOp) -> Bool {
        lastOp != op       // .none からの初回も必ず true になる
    }

    // MARK: - 書き込み (TAPOON / TAPOUT / TAPOOF)

    /// TAPOON: ヘッダを書いてブロックを開始する。
    ///
    /// 実機では新しいヘッダを書き始めた時点で直前のブロックは確定する。
    /// TAPOOF は「書き込みを終える」だけで、ブロック境界は TAPOON が作る。
    ///
    /// 実際 Shalom のセーブは TAPOOF を挟まずに TAPOON を連続で呼ぶ:
    ///   TAPOON(long) → TAPOUT×16 (0xEA×10 + "SHALOM")
    ///   TAPOON(short) → TAPOUT×63 → TAPOOF
    /// ここで直前のブロックを確定しないとヘッダブロックが失われ、
    /// ロード時に識別子が見つからず CONTINUE できなくなる。
    func beginWrite(longHeader: Bool, frame: Int) {
        if isWriting {
            commitBlock()       // TAPOOF を挟まない連続 TAPOON に対応
        } else if isNewSession(.write) {
            writeBlock = 0      // 書き込みセッション開始 → 頭出し
        }
        lastOp = .write
        writeBuffer.removeAll()
        writeLong = longHeader
        isWriting = true
    }

    /// TAPOUT: 1 バイト書き込む
    func writeByte(_ b: UInt8, frame: Int) {
        guard isWriting else { return }
        writeBuffer.append(b)
    }

    /// TAPOOF: 書き込みを終了する。書きかけのブロックを確定する。
    func endWrite() {
        guard isWriting else { return }
        commitBlock()
    }

    /// 書きかけのブロックを現在の書き込み位置へ確定し、位置を 1 つ進める。
    private func commitBlock() {
        let block = Block(longHeader: writeLong, data: writeBuffer)
        if writeBlock < blocks.count {
            blocks[writeBlock] = block
        } else {
            blocks.append(block)
        }
        writeBlock += 1
        writeBuffer.removeAll()
        isWriting = false
        save()
    }

    // MARK: - 読み出し (TAPION / TAPIN / TAPIOF)

    /// TAPION: 次のブロックのヘッダを検出する。成功なら true。
    ///
    /// 実機の TAPION はテープを前へ送りながら次のヘッダを探すため、
    /// 呼ばれるたびに次のブロックへ進む。読み出しセッションの開始時だけ
    /// 先頭へ巻き戻す。
    ///
    /// ゲームによっては目的のファイルが見つかるまで TAPIOF を挟まずに
    /// TAPION を繰り返す（Shalom のロードは識別子 0xEA が一致しないと
    /// TAPION からやり直す）。ここで前へ進めないと同じブロックを読み続けて
    /// 無限ループになる。
    func beginRead(frame: Int) -> Bool {
        if isNewSession(.read) {
            readBlock = 0           // 読み出しセッションの開始 → 頭出し
            searchWrapped = false
        } else {
            readBlock += 1          // 次のヘッダを探して前へ送る
            if readBlock >= blocks.count && !searchWrapped {
                // 終端に達したら一度だけ頭出しして探し直す。
                // 実機ではユーザーがテープを巻き戻す操作に相当し、
                // リセットを挟まずに CONTINUE を再試行できるようにする。
                // 2 周目でも見つからなければ false を返して打ち切るので、
                // 目的のファイルが無いテープでも無限ループにはならない。
                readBlock = 0
                searchWrapped = true
            }
        }
        lastOp = .read
        readPos = 0
        return readBlock < blocks.count
    }

    /// TAPIN: 1 バイト読み出す。データが尽きたら nil（CF=1 相当）。
    func readByte(frame: Int) -> UInt8? {
        guard readBlock < blocks.count else { return nil }
        let block = blocks[readBlock]
        guard readPos < block.data.count else { return nil }
        let b = block.data[readPos]
        readPos += 1
        return b
    }

    /// TAPIOF: 読み出しを終了する。
    /// ブロックの送りは TAPION 側が行うため、ここでは位置を進めない。
    func endRead() {
        readPos = 0
    }

    // MARK: - 巻き戻し

    /// テープの中身は残したまま、頭出し（読み書き位置を先頭へ）を行う。
    ///
    /// 本体リセット時に呼ぶ。TAPION は「テープを前へ送りながら次のヘッダを探す」
    /// 挙動のため、一度ロードすると読み出し位置が末尾まで進んでいる。巻き戻さないと
    /// リセット後の CONTINUE で 1 回目の TAPION がテープ終端に当たり、
    /// 「ロードがしっぱいにおわりました」になってしまう。
    /// 実機でもリセットボタンはテープの内容を消さず、ユーザーが頭出しして
    /// ロードし直すため、この動作が実機の操作に相当する。
    func rewind() {
        readBlock = 0
        readPos = 0
        writeBlock = 0
        writeBuffer.removeAll()
        isWriting = false
        searchWrapped = false
        lastOp = .none      // 次の TAPION / TAPOON を必ず新セッション扱いにする
    }

    // MARK: - ステートセーブ連携
    //
    // .msxstate のスナップショットにテープの内容を含めるための API。
    // これが無いと、ゲーム内でカセットテープにセーブしたデータが
    // ステートセーブ（および書き出しファイル）に反映されず、
    // 別の状態からロードした際にテープの中身が失われる。

    struct Snapshot: Codable {
        var blocks: [Block]
        var readBlock: Int
        var readPos: Int
    }

    var snapshot: Snapshot {
        Snapshot(blocks: blocks, readBlock: readBlock, readPos: readPos)
    }

    func restore(_ s: Snapshot) {
        blocks = s.blocks
        readBlock = s.readBlock
        readPos = s.readPos
        // 書き込み中の状態やセッション判定はスナップショットを跨がないので破棄する
        writeBuffer.removeAll()
        isWriting = false
        lastOp = .none
        writeBlock = 0
        searchWrapped = false
        // ロードした内容をディスクにも反映し、テープの永続化ファイルと一致させる
        save()
    }

    // MARK: - 永続化
    //
    // 形式: ブロックごとに [ヘッダ種別 1B][長さ 4B LE][データ]

    func save() {
        guard let url = fileURL else { return }
        var out = Data()
        for b in blocks {
            out.append(b.longHeader ? 1 : 0)
            var len = UInt32(b.data.count).littleEndian
            withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
            out.append(contentsOf: b.data)
        }
        do {
            try out.write(to: url, options: .atomic)
            print("[Tape] saved \(blocks.count) block(s), \(out.count) bytes")
        } catch {
            print("[Tape] save failed: \(error)")
        }
    }

    func load() {
        blocks.removeAll()
        readBlock = 0
        readPos = 0
        lastOp = .none
        writeBlock = 0
        searchWrapped = false
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return }
        var i = 0
        while i + 5 <= data.count {
            let long = data[i] != 0
            let len = Int(UInt32(data[i+1]) | UInt32(data[i+2]) << 8
                          | UInt32(data[i+3]) << 16 | UInt32(data[i+4]) << 24)
            i += 5
            guard len >= 0, i + len <= data.count else { break }
            blocks.append(Block(longHeader: long, data: [UInt8](data[i..<(i+len)])))
            i += len
        }
        print("[Tape] loaded \(blocks.count) block(s) from \(url.lastPathComponent)")
    }

    /// カートリッジ切り替え時などに内容を破棄する
    func eject() {
        blocks.removeAll()
        writeBuffer.removeAll()
        isWriting = false
        readBlock = 0
        readPos = 0
        lastOp = .none
        writeBlock = 0
        searchWrapped = false
        fileURL = nil
    }

    /// セーブデータが存在するか
    var hasData: Bool { !blocks.isEmpty }
}
