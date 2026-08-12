// RTC.swift - MSX2 時計 IC (RICOH RP-5C01) エミュレーション
//
// MSX2 は I/O ポート 0xB4 (レジスタ選択) / 0xB5 (データ) 経由で RTC にアクセスする。
// 時刻のほかに CMOS RAM を内蔵しており、MSX2 の BIOS は起動時にここから
// 画面色・キークリック音・起動画面などのシステム設定を読み出す。
// 実装が無いと読み出しが 0xFF になり、設定値が不正になる。
//
// レジスタ構成:
//   ブロック 0: 時刻 (秒/分/時/曜日/日/月/年)
//   ブロック 1: アラーム・調整用
//   ブロック 2-3: CMOS RAM (各 13 ニブル)
//   レジスタ 13: モード (下位 2bit = ブロック番号)
//   レジスタ 14: テスト, 15: リセット
//
// 各レジスタは 4bit (ニブル) 単位。

import Foundation

final class RTC {

    /// 現在選択中のレジスタ番号 (0-15)
    private var selected: Int = 0

    /// モードレジスタ (R#13)。下位 2bit が参照中のブロック番号。
    private var mode: UInt8 = 0

    /// CMOS RAM: ブロック 2 と 3、各 13 ニブル
    private var cmos = [UInt8](repeating: 0, count: 2 * 13)

    /// ブロック 1 (アラーム等) の保持値
    private var block1 = [UInt8](repeating: 0, count: 13)

    init() {
        // MSX2 BIOS が期待する既定値。
        // ブロック 2 の先頭には有効判定用のマジック "AB" 相当の値が入っており、
        // これが一致しないと BIOS は CMOS を初期化し直す。
        // ここでは «未初期化» を返して BIOS 側の初期化に任せる方が安全なので 0 のままにする。
        cmos = [UInt8](repeating: 0, count: 2 * 13)
    }

    /// ポート 0xB4: レジスタ選択
    func selectRegister(_ value: UInt8) {
        selected = Int(value & 0x0F)
    }

    /// ポート 0xB5: データ書き込み (下位ニブルのみ有効)
    func write(_ value: UInt8) {
        let v = value & 0x0F
        switch selected {
        case 13:
            mode = v
        case 14, 15:
            break   // テスト/リセットレジスタは無視
        default:
            let block = Int(mode & 0x03)
            switch block {
            case 0:
                break   // 時刻の書き換えは無視 (ホストの時刻を使う)
            case 1:
                if selected < block1.count { block1[selected] = v }
            case 2, 3:
                let idx = (block - 2) * 13 + selected
                if idx < cmos.count { cmos[idx] = v }
            default:
                break
            }
        }
    }

    /// ポート 0xB5: データ読み出し (上位ニブルは 1 で返る)
    func read() -> UInt8 {
        let v: UInt8
        switch selected {
        case 13:
            v = mode
        case 14, 15:
            v = 0
        default:
            let block = Int(mode & 0x03)
            switch block {
            case 0:
                v = timeNibble(selected)
            case 1:
                v = selected < block1.count ? block1[selected] : 0
            case 2, 3:
                let idx = (block - 2) * 13 + selected
                v = idx < cmos.count ? cmos[idx] : 0
            default:
                v = 0
            }
        }
        return v | 0xF0     // 未使用の上位ニブルは 1
    }

    /// ブロック 0 (時計) の各ニブルをホストの現在時刻から生成する
    private func timeNibble(_ reg: Int) -> UInt8 {
        let c = Calendar.current
        let d = Date()
        let sec   = c.component(.second, from: d)
        let min   = c.component(.minute, from: d)
        let hour  = c.component(.hour,   from: d)
        let wday  = c.component(.weekday, from: d) - 1   // 0 = 日曜
        let day   = c.component(.day,    from: d)
        let month = c.component(.month,  from: d)
        let year  = c.component(.year,   from: d)

        switch reg {
        case 0:  return UInt8(sec % 10)
        case 1:  return UInt8(sec / 10)
        case 2:  return UInt8(min % 10)
        case 3:  return UInt8(min / 10)
        case 4:  return UInt8(hour % 10)
        case 5:  return UInt8(hour / 10)
        case 6:  return UInt8(wday)
        case 7:  return UInt8(day % 10)
        case 8:  return UInt8(day / 10)
        case 9:  return UInt8(month % 10)
        case 10: return UInt8(month / 10)
        // MSX の年は 1980 年起点
        case 11: return UInt8(((year - 1980) % 100) % 10)
        case 12: return UInt8(((year - 1980) % 100) / 10)
        default: return 0
        }
    }

    // MARK: - セーブステート

    /// CMOS の内容 (時刻はホスト依存なので保存しない)
    var snapshot: [UInt8] { [mode] + cmos + block1 }

    func restore(_ data: [UInt8]) {
        guard data.count == 1 + cmos.count + block1.count else { return }
        mode = data[0]
        cmos = Array(data[1..<(1 + cmos.count)])
        block1 = Array(data[(1 + cmos.count)...])
    }
}
