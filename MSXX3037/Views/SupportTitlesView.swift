// SupportTitlesView.swift
// サポートタイトル一覧
// タイトルを追加するには supportTitles 配列に文字列を追加してください

import SwiftUI

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// ここにタイトルを追加・編集してください
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
let supportTitles: [String] = [
    "Dragon Quest2","Goonies", "Gradius / Nemesis", "Gradius2 / Nemesis2","Knightmare / Majyo densetsu","Laptick2","Magical Kid Wiz",
]

// MARK: - サポートタイトル一覧ビュー
struct SupportTitlesView: View {
    var body: some View {
        List(supportTitles, id: \.self) { title in
            Text(title)
                .font(.system(.subheadline, design: .monospaced))
        }
        .navigationTitle("Support Titles")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        SupportTitlesView()
    }
}
