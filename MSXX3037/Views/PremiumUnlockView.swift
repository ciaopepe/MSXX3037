// PremiumUnlockView.swift
// EMuSX Premium Unlock

import SwiftUI
import StoreKit

struct PremiumUnlockView: View {
    @ObservedObject private var store: StoreKitManager = .shared
    @State private var showAlert = false
    @State private var alertMessage = ""

    // MARK: - Features
    private let features: [(icon: String, color: Color, title: String, description: String)] = [
        ("gamecontroller.fill",  .cyan,   "Gamepad B / C / D",
         "Unlock extended gamepads with 8-directional input and up to 6 buttons."),
        ("square.and.arrow.down.fill", .green, "Save States",
         "Save your game progress at any time across 3 save slots."),
        ("square.and.arrow.up.fill",   .orange, "Load States",
         "Resume your game from any saved slot whenever you like."),
        ("plus.square.on.square",      .purple, "Multiple ROMs",
         "Switch between games freely and load as many ROM titles as you want."),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                headerSection
                featuresSection
                Divider().padding(.horizontal, 20)
                purchaseSection
                Spacer(minLength: 40)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Premium Unlock")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Notice", isPresented: $showAlert) {
            Button("OK", role: .cancel) {
                store.purchaseState = .idle
            }
        } message: {
            Text(alertMessage)
        }
        .onChange(of: store.purchaseState) { state in
            switch state {
            case .success:
                alertMessage = "Thank you for your purchase!\nAll Premium features are now unlocked."
                showAlert = true
            case .failed(let msg):
                alertMessage = msg
                showAlert = true
            default:
                break
            }
        }
    }

    // MARK: - Header
    private var headerSection: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.cyan.opacity(0.3), .green.opacity(0.2)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 90, height: 90)
                Image(systemName: store.isPremium ? "checkmark.seal.fill" : "lock.open.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(
                        LinearGradient(
                            colors: store.isPremium ? [.green, .cyan] : [.cyan, .green],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
            }
            .shadow(color: .cyan.opacity(0.4), radius: 12)
            .padding(.top, 24)

            if store.isPremium {
                Text("Premium Unlocked")
                    .font(.system(size: 22, weight: .black, design: .rounded))
                    .foregroundStyle(LinearGradient(
                        colors: [.green, .cyan], startPoint: .leading, endPoint: .trailing))
                Text("Enjoy all features")
                    .font(.system(size: 13, design: .default))
                    .foregroundColor(.secondary)
            } else {
                Text("EMuSX Premium")
                    .font(.system(size: 22, weight: .black, design: .rounded))
                    .foregroundStyle(LinearGradient(
                        colors: [.cyan, .green], startPoint: .leading, endPoint: .trailing))
                Text("Unlock everything with a one-time purchase")
                    .font(.system(size: 13, design: .default))
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Features
    private var featuresSection: some View {
        VStack(spacing: 10) {
            ForEach(features, id: \.title) { f in
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(f.color.opacity(0.15))
                            .frame(width: 44, height: 44)
                        Image(systemName: f.icon)
                            .font(.system(size: 20))
                            .foregroundColor(f.color)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.primary)
                        Text(f.description)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if store.isPremium {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else {
                        Image(systemName: "lock.fill")
                            .foregroundColor(.secondary.opacity(0.5))
                            .font(.system(size: 13))
                    }
                }
                .padding(14)
                .background(Color(.secondarySystemGroupedBackground))
                .cornerRadius(12)
            }
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Purchase / Restore
    private var purchaseSection: some View {
        VStack(spacing: 14) {
            if store.isPremium {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundColor(.green)
                    Text("Purchased — All features are active")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.green)
                }
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .background(Color.green.opacity(0.12))
                .cornerRadius(14)
                .padding(.horizontal, 20)
            } else {
                // Purchase button
                Button {
                    Task { await store.purchase() }
                } label: {
                    HStack(spacing: 8) {
                        if store.purchaseState == .purchasing {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(.black)
                        } else {
                            Image(systemName: "cart.fill")
                        }
                        if let product = store.product {
                            Text("Buy Now — \(product.displayPrice)")
                                .fontWeight(.bold)
                        } else if store.purchaseState == .loading {
                            Text("Loading price…")
                                .fontWeight(.bold)
                        } else {
                            Text("Buy Now")
                                .fontWeight(.bold)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        LinearGradient(
                            colors: [.cyan, .green],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .foregroundColor(.black)
                    .cornerRadius(14)
                }
                .disabled(store.purchaseState == .purchasing || store.purchaseState == .restoring || store.purchaseState == .loading)
                .padding(.horizontal, 20)

                // Restore button
                Button {
                    Task { await store.restore() }
                } label: {
                    HStack(spacing: 6) {
                        if store.purchaseState == .restoring {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(.accentColor)
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text("Restore Purchase")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Color(.secondarySystemGroupedBackground))
                    .foregroundColor(.accentColor)
                    .cornerRadius(14)
                }
                .disabled(store.purchaseState == .purchasing || store.purchaseState == .restoring)
                .padding(.horizontal, 20)

                // Note
                Text("This is a one-time purchase. It will be active on all devices signed in with the same Apple ID.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }
        }
    }
}

#Preview {
    NavigationStack {
        PremiumUnlockView()
    }
}
