// GamepadConfig.swift - ゲームパッド設定（キーセット・ボタン割り当て・連射）
// UserDefaults で永続化

import SwiftUI
import Combine

// MARK: - キーセットの種類
enum GamepadKeySet: Int, CaseIterable {
    case setA = 0  // 4方向 + 2ボタン
    case setB = 1  // 8方向 + 2ボタン
    case setC = 2  // 8方向 + 4ボタン
    case setD = 3  // 8方向 + 6ボタン
    case setE = 4  // 8方向 + 2ボタン + 外部キーボード特殊キー

    var label: String {
        switch self {
        case .setA: return "A: 4-Dir + 2 Btn"
        case .setB: return "B: 8-Dir + 2 Btn"
        case .setC: return "C: 8-Dir + 4 Btn"
        case .setD: return "D: 8-Dir + 6 Btn"
        case .setE: return "E: Keyboard"
        }
    }

    var is8Direction: Bool { self != .setA }
    var buttonCount: Int {
        switch self {
        case .setA, .setB, .setE: return 2
        case .setC: return 4
        case .setD: return 6
        }
    }

    /// 外部キーボードで特殊キー（GRAPH / CODE / STOP / SEL / F1-F5）を入力するモード
    var isKeyboardMode: Bool { self == .setE }
}

// MARK: - セーブステートに含める設定スナップショット
struct SettingsSnapshot: Codable {
    var speedValue: Double
    var keySetRaw: Int
    var button1Key: String
    var button2Key: String
    var button3Key: String
    var button4Key: String
    var button5Key: String?
    var button6Key: String?
    var button1Turbo: Bool
    var button2Turbo: Bool
    var button3Turbo: Bool
    var button4Turbo: Bool
    var button5Turbo: Bool?
    var button6Turbo: Bool?
}

// MARK: - ゲームパッド設定
@MainActor
final class GamepadConfig: ObservableObject {
    static let shared = GamepadConfig()

    @Published var keySet: GamepadKeySet {
        didSet { save() }
    }
    @Published var button1Key: String { didSet { save() } }
    @Published var button2Key: String { didSet { save() } }
    @Published var button3Key: String { didSet { save() } }
    @Published var button4Key: String { didSet { save() } }
    @Published var button5Key: String { didSet { save() } }
    @Published var button6Key: String { didSet { save() } }

    // 連射（ターボ）設定: ボタンごとにON/OFF
    @Published var button1Turbo: Bool { didSet { save() } }
    @Published var button2Turbo: Bool { didSet { save() } }
    @Published var button3Turbo: Bool { didSet { save() } }
    @Published var button4Turbo: Bool { didSet { save() } }
    @Published var button5Turbo: Bool { didSet { save() } }
    @Published var button6Turbo: Bool { didSet { save() } }

    /// 設定UIのピッカーに表示するキー一覧
    nonisolated static let assignableKeys: [String] = {
        MSXMachine.keyMap.keys.sorted()
    }()

    /// キー名を表示用ラベルに変換
    nonisolated static func displayLabel(for key: String) -> String {
        switch key {
        case " ": return "SPC"
        default:  return key
        }
    }

    // MARK: - Snapshot ヘルパー

    /// 現在の設定をスナップショット化（speedValue は外部から渡す）
    func snapshot(speedValue: Double) -> SettingsSnapshot {
        SettingsSnapshot(
            speedValue: speedValue,
            keySetRaw: keySet.rawValue,
            button1Key: button1Key,
            button2Key: button2Key,
            button3Key: button3Key,
            button4Key: button4Key,
            button5Key: button5Key,
            button6Key: button6Key,
            button1Turbo: button1Turbo,
            button2Turbo: button2Turbo,
            button3Turbo: button3Turbo,
            button4Turbo: button4Turbo,
            button5Turbo: button5Turbo,
            button6Turbo: button6Turbo
        )
    }

    /// スナップショットから設定を復元し、speedValue を返す
    func apply(_ s: SettingsSnapshot) -> Double {
        keySet = GamepadKeySet(rawValue: s.keySetRaw) ?? .setA
        button1Key = s.button1Key
        button2Key = s.button2Key
        button3Key = s.button3Key
        button4Key = s.button4Key
        button5Key = s.button5Key ?? "F3"
        button6Key = s.button6Key ?? "F4"
        button1Turbo = s.button1Turbo
        button2Turbo = s.button2Turbo
        button3Turbo = s.button3Turbo
        button4Turbo = s.button4Turbo
        button5Turbo = s.button5Turbo ?? false
        button6Turbo = s.button6Turbo ?? false
        return s.speedValue
    }

    // MARK: - UserDefaults 永続化
    private let defaults = UserDefaults.standard
    private enum Keys {
        static let keySet  = "gamepad_keySet"
        static let button1 = "gamepad_button1"
        static let button2 = "gamepad_button2"
        static let button3 = "gamepad_button3"
        static let button4 = "gamepad_button4"
        static let button5 = "gamepad_button5"
        static let button6 = "gamepad_button6"
        static let button1Turbo = "gamepad_button1_turbo"
        static let button2Turbo = "gamepad_button2_turbo"
        static let button3Turbo = "gamepad_button3_turbo"
        static let button4Turbo = "gamepad_button4_turbo"
        static let button5Turbo = "gamepad_button5_turbo"
        static let button6Turbo = "gamepad_button6_turbo"
    }

    private init() {
        let raw = UserDefaults.standard.integer(forKey: Keys.keySet)
        self.keySet     = GamepadKeySet(rawValue: raw) ?? .setA
        self.button1Key = UserDefaults.standard.string(forKey: Keys.button1) ?? "RET"
        self.button2Key = UserDefaults.standard.string(forKey: Keys.button2) ?? " "
        self.button3Key = UserDefaults.standard.string(forKey: Keys.button3) ?? "F1"
        self.button4Key = UserDefaults.standard.string(forKey: Keys.button4) ?? "F2"
        self.button5Key = UserDefaults.standard.string(forKey: Keys.button5) ?? "F3"
        self.button6Key = UserDefaults.standard.string(forKey: Keys.button6) ?? "F4"
        self.button1Turbo = UserDefaults.standard.bool(forKey: Keys.button1Turbo)
        self.button2Turbo = UserDefaults.standard.bool(forKey: Keys.button2Turbo)
        self.button3Turbo = UserDefaults.standard.bool(forKey: Keys.button3Turbo)
        self.button4Turbo = UserDefaults.standard.bool(forKey: Keys.button4Turbo)
        self.button5Turbo = UserDefaults.standard.bool(forKey: Keys.button5Turbo)
        self.button6Turbo = UserDefaults.standard.bool(forKey: Keys.button6Turbo)
    }

    private func save() {
        defaults.set(keySet.rawValue, forKey: Keys.keySet)
        defaults.set(button1Key,      forKey: Keys.button1)
        defaults.set(button2Key,      forKey: Keys.button2)
        defaults.set(button3Key,      forKey: Keys.button3)
        defaults.set(button4Key,      forKey: Keys.button4)
        defaults.set(button5Key,      forKey: Keys.button5)
        defaults.set(button6Key,      forKey: Keys.button6)
        defaults.set(button1Turbo,    forKey: Keys.button1Turbo)
        defaults.set(button2Turbo,    forKey: Keys.button2Turbo)
        defaults.set(button3Turbo,    forKey: Keys.button3Turbo)
        defaults.set(button4Turbo,    forKey: Keys.button4Turbo)
        defaults.set(button5Turbo,    forKey: Keys.button5Turbo)
        defaults.set(button6Turbo,    forKey: Keys.button6Turbo)
    }
}
