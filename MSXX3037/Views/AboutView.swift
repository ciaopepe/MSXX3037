// AboutView.swift
// EMuSX アプリ説明ページ

import SwiftUI

struct AboutView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // EMuSX ロゴ
                VStack(spacing: 8) {
                    Text("EMuSX")
                        .font(.system(size: 48, weight: .black, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color.cyan, Color.green, Color.cyan],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .shadow(color: .cyan.opacity(0.5), radius: 10)

                    Text("8 bits MSX Emulator")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)

                    Text("v1.0")
                        .font(.system(size: 10, weight: .light, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.6))
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

                // 概要
                VStack(alignment: .leading, spacing: 16) {
                    aboutSection(title: "About", text:
                        "EMuSX is an MSX/MSX2 emulator for iOS. " +
                        "This app includes a BIOS-compatible implementation based on the open-source C-BIOS project." +
                        " It does not include or use any original MSX firmware."
                    )

                    aboutSection(title: "Supported Formats", text:
                        "ROM cartridges (.rom)"
                    )

                    aboutSection(title: "Features", text:
                        "- Virtual gamepad with configurable buttons\n" +
                        "- Save states (3 slots)\n" +
                        "- Turbo fire support"
                    )
                    
                    aboutSection(title: "License", text: """
                        This product includes a modified version of C-BIOS \
                        (https://cbios.sourceforge.net/). Modifications were made by 3037.

                        Copyright (c) 2002-2005 BouKiCHi
                        Copyright (c) Reikan
                        Copyright (c) the C-BIOS Association and contributors

                        Redistribution and use in source and binary forms, with or without \
                        modification, are permitted provided that the following conditions are met:

                        1. Redistributions of source code must retain the above copyright \
                        notice, this list of conditions and the following disclaimer.

                        2. Redistributions in binary form must reproduce the above copyright \
                        notice, this list of conditions and the following disclaimer in the \
                        documentation and/or other materials provided with the distribution.

                        THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS \
                        "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT \
                        LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR \
                        A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT \
                        HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, \
                        SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT \
                        LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, \
                        DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY \
                        THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT \
                        (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE \
                        OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

                        All content other than C-BIOS is copyrighted by 3037.
                        """
                    )
                }
                .padding(.horizontal, 20)

                Spacer(minLength: 40)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("About EMuSX")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func aboutSection(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundColor(.cyan)
            Text(text)
                .font(.system(size: 13, design: .default))
                .foregroundColor(.primary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(10)
    }
}

#Preview {
    NavigationStack {
        AboutView()
    }
}
