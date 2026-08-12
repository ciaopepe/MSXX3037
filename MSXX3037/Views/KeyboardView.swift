// KeyboardView.swift - MSX Virtual Keyboard

import SwiftUI

struct KeyboardView: View {
    let machine: MSXMachine
    @State private var pressedKeys = Set<String>()

    // MSX キーボード配列
    //
    // 各行の幅の合計を 13 ユニットに揃えてあるので、行ごとにキー幅が
    // ばらつかず端まで綺麗に並ぶ。キーを増減する場合も合計 13 を維持すること。
    //
    // F6-F10 は MSX 実機には独立したキーが無く、SHIFT + F1〜F5 で入力する。
    // そのため複数キーの同時押しとして定義している。
    private let rows: [[KeyDef]] = [
        // Row 1: ESC + ファンクションキー F1-F10 + BS   (11 + 2.0 = 13)
        [
            KeyDef("ESC", "ESC"),
            KeyDef("F1", "F1"), KeyDef("F2", "F2"), KeyDef("F3", "F3"),
            KeyDef("F4", "F4"), KeyDef("F5", "F5"),
            KeyDef(["SHIFT", "F1"], "F6"), KeyDef(["SHIFT", "F2"], "F7"),
            KeyDef(["SHIFT", "F3"], "F8"), KeyDef(["SHIFT", "F4"], "F9"),
            KeyDef(["SHIFT", "F5"], "F10"),
            KeyDef("BS", "BS", 2.0),
        ],
        // Row 2: 数字 + - = \                            (13 × 1.0 = 13)
        [
            KeyDef("1","1"), KeyDef("2","2"), KeyDef("3","3"),
            KeyDef("4","4"), KeyDef("5","5"), KeyDef("6","6"),
            KeyDef("7","7"), KeyDef("8","8"), KeyDef("9","9"),
            KeyDef("0","0"), KeyDef("-","-"), KeyDef("=","="),
            KeyDef("\\","\\"),
        ],
        // Row 3: QWERTY + [ ]                            (13 × 1.0 = 13)
        [
            KeyDef("TAB","TAB"),
            KeyDef("Q","Q"), KeyDef("W","W"), KeyDef("E","E"),
            KeyDef("R","R"), KeyDef("T","T"), KeyDef("Y","Y"),
            KeyDef("U","U"), KeyDef("I","I"), KeyDef("O","O"),
            KeyDef("P","P"),
            KeyDef("[","["), KeyDef("]","]"),
        ],
        // Row 4: ASDF + ; ' RET                          (13 × 1.0 = 13)
        [
            KeyDef("CTRL","CTRL"),
            KeyDef("A","A"), KeyDef("S","S"), KeyDef("D","D"),
            KeyDef("F","F"), KeyDef("G","G"), KeyDef("H","H"),
            KeyDef("J","J"), KeyDef("K","K"), KeyDef("L","L"),
            KeyDef(";",";"), KeyDef("'","'"),
            KeyDef("RET","RET"),
        ],
        // Row 5: ZXCV + , . / _                          (1.5 + 10 + 1.5 = 13)
        [
            KeyDef("SHIFT","SHIFT",1.5),
            KeyDef("Z","Z"), KeyDef("X","X"), KeyDef("C","C"),
            KeyDef("V","V"), KeyDef("B","B"), KeyDef("N","N"),
            KeyDef("M","M"),
            KeyDef(",",","), KeyDef(".","."), KeyDef("/","/"),
            KeyDef("SHIFT","SHIFT",1.5),
        ],
        // Row 6: 特殊キー                                 (1.5×8 + 1.0 = 13)
        [
            KeyDef("GRAPH","GRPH",1.5), KeyDef("CAP","CAPS",1.5),
            KeyDef("CODE","CODE",1.5), KeyDef("STOP","STOP",1.5),
            KeyDef("SEL","SEL",1.5), KeyDef("HOME","HOME",1.5),
            KeyDef("INS","INS",1.5), KeyDef("DEL","DEL",1.5),
            KeyDef("_","_"),
        ],
        // Row 7: SPACE + カーソル + `                     (6.0 + 1.5×4 + 1.0 = 13)
        [
            KeyDef(" ", "SPACE", 6.0),
            KeyDef("LEFT","◀",1.5), KeyDef("UP","▲",1.5),
            KeyDef("DOWN","▼",1.5), KeyDef("RIGHT","▶",1.5),
            KeyDef("`","`"),
        ],
    ]

    var body: some View {
        VStack(spacing: 2) {
            ForEach(0..<rows.count, id: \.self) { rowIdx in
                HStack(spacing: 2) {
                    ForEach(rows[rowIdx], id: \.id) { key in
                        keyButton(key)
                    }
                }
            }
        }
        .padding(4)
        .background(Color(white: 0.15))
    }

    private func keyButton(_ key: KeyDef) -> some View {
        let isPressed = pressedKeys.contains(key.id.uuidString)

        return Text(key.label)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .minimumScaleFactor(0.6)
            .lineLimit(1)
            .foregroundColor(isPressed ? .black : .white)
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .background(isPressed ? Color.green : Color(white: 0.25))
            .cornerRadius(4)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: CGFloat(key.width) * 34)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        // 同じキーを押している間は再送しない
                        guard !pressedKeys.contains(key.id.uuidString) else { return }
                        pressedKeys.insert(key.id.uuidString)
                        for name in key.names { machine.pressKey(name) }
                    }
                    .onEnded { _ in
                        pressedKeys.remove(key.id.uuidString)
                        // SHIFT のように複数キーで共有される修飾キーは、
                        // 他のキーがまだ押している場合は離さない
                        for name in key.names where !isHeldByOtherKey(name, except: key) {
                            machine.releaseKey(name)
                        }
                    }
            )
    }

    /// 押下中の他のキーが同じ MSX キーを使っているか
    private func isHeldByOtherKey(_ name: String, except key: KeyDef) -> Bool {
        for row in rows {
            for other in row where other.id != key.id {
                if pressedKeys.contains(other.id.uuidString) && other.names.contains(name) {
                    return true
                }
            }
        }
        return false
    }
}

struct KeyDef: Identifiable {
    let id = UUID()
    /// 同時に押す MSX キー名（F6 = SHIFT + F1 のような合成キーに対応）
    let names: [String]
    let label: String
    let width: Double

    init(_ name: String, _ label: String, _ width: Double = 1.0) {
        self.names = [name]
        self.label = label
        self.width = width
    }

    init(_ names: [String], _ label: String, _ width: Double = 1.0) {
        self.names = names
        self.label = label
        self.width = width
    }
}
