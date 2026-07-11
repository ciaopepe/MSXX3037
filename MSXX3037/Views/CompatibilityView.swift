// CompatibilityView.swift
// エミュレーション互換性情報（技術仕様ベース）
// 注: 市販ゲームの商品名は App Store 審査（5.2 知的財産）のため記載しない

import SwiftUI

// MARK: - 互換性情報ビュー
struct CompatibilityView: View {

    private let sections: [(icon: String, color: Color, title: String, items: [String])] = [
        ("cpu", .cyan, "Emulated Hardware", [
            "Z80 CPU (3.58 MHz)",
            "TMS9918A-compatible VDP",
            "AY-3-8910-compatible PSG sound",
            "Floppy disk controller",
        ]),
        ("doc", .green, "Supported File Formats", [
            "ROM cartridges (.rom / .bin)",
            "ZIP-compressed ROMs (.zip)",
            "Disk images (.dsk)",
        ]),
        ("memorychip", .orange, "Cartridge Mappers", [
            "Plain ROMs up to 64KB",
            "MegaROM bank-switching (8KB / 16KB banks)",
            "SCC sound cartridge support",
            "Automatic mapper detection",
        ]),
        ("square.and.arrow.down.on.square", .purple, "System", [
            "Open-source C-BIOS based system ROM",
            "Save states (3 slots)",
            "iCloud sync for settings and save data",
        ]),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // ヘッダー
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 36))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color.cyan, Color.green, Color.cyan],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .shadow(color: .cyan.opacity(0.5), radius: 10)

                    Text("Compatibility")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .padding(.top, 20)

                // セパレーター
                RoundedRectangle(cornerRadius: 1)
                    .fill(
                        LinearGradient(
                            colors: [.clear, .cyan.opacity(0.4), .green.opacity(0.4), .cyan.opacity(0.4), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: 200, height: 2)

                // 仕様セクション
                ForEach(sections, id: \.title) { section in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 10) {
                            Image(systemName: section.icon)
                                .font(.system(size: 16))
                                .foregroundColor(section.color)
                            Text(section.title)
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundColor(.primary)
                            Spacer()
                        }
                        .padding(.vertical, 12)
                        .padding(.horizontal, 14)

                        Divider().padding(.leading, 14)

                        ForEach(Array(section.items.enumerated()), id: \.offset) { index, item in
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(section.color.opacity(0.6))
                                    .frame(width: 5, height: 5)
                                Text(item)
                                    .font(.system(size: 13))
                                    .foregroundColor(.primary.opacity(0.85))
                                Spacer()
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal, 16)

                            if index < section.items.count - 1 {
                                Divider().padding(.leading, 33)
                            }
                        }
                    }
                    .background(Color(.secondarySystemGroupedBackground))
                    .cornerRadius(10)
                    .padding(.horizontal, 20)
                }

                // 注意書き（ユーザー持ち込みROMの責任明確化 — 審査4.7対応）
                Text("Game software is not included. Load only software you own or have the right to use.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)

                Spacer(minLength: 40)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        CompatibilityView()
    }
}
