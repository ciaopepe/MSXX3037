// SupportTitlesView.swift
// サポートタイトル一覧
// タイトルを追加するには supportTitles 配列に文字列を追加してください

import SwiftUI

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// ここにタイトルを追加・編集してください
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

let supportTitles: [String] = [
    "Dragon Quest2","Goonies", "Gradius / Nemesis", "Gradius2 / Nemesis2","Knightmare / Majyo densetsu","Laptick2","Magical Kid Wiz", "Metal gear","Ganbare Goemon", "Butamaru Pants", "Arkanoid",
]

// MARK: - サポートタイトル一覧ビュー
struct SupportTitlesView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // ヘッダー
                VStack(spacing: 8) {
                    Image(systemName: "list.star")
                        .font(.system(size: 36))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color.cyan, Color.green, Color.cyan],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .shadow(color: .cyan.opacity(0.5), radius: 10)

                    Text("Support Titles")
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

                // タイトル一覧カード
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(supportTitles.sorted().enumerated()), id: \.offset) { index, title in
                        HStack(spacing: 12) {
                            Text("\(index + 1)")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(.cyan.opacity(0.6))
                                .frame(width: 24, alignment: .trailing)
                            Text(title)
                                .font(.system(size: 14, design: .default))
                                .foregroundColor(.primary.opacity(0.85))
                            Spacer()
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 14)

                        if index < supportTitles.count - 1 {
                            Divider()
                                .padding(.leading, 50)
                        }
                    }
                }
                .background(Color(.secondarySystemGroupedBackground))
                .cornerRadius(10)
                .padding(.horizontal, 20)

                Spacer(minLength: 40)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        SupportTitlesView()
    }
}
