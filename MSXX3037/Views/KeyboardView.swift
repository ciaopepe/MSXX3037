// KeyboardView.swift - MSX Virtual Keyboard

import SwiftUI

struct KeyboardView: View {
    let machine: MSXMachine
    @State private var pressedKeys = Set<String>()

    // MSX keyboard layout
    private let rows: [[KeyDef]] = [
        // Row 1: ESC + Function keys + control
        [
            KeyDef("ESC", "ESC", 1.0),
            KeyDef("F1", "F1", 1.0), KeyDef("F2", "F2", 1.0),
            KeyDef("F3", "F3", 1.0), KeyDef("F4", "F4", 1.0),
            KeyDef("F5", "F5", 1.0),
            KeyDef("BS", "⌫", 1.5),
        ],
        // Row 2: numbers
        [
            KeyDef("1","1",1), KeyDef("2","2",1), KeyDef("3","3",1),
            KeyDef("4","4",1), KeyDef("5","5",1), KeyDef("6","6",1),
            KeyDef("7","7",1), KeyDef("8","8",1), KeyDef("9","9",1),
            KeyDef("0","0",1), KeyDef("-","-",1), KeyDef("=","=",1),
        ],
        // Row 3: QWERTY
        [
            KeyDef("TAB","TAB",1.5),
            KeyDef("Q","Q",1), KeyDef("W","W",1), KeyDef("E","E",1),
            KeyDef("R","R",1), KeyDef("T","T",1), KeyDef("Y","Y",1),
            KeyDef("U","U",1), KeyDef("I","I",1), KeyDef("O","O",1),
            KeyDef("P","P",1),
        ],
        // Row 4: ASDF
        [
            KeyDef("CTRL","CTRL",1.5),
            KeyDef("A","A",1), KeyDef("S","S",1), KeyDef("D","D",1),
            KeyDef("F","F",1), KeyDef("G","G",1), KeyDef("H","H",1),
            KeyDef("J","J",1), KeyDef("K","K",1), KeyDef("L","L",1),
            KeyDef("RET","RET",1.5),
        ],
        // Row 5: ZXCV + space
        [
            KeyDef("SHIFT","SHIFT",2.0),
            KeyDef("Z","Z",1), KeyDef("X","X",1), KeyDef("C","C",1),
            KeyDef("V","V",1), KeyDef("B","B",1), KeyDef("N","N",1),
            KeyDef("M","M",1),
            KeyDef("SHIFT","↑SHIFT",2.0),
        ],
        // Row 6: Space + arrows
        [
            KeyDef(" ", "SPACE", 5.0),
            KeyDef("LEFT","◀",1), KeyDef("UP","▲",1),
            KeyDef("DOWN","▼",1), KeyDef("RIGHT","▶",1),
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
        let isPressed = pressedKeys.contains(key.name)

        return Text(key.label)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundColor(isPressed ? .black : .white)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(isPressed ? Color.green : Color(white: 0.25))
            .cornerRadius(4)
            .frame(width: nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: CGFloat(key.width) * 32)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !pressedKeys.contains(key.name) {
                            pressedKeys.insert(key.name)
                            machine.pressKey(key.name)
                        }
                    }
                    .onEnded { _ in
                        pressedKeys.remove(key.name)
                        machine.releaseKey(key.name)
                    }
            )
    }
}

struct KeyDef: Identifiable {
    let id = UUID()
    let name: String
    let label: String
    let width: Double

    init(_ name: String, _ label: String, _ width: Double = 1.0) {
        self.name = name
        self.label = label
        self.width = width
    }
}
