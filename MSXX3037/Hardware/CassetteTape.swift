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

    /// 直前のテープ操作の種別。セッション境界の判定に使う。
    private enum LastOp { case none, read, write }
    private var lastOp: LastOp = .none
    private var lastOpFrame = 0

    /// セッションの区切りとみなすフレーム間隔。
    /// ゲームは 1 回のセーブ/ロードで複数ブロックを連続して処理するため、
    /// 連続操作は同一セッション、間隔が空いたら新しいセッションとして扱う。
    private let sessionGapFrames = 120

    /// 永続化先。nil の間はメモリ上のみ（カートリッジ未ロード時）。
    var fileURL: URL?

    // MARK: - セッション判定

    private func isNewSession(_ op: LastOp, frame: Int) -> Bool {
        if lastOp == .none { return true }
        if lastOp != op { return true }
        return frame - lastOpFrame > sessionGapFrames
    }

    // MARK: - 書き込み (TAPOON / TAPOUT / TAPOOF)

    /// TAPOON: ヘッダを書いてブロックを開始する。
    /// 新しいセッションならテープを巻き戻して上書きする（実機で録音し直す操作に相当）。
    func beginWrite(longHeader: Bool, frame: Int) {
        if isNewSession(.write, frame: frame) {
            blocks.removeAll()
        }
        lastOp = .write
        lastOpFrame = frame
        writeBuffer.removeAll()
        writeLong = longHeader
        isWriting = true
    }

    /// TAPOUT: 1 バイト書き込む
    func writeByte(_ b: UInt8, frame: Int) {
        guard isWriting else { return }
        writeBuffer.append(b)
        lastOpFrame = frame
    }

    /// TAPOOF: ブロックを確定してファイルへ保存する
    func endWrite() {
        guard isWriting else { return }
        blocks.append(Block(longHeader: writeLong, data: writeBuffer))
        writeBuffer.removeAll()
        isWriting = false
        save()
    }

    // MARK: - 読み出し (TAPION / TAPIN / TAPIOF)

    /// TAPION: 次のブロックのヘッダを検出する。成功なら true。
    /// 新しいセッションなら先頭ブロックへ巻き戻す。
    func beginRead(frame: Int) -> Bool {
        if isNewSession(.read, frame: frame) {
            readBlock = 0
        }
        lastOp = .read
        lastOpFrame = frame
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
        lastOpFrame = frame
        return b
    }

    /// TAPIOF: 読み出しを終了し、次のブロックへ進める
    func endRead() {
        if readBlock < blocks.count { readBlock += 1 }
        readPos = 0
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
        fileURL = nil
    }

    /// セーブデータが存在するか
    var hasData: Bool { !blocks.isEmpty }
}
