// ExternalKeyboardManager.swift
// 外部キーボード接続検出と MSX キーマトリクスへのイベント変換
// Gamepad E (setE) 選択時に有効化

import GameController
import Combine

@MainActor
final class ExternalKeyboardManager: ObservableObject {
    static let shared = ExternalKeyboardManager()

    /// 外部キーボードが接続されているか
    @Published var isConnected: Bool = false

    private weak var activeMachine: MSXMachine?

    // MARK: - ハードウェアキー → MSX キー名 マッピング
    // 同一 MSX キーに複数のハードウェアキーを割り当て可
    private let keyMapping: [(GCKeyCode, String)] = [
        (.leftAlt,      "GRAPH"),   // ⌥ Option Left  → GRAPH
        (.rightAlt,     "GRAPH"),   // ⌥ Option Right → GRAPH
        (.leftGUI,      "CODE"),    // ⌘ Command Left  → CODE
        (.rightGUI,     "CODE"),    // ⌘ Command Right → CODE
        (.leftControl,  "CODE"),    // ⌃ Control Left  → CODE
        (.rightControl, "CODE"),    // ⌃ Control Right → CODE
        (.escape,       "STOP"),    // ⎋ Esc → STOP
        (.tab,          "SEL"),     // ⇥ Tab → SELECT
        (.F1,           "F1"),
        (.F2,           "F2"),
        (.F3,           "F3"),
        (.F4,           "F4"),
        (.F5,           "F5"),
    ]

    private init() {
        isConnected = GCKeyboard.coalesced != nil

        NotificationCenter.default.addObserver(
            forName: .GCKeyboardDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isConnected = true
                // すでに setE 選択中なら即座にハンドラを再登録
                if let machine = self?.activeMachine {
                    self?.hookHandlers(machine: machine)
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: .GCKeyboardDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isConnected = GCKeyboard.coalesced != nil
            }
        }
    }

    // MARK: - Public API

    /// setE 選択時に呼ぶ — キーボードキャプチャを開始
    func startCapture(machine: MSXMachine) {
        activeMachine = machine
        hookHandlers(machine: machine)
    }

    /// setE から他のセットに切り替えるときに呼ぶ — キャプチャ停止 + スタックキー解放
    func stopCapture() {
        clearHandlers()
        activeMachine = nil
    }

    // MARK: - Private

    private func hookHandlers(machine: MSXMachine) {
        guard let kb = GCKeyboard.coalesced?.keyboardInput else { return }
        for (code, msxKey) in keyMapping {
            kb.button(forKeyCode: code)?.pressedChangedHandler = { [weak machine] _, _, pressed in
                DispatchQueue.main.async {
                    if pressed { machine?.pressKey(msxKey) }
                    else       { machine?.releaseKey(msxKey) }
                }
            }
        }
    }

    private func clearHandlers() {
        guard let kb = GCKeyboard.coalesced?.keyboardInput else { return }
        let msxKeys = Set(keyMapping.map(\.1))
        for (code, _) in keyMapping {
            kb.button(forKeyCode: code)?.pressedChangedHandler = nil
        }
        // スタックキーをすべて解放
        for msxKey in msxKeys {
            activeMachine?.releaseKey(msxKey)
        }
    }
}
