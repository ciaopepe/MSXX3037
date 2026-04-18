// EmulatorView.swift - Main Emulator UI with Metal rendering

import SwiftUI
import MetalKit
import AVKit
import UniformTypeIdentifiers
import Combine

// MARK: - Metal Renderer
final class MSXRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var pipeline: MTLRenderPipelineState?
    private var crtPipeline: MTLRenderPipelineState?
    private var texture: MTLTexture?
    private var vertexBuffer: MTLBuffer?
    private let machine: MSXMachine
    // Pre-allocated RGBA buffer to avoid 196KB malloc every frame (audio thread contention)
    private var rgbaBuffer = [UInt8](repeating: 0, count: VDP.screenWidth * VDP.screenHeight * 4)
    /// 速度倍率（1.0 = 1draw につき1 machine frame）
    var speedMultiplier: Double = 1.0
    /// CRT フィルタ有効フラグ
    var crtEnabled: Bool = false
    /// 端数フレームの蓄積用
    private var frameAccumulator: Double = 0.0

    init?(mtkView: MTKView, machine: MSXMachine) {
        guard let device = mtkView.device,
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = queue
        self.machine = machine
        super.init()

        mtkView.delegate = self
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.preferredFramesPerSecond = 60
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        setupPipeline(mtkView: mtkView)
        setupTexture()
        setupVertices()
    }

    private func setupPipeline(mtkView: MTKView) {
        let shaderSrc = """
        #include <metal_stdlib>
        using namespace metal;
        struct VertexOut { float4 pos [[position]]; float2 uv; };

        // 共通頂点シェーダー
        vertex VertexOut vert(uint id [[vertex_id]], constant float* v [[buffer(0)]]) {
            uint b = id * 6;
            VertexOut o;
            o.pos = float4(v[b+0], v[b+1], v[b+2], v[b+3]);
            o.uv  = float2(v[b+4], v[b+5]);
            return o;
        }

        // 通常描画（ニアレストネイバー）
        fragment float4 frag(VertexOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
            constexpr sampler s(min_filter::nearest, mag_filter::nearest);
            return tex.sample(s, in.uv);
        }

        // CRT フィルタ描画
        fragment float4 frag_crt(VertexOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
            float2 uv = in.uv;

            // 1. バレル歪み（ブラウン管の球面ガラス）
            float2 c = uv * 2.0 - 1.0;
            uv += c * dot(c, c) * 0.015;
            if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0)
                return float4(0.0, 0.0, 0.0, 1.0);

            // 2. 色収差（RGB の横ズレ）
            constexpr sampler s(min_filter::linear, mag_filter::linear, address::clamp_to_edge);
            float ab = 0.002;
            float r = tex.sample(s, uv + float2(-ab, 0.0)).r;
            float g = tex.sample(s, uv).g;
            float b = tex.sample(s, uv + float2( ab, 0.0)).b;
            float4 color = float4(r, g, b, 1.0);

            // 3. スキャンライン（MSX ピクセル行の境界を暗くする）
            float scanline = abs(sin(uv.y * 212.0 * 3.14159265));
            color.rgb *= 0.65 + 0.35 * scanline;

            // 4. RGB フォスファマスク（スクリーン px 単位の 3 色サブピクセル）
            int col3 = int(in.pos.x) % 3;
            float3 mask;
            if      (col3 == 0) { mask = float3(1.00, 0.75, 0.75); }
            else if (col3 == 1) { mask = float3(0.75, 1.00, 0.75); }
            else                { mask = float3(0.75, 0.75, 1.00); }
            color.rgb *= mask * 1.20;   // avg 0.833 × 1.20 ≈ 1.0 で輝度補償

            // 5. ビネット（コーナー周辺減光）
            float2 vp = (uv - 0.5) * 2.0;
            float vig = 1.0 - smoothstep(0.65, 1.55, length(vp * float2(1.0, 1.05)));
            color.rgb *= max(vig, 0.0);

            // 6. ガンマ補正（CRT 自発光の輝き感）
            color.rgb = pow(clamp(color.rgb, 0.001, 1.0), float3(0.85));

            return color;
        }
        """
        do {
            let lib = try device.makeLibrary(source: shaderSrc, options: nil)
            guard let vert     = lib.makeFunction(name: "vert"),
                  let frag     = lib.makeFunction(name: "frag"),
                  let fragCRT  = lib.makeFunction(name: "frag_crt") else {
                print("[Metal] ERROR: shader functions not found")
                return
            }
            let fmt = mtkView.colorPixelFormat

            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction   = vert
            desc.fragmentFunction = frag
            desc.colorAttachments[0].pixelFormat = fmt
            pipeline = try device.makeRenderPipelineState(descriptor: desc)

            let descCRT = MTLRenderPipelineDescriptor()
            descCRT.vertexFunction   = vert
            descCRT.fragmentFunction = fragCRT
            descCRT.colorAttachments[0].pixelFormat = fmt
            crtPipeline = try device.makeRenderPipelineState(descriptor: descCRT)
        } catch {
            print("[Metal] ERROR: pipeline setup failed: \(error)")
        }
    }

    private func setupTexture() {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: VDP.screenWidth,
            height: VDP.screenHeight,
            mipmapped: false)
        desc.storageMode = .shared
        desc.usage = [.shaderRead]
        texture = device.makeTexture(descriptor: desc)
    }

    private func setupVertices() {
        // Full screen quad as 2 triangles (6 vertices)
        // NDC y=+1(画面上端) → UV v=0(VDP row0) が正しい方向
        let verts: [Float] = [
            -1, -1, 0, 1,   0, 1,
             1, -1, 0, 1,   1, 1,
            -1,  1, 0, 1,   0, 0,
             1, -1, 0, 1,   1, 1,
             1,  1, 0, 1,   1, 0,
            -1,  1, 0, 1,   0, 0,
        ]
        vertexBuffer = device.makeBuffer(bytes: verts, length: verts.count * 4)
    }

    func updateTexture(pixels: [UInt32]) {
        guard let texture = texture else { return }
        // Reuse pre-allocated buffer — no malloc, no audio thread contention
        for (i, p) in pixels.enumerated() {
            rgbaBuffer[i*4+0] = UInt8((p >> 24) & 0xFF)
            rgbaBuffer[i*4+1] = UInt8((p >> 16) & 0xFF)
            rgbaBuffer[i*4+2] = UInt8((p >>  8) & 0xFF)
            rgbaBuffer[i*4+3] = UInt8((p >>  0) & 0xFF)
        }
        texture.replace(
            region: MTLRegionMake2D(0, 0, VDP.screenWidth, VDP.screenHeight),
            mipmapLevel: 0,
            withBytes: rgbaBuffer,
            bytesPerRow: VDP.screenWidth * 4)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        // アキュムレータ方式: 端数フレームも正確に処理
        frameAccumulator += speedMultiplier
        let framesToRun = Int(frameAccumulator)
        frameAccumulator -= Double(framesToRun)
        for _ in 0..<framesToRun {
            machine.runFrame()
        }

        guard let drawable = view.currentDrawable,
              let desc = view.currentRenderPassDescriptor,
              let cmd = commandQueue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: desc) else {
            print(String(format: "[draw] GUARD FAILED pip=%@ tex=%@ vb=%@ drawable=%@ desc=%@",
                pipeline     != nil ? "OK" : "nil",
                texture      != nil ? "OK" : "nil",
                vertexBuffer != nil ? "OK" : "nil",
                view.currentDrawable             != nil ? "OK" : "nil",
                view.currentRenderPassDescriptor != nil ? "OK" : "nil"))
            return
        }

        updateTexture(pixels: machine.screenPixels)
        let activePipeline = crtEnabled ? crtPipeline : pipeline
        if let pip = activePipeline, let vb = vertexBuffer {
            enc.setRenderPipelineState(pip)
            enc.setVertexBuffer(vb, offset: 0, index: 0)
            enc.setFragmentTexture(texture, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}

// MARK: - MTKView wrapper for SwiftUI
struct MetalView: UIViewRepresentable {
    let machine: MSXMachine
    @Binding var renderer: MSXRenderer?

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.backgroundColor = UIColor.clear
        view.isOpaque = false
        let r = MSXRenderer(mtkView: view, machine: machine)
        DispatchQueue.main.async { renderer = r }
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}
}

// MARK: - AirPlay Button
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor       = .white
        v.activeTintColor = UIColor(red: 0, green: 1, blue: 1, alpha: 1)  // .cyan
        v.backgroundColor = .clear
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

// MARK: - Gamepad Overlay（横画面用）
struct GamepadOverlay: View {
    let machine: MSXMachine
    @ObservedObject var config: GamepadConfig

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                // 左: 十字キー（4方向 or 8方向）
                DPadView(machine: machine, is8Direction: config.keySet.is8Direction)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(.leading, max(24, geo.safeAreaInsets.leading + 12))
                    .padding(.bottom, 28)

                // 右: ファイアボタン（2個 or 4個）
                fireButtons
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, max(24, geo.safeAreaInsets.trailing + 12))
                    .padding(.bottom, 28)
            }
        }
    }

    @ViewBuilder
    private var fireButtons: some View {
        if config.keySet.buttonCount <= 2 {
            // キーセットA・B: 2ボタン縦並び
            VStack(spacing: 16) {
                FireButton(label: GamepadConfig.displayLabel(for: config.button1Key),
                           key: config.button1Key, machine: machine, size: 52,
                           turbo: config.button1Turbo)
                FireButton(label: GamepadConfig.displayLabel(for: config.button2Key),
                           key: config.button2Key, machine: machine, size: 66,
                           turbo: config.button2Turbo)
            }
        } else if config.keySet.buttonCount == 4 {
            // キーセットC: 4ボタン ダイヤモンド配置
            VStack(spacing: 8) {
                FireButton(label: GamepadConfig.displayLabel(for: config.button3Key),
                           key: config.button3Key, machine: machine, size: 48,
                           turbo: config.button3Turbo)
                HStack(spacing: 12) {
                    FireButton(label: GamepadConfig.displayLabel(for: config.button1Key),
                               key: config.button1Key, machine: machine, size: 52,
                               turbo: config.button1Turbo)
                    FireButton(label: GamepadConfig.displayLabel(for: config.button2Key),
                               key: config.button2Key, machine: machine, size: 52,
                               turbo: config.button2Turbo)
                }
                FireButton(label: GamepadConfig.displayLabel(for: config.button4Key),
                           key: config.button4Key, machine: machine, size: 48,
                           turbo: config.button4Turbo)
            }
        } else {
            // キーセットD: 6ボタン 2段×3列配置
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    FireButton(label: GamepadConfig.displayLabel(for: config.button4Key),
                               key: config.button4Key, machine: machine, size: 44,
                               turbo: config.button4Turbo)
                    FireButton(label: GamepadConfig.displayLabel(for: config.button5Key),
                               key: config.button5Key, machine: machine, size: 44,
                               turbo: config.button5Turbo)
                    FireButton(label: GamepadConfig.displayLabel(for: config.button6Key),
                               key: config.button6Key, machine: machine, size: 44,
                               turbo: config.button6Turbo)
                }
                HStack(spacing: 8) {
                    FireButton(label: GamepadConfig.displayLabel(for: config.button1Key),
                               key: config.button1Key, machine: machine, size: 50,
                               turbo: config.button1Turbo)
                    FireButton(label: GamepadConfig.displayLabel(for: config.button2Key),
                               key: config.button2Key, machine: machine, size: 50,
                               turbo: config.button2Turbo)
                    FireButton(label: GamepadConfig.displayLabel(for: config.button3Key),
                               key: config.button3Key, machine: machine, size: 50,
                               turbo: config.button3Turbo)
                }
            }
        }
    }
}

// MARK: - 十字キー（D-Pad）
struct DPadView: View {
    let machine: MSXMachine
    let is8Direction: Bool
    @State private var activeKeys = Set<String>()

    private let btnSize: CGFloat = 48
    private let offset: CGFloat  = 52

    var body: some View {
        ZStack {
            // センター装飾
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.08))
                .frame(width: 36, height: 36)

            // 4方向（常時表示）
            dpadBtn(keys: ["UP"],    icon: "chevron.up",    dx:      0, dy: -offset)
            dpadBtn(keys: ["DOWN"],  icon: "chevron.down",  dx:      0, dy:  offset)
            dpadBtn(keys: ["LEFT"],  icon: "chevron.left",  dx: -offset, dy:      0)
            dpadBtn(keys: ["RIGHT"], icon: "chevron.right", dx:  offset, dy:      0)

            // 斜め4方向（8方向モード: 3x3グリッドの角に配置）
            if is8Direction {
                dpadBtn(keys: ["UP", "LEFT"],    icon: "arrow.up.left",    dx: -offset, dy: -offset)
                dpadBtn(keys: ["UP", "RIGHT"],   icon: "arrow.up.right",   dx:  offset, dy: -offset)
                dpadBtn(keys: ["DOWN", "LEFT"],  icon: "arrow.down.left",  dx: -offset, dy:  offset)
                dpadBtn(keys: ["DOWN", "RIGHT"], icon: "arrow.down.right", dx:  offset, dy:  offset)
            }
        }
        .frame(width: is8Direction ? 160 : 156, height: is8Direction ? 160 : 156)
    }

    private func dpadBtn(keys: [String], icon: String, dx: CGFloat, dy: CGFloat) -> some View {
        let pressed = keys.allSatisfy { activeKeys.contains($0) }
        return RoundedRectangle(cornerRadius: 10)
            .fill(pressed ? Color.white.opacity(0.55) : Color.white.opacity(0.18))
            .frame(width: btnSize, height: btnSize)
            .overlay(
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
            )
            .offset(x: dx, y: dy)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        for key in keys {
                            if !activeKeys.contains(key) {
                                activeKeys.insert(key)
                                machine.pressKey(key)
                            }
                        }
                    }
                    .onEnded { _ in
                        for key in keys {
                            activeKeys.remove(key)
                            machine.releaseKey(key)
                        }
                    }
            )
    }
}

// MARK: - ファイアボタン（連射対応）
struct FireButton: View {
    let label: String
    let key: String
    let machine: MSXMachine
    let size: CGFloat
    var turbo: Bool = false
    @State private var pressed = false
    @State private var turboTimer: Timer?
    @State private var turboKeyDown = false  // 連射中の現在のキー状態

    var body: some View {
        Circle()
            .fill(pressed ? Color.white.opacity(0.55) : Color.white.opacity(0.18))
            .frame(width: size, height: size)
            .overlay(
                ZStack {
                    Text(label)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    // 連射インジケーター
                    if turbo {
                        Text("T")
                            .font(.system(size: 8, weight: .heavy, design: .rounded))
                            .foregroundColor(.yellow)
                            .offset(x: size * 0.28, y: -size * 0.28)
                    }
                }
            )
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !pressed {
                            pressed = true
                            if turbo {
                                startTurbo()
                            } else {
                                machine.pressKey(key)
                            }
                        }
                    }
                    .onEnded { _ in
                        pressed = false
                        if turbo {
                            stopTurbo()
                        } else {
                            machine.releaseKey(key)
                        }
                    }
            )
    }

    private func startTurbo() {
        // 最初の押下
        machine.pressKey(key)
        turboKeyDown = true
        // 15Hz で押下/解放を交互に切り替え（1/15秒 ≈ 0.067秒間隔）
        turboTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { _ in
            DispatchQueue.main.async {
                if turboKeyDown {
                    machine.releaseKey(key)
                    turboKeyDown = false
                } else {
                    machine.pressKey(key)
                    turboKeyDown = true
                }
            }
        }
    }

    private func stopTurbo() {
        turboTimer?.invalidate()
        turboTimer = nil
        // キーが押された状態なら確実に離す
        if turboKeyDown {
            machine.releaseKey(key)
            turboKeyDown = false
        }
    }
}

// MARK: - 設定シート
struct SettingsView: View {
    @Binding var speedValue: Double
    @Binding var crtEnabled: Bool
    @ObservedObject var config: GamepadConfig
    @Binding var biosName: String
    let onSelectAlphaBIOS: () -> Void
    let onSelectBIOS: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showingBIOSPicker = false
    @State private var gamepadExpanded = false
    @ObservedObject private var store: StoreKitManager = .shared
    @ObservedObject private var keyboardMgr = ExternalKeyboardManager.shared

    var body: some View {
        NavigationStack {
            Form {
                // BIOS ROM 選択
                Section {
                    HStack {
                        Label(biosName, systemImage: "cpu")
                            .lineLimit(1)
                        Spacer()
                        Menu {
                            Button {
                                onSelectAlphaBIOS()
                            } label: {
                                Label("α-BIOS (Fast Boot)", systemImage: "bolt.fill")
                            }
                            .disabled(biosName == "α-BIOS")

                            Button {
                                showingBIOSPicker = true
                            } label: {
                                Label("Select ROM File…", systemImage: "doc.badge.plus")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.title3)
                                .foregroundColor(.accentColor)
                        }
                    }
                } header: {
                    Text("BIOS")
                }

                // ゲーム速度（スライダー）
                Section {
                    VStack(spacing: 12) {
                        Text(String(format: "%.1fx", speedValue))
                            .font(.system(size: 28, weight: .bold, design: .monospaced))
                            .foregroundColor(.cyan)

                        Slider(value: $speedValue, in: 0.5...2.0, step: 0.1)
                            .tint(.cyan)

                        HStack {
                            Text("0.5x")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("2.0x")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Game Speed")
                }

                // ゲームパッド設定（折りたたみ可能）
                Section {
                    DisclosureGroup(isExpanded: $gamepadExpanded) {
                        // キーセット選択（Premium 未購入は setA のみ / setE はキーボード接続時のみ）
                        Picker("Pad Type", selection: $config.keySet) {
                            ForEach(GamepadKeySet.allCases, id: \.self) { set in
                                if set == .setA {
                                    Text(set.label).tag(set)
                                } else if set == .setE {
                                    if store.isPremium && keyboardMgr.isConnected {
                                        Text(set.label).tag(set)
                                    }
                                } else {
                                    if store.isPremium {
                                        Text(set.label).tag(set)
                                    }
                                }
                            }
                        }
                        if !store.isPremium {
                            NavigationLink {
                                PremiumUnlockView()
                            } label: {
                                Label("Gamepad B / C / D / E は Premium で解放", systemImage: "lock.fill")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } else if !keyboardMgr.isConnected {
                            Label("Gamepad E: available when a keyboard is connected", systemImage: "keyboard")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        // Gamepad E: keyboard mapping info
                        if config.keySet == .setE {
                            VStack(alignment: .leading, spacing: 4) {
                                keyboardMappingRow("⌥ Option",    msxKey: "GRAPH")
                                keyboardMappingRow("⌘ / ⌃",       msxKey: "CODE")
                                keyboardMappingRow("⎋ Esc",        msxKey: "STOP")
                                keyboardMappingRow("⇥ Tab",        msxKey: "SELECT")
                                keyboardMappingRow("F1 – F5",      msxKey: "F1 – F5")
                            }
                            .padding(.vertical, 4)
                        }

                        // ボタン割り当て・連射
                        buttonRow("Btn 1", key: $config.button1Key, turbo: $config.button1Turbo)
                        buttonRow("Btn 2", key: $config.button2Key, turbo: $config.button2Turbo)
                        if config.keySet.buttonCount >= 4 {
                            buttonRow("Btn 3", key: $config.button3Key, turbo: $config.button3Turbo)
                            buttonRow("Btn 4", key: $config.button4Key, turbo: $config.button4Turbo)
                        }
                        if config.keySet.buttonCount >= 6 {
                            buttonRow("Btn 5", key: $config.button5Key, turbo: $config.button5Turbo)
                            buttonRow("Btn 6", key: $config.button6Key, turbo: $config.button6Turbo)
                        }
                    } label: {
                        HStack {
                            Label("Gamepad", systemImage: "gamecontroller")
                            Spacer()
                            Text(config.keySet.label)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                // ディスプレイ設定
                Section {
                    Toggle(isOn: $crtEnabled) {
                        Label("CRT Filter", systemImage: "tv.fill")
                    }
                    .tint(.cyan)
                    if crtEnabled {
                        Text("Scanlines · Barrel distortion · Phosphor mask · Vignette")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("Display")
                }

                // EMuSX ロゴ
                Section {
                    VStack(spacing: 8) {
                        Text("EMuSX")
                            .font(.system(size: 32, weight: .black, design: .rounded))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [Color.cyan, Color.green, Color.cyan],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                        Text("8 bits MSX Emulator")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)

                    NavigationLink {
                        PremiumUnlockView()
                    } label: {
                        HStack {
                            Label("Premium Unlock", systemImage: store.isPremium ? "checkmark.seal.fill" : "lock.open.fill")
                                .foregroundColor(store.isPremium ? .green : .primary)
                            Spacer()
                            if store.isPremium {
                                Text("Unlocked")
                                    .font(.caption)
                                    .foregroundColor(.green)
                            }
                        }
                    }

                    NavigationLink {
                        AboutView()
                    } label: {
                        Label("About EMuSX", systemImage: "info.circle")
                    }

                    NavigationLink {
                        SupportTitlesView()
                    } label: {
                        Label("Support Titles", systemImage: "list.star")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    AirPlayButton()
                        .frame(width: 36, height: 36)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .sheet(isPresented: $showingBIOSPicker) {
            DocumentPicker(
                types: [.init(filenameExtension: "rom")!,
                        .init(filenameExtension: "bin")!,
                        UTType.data],
                onPick: { url in onSelectBIOS(url) }
            )
        }
    }

    private func keyPicker(_ label: String, selection: Binding<String>) -> some View {
        Picker(label, selection: selection) {
            ForEach(GamepadConfig.assignableKeys, id: \.self) { key in
                Text(GamepadConfig.displayLabel(for: key)).tag(key)
            }
        }
    }

    /// ボタン割り当て + 連射トグルを一行に表示
    private func buttonRow(_ label: String, key: Binding<String>, turbo: Binding<Bool>) -> some View {
        HStack {
            keyPicker(label, selection: key)
            Spacer()
            Toggle("Turbo", isOn: turbo)
                .toggleStyle(.switch)
                .fixedSize()
                .font(.caption)
        }
    }

    /// Gamepad E — keyboard mapping row
    private func keyboardMappingRow(_ hwKey: String, msxKey: String) -> some View {
        HStack(spacing: 0) {
            Text(hwKey)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.cyan)
                .frame(width: 80, alignment: .leading)
            Text("→")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .padding(.horizontal, 4)
            Text(msxKey)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
        }
    }
}

// MARK: - Emulator View
struct EmulatorView: View {
    @StateObject private var viewModel = EmulatorViewModel()
    @ObservedObject private var keyboardMgr = ExternalKeyboardManager.shared

    var body: some View {
        GeometryReader { geo in
            let isLandscape = geo.size.width > geo.size.height
            if isLandscape {
                landscapeLayout(geo: geo)
            } else {
                portraitLayout(geo: geo)
            }
        }
        .ignoresSafeArea()
        .sheet(isPresented: $viewModel.showingFilePicker, onDismiss: {
            viewModel.onFilePickerDismiss()
        }) {
            DocumentPicker(
                types: [.init(filenameExtension: "rom")!,
                        .init(filenameExtension: "bin")!,
                        .init(filenameExtension: "dsk")!,
                        UTType.data],
                onPick: { viewModel.handleFilePick($0) }
            )
        }
        .sheet(isPresented: $viewModel.showSettings) {
            SettingsView(
                speedValue: $viewModel.speedValue,
                crtEnabled: $viewModel.crtEnabled,
                config: viewModel.gamepadConfig,
                biosName: $viewModel.biosName,
                onSelectAlphaBIOS: { viewModel.switchToAlphaBIOS() },
                onSelectBIOS: { viewModel.handleBIOSPick($0) }
            )
            .presentationDetents([.large])
        }
        .alert("Error", isPresented: $viewModel.showError) {
            Button("OK") {}
        } message: {
            Text(viewModel.errorMessage)
        }
        .sheet(isPresented: $viewModel.showPremiumSheet) {
            NavigationStack {
                PremiumUnlockView()
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("閉じる") { viewModel.showPremiumSheet = false }
                        }
                    }
            }
            .presentationDetents([.large])
        }
        // Gamepad E: 外部キーボードキャプチャ管理
        .onAppear {
            if viewModel.gamepadConfig.keySet == .setE {
                keyboardMgr.startCapture(machine: viewModel.machine)
            }
        }
        .onChange(of: viewModel.gamepadConfig.keySet) { _, newSet in
            if newSet == .setE {
                keyboardMgr.startCapture(machine: viewModel.machine)
            } else {
                keyboardMgr.stopCapture()
            }
        }
    }

    // MARK: 横画面レイアウト（フルスクリーン + 透過ゲームパッド）
    @ViewBuilder
    private func landscapeLayout(geo: GeometryProxy) -> some View {
        let aspect  = CGFloat(VDP.screenWidth) / CGFloat(VDP.screenHeight)
        let screenH = geo.size.height
        let screenW = min(geo.size.width, screenH * aspect)

        ZStack {
            Color.black

            if viewModel.machine.romLoaded {
                // Metal は常に動かす（オートキー入力が必要なため）
                MetalView(machine: viewModel.machine, renderer: $viewModel.renderer)
                    .frame(width: screenW, height: screenH)
                // C-BIOS ブート中はスプラッシュで隠す（カートリッジ起動まで）
                if viewModel.showSplash {
                    msxx3037Splash
                }
            } else {
                romLoadPrompt
            }

            // 透過ゲームパッド（ゲーム画面が見えているときのみ、実行中）
            if viewModel.loadedCartridge && !viewModel.showSplash && viewModel.isRunning {
                GamepadOverlay(machine: viewModel.machine, config: viewModel.gamepadConfig)
            }

            // ポーズ中: セーブ/ロードパネル
            if !viewModel.isRunning && viewModel.loadedCartridge && !viewModel.showSplash {
                saveLoadOverlay
            }

            // HUD（上段）
            VStack {
                HStack {
                    // 左上: 一時停止ボタン
                    Button { viewModel.togglePause() } label: {
                        Image(systemName: viewModel.isRunning ? "pause.fill" : "play.fill")
                            .font(.system(size: 24))
                            .foregroundColor(viewModel.isRunning ? .green : .white.opacity(0.5))
                    }
                    .padding(.leading, max(16, geo.safeAreaInsets.leading))
                    .padding(.top,     max(12, geo.safeAreaInsets.top))

                    Spacer()

                    // 右上: 速度バッジ + 操作ボタン群
                    HStack(spacing: 14) {
                        Text(viewModel.speedLabel)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.green)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Color.black.opacity(0.55))
                            .cornerRadius(4)

                        hudBtn("gearshape.fill",         .white.opacity(0.7))  { viewModel.openSettings() }
                        hudBtn("tray.and.arrow.down",    .orange.opacity(0.8)) { viewModel.showingFilePicker = true }
                        hudBtn("arrow.counterclockwise", .yellow.opacity(0.8)) { viewModel.resetGame() }
                    }
                    .padding(.trailing, max(16, geo.safeAreaInsets.trailing))
                    .padding(.top,     max(12, geo.safeAreaInsets.top))
                }
                Spacer()
            }
        }
    }

    private func hudBtn(_ icon: String, _ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundColor(color)
        }
    }

    // MARK: 縦画面レイアウト（画面 + コントロールバー + キーボード）
    @ViewBuilder
    private func portraitLayout(geo: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            // ステータスバー分のスペーサー
            Color.black.frame(height: geo.safeAreaInsets.top)

            ZStack {
                screenArea(geo: geo)
                // ポーズ中: セーブ/ロードパネル（縦画面）
                if !viewModel.isRunning && viewModel.loadedCartridge && !viewModel.showSplash {
                    saveLoadOverlay
                }
            }
            controlBar
            KeyboardView(machine: viewModel.machine)

            // ホームインジケーター分のスペーサー
            Color.black.frame(height: geo.safeAreaInsets.bottom)
        }
        .background(Color.black)
        .ignoresSafeArea(.keyboard)
    }

    private func screenArea(geo: GeometryProxy) -> some View {
        let aspect: CGFloat = CGFloat(VDP.screenWidth) / CGFloat(VDP.screenHeight)
        let availH = geo.size.height - geo.safeAreaInsets.top - geo.safeAreaInsets.bottom
        let maxH   = availH * 0.55
        let w      = min(geo.size.width, maxH * aspect)
        let h      = w / aspect

        return ZStack {
            Color.black
            if viewModel.machine.romLoaded {
                // Metal は常に動かす（オートキー入力が必要なため）
                MetalView(machine: viewModel.machine, renderer: $viewModel.renderer)
                    .frame(width: w, height: h)
                // C-BIOS ブート中はスプラッシュで隠す（カートリッジ起動まで）
                if viewModel.showSplash {
                    msxx3037Splash
                }
            } else {
                romLoadPrompt
            }
        }
        .frame(height: maxH)
    }

    /// C-BIOSブート中に重ねて表示するスプラッシュ（カートリッジ起動まで）
    private var msxx3037Splash: some View {
        ZStack {
            // 背景: ダークグラデーション
            LinearGradient(
                colors: [Color.black, Color(red: 0.0, green: 0.05, blue: 0.15), Color.black],
                startPoint: .top,
                endPoint: .bottom
            )

            // 走査線エフェクト
            VStack(spacing: 0) {
                ForEach(0..<80, id: \.self) { _ in
                    Rectangle().fill(Color.white.opacity(0.03)).frame(height: 1)
                    Spacer().frame(height: 3)
                }
            }

            // メインコンテンツ
            VStack(spacing: 16) {
                // "EMuSX" ロゴ
                Text("EMuSX")
                    .font(.system(size: 64, weight: .black, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.cyan, Color.green, Color.cyan],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .shadow(color: .cyan.opacity(0.8), radius: 20)
                    .shadow(color: .green.opacity(0.5), radius: 40)
                    .shadow(color: .cyan.opacity(0.3), radius: 60)

                // サブタイトル
                Text("8 b i t s   M S X   E M U L A T O R")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.green.opacity(0.4), Color.cyan.opacity(0.7), Color.green.opacity(0.4)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .kerning(2)

                // セパレーター
                RoundedRectangle(cornerRadius: 1)
                    .fill(
                        LinearGradient(
                            colors: [.clear, .cyan.opacity(0.6), .green.opacity(0.6), .cyan.opacity(0.6), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: 180, height: 2)
                    .shadow(color: .cyan.opacity(0.5), radius: 6)

                // バージョン
                Text("v1.0")
                    .font(.system(size: 10, weight: .light, design: .monospaced))
                    .foregroundColor(.cyan.opacity(0.3))
            }
        }
    }

    // MARK: - セーブ/ロード オーバーレイ（ポーズ中に表示）
    private var saveLoadOverlay: some View {
        VStack(spacing: 16) {
            Text("PAUSED")
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.7))

            HStack(spacing: 24) {
                ForEach(0..<3, id: \.self) { slot in
                    saveLoadSlot(slot: slot)
                }
            }

            // フィードバックメッセージ
            if let msg = viewModel.saveLoadMessage {
                Text(msg)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.green)
                    .transition(.opacity)
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.black.opacity(0.75))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )
        )
        .animation(.easeInOut(duration: 0.3), value: viewModel.saveLoadMessage)
    }

    private func saveLoadSlot(slot: Int) -> some View {
        let hasData = viewModel.machine.hasSaveData(slot: slot)
        let isPremium = StoreKitManager.shared.isPremium
        let dateStr: String = {
            guard let d = viewModel.machine.saveDate(slot: slot) else { return "Empty" }
            let f = DateFormatter()
            f.dateFormat = "MM/dd HH:mm"
            return f.string(from: d)
        }()

        return VStack(spacing: 8) {
            Text("SLOT \(slot + 1)")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(.cyan)

            if !isPremium {
                Image(systemName: "lock.fill")
                    .foregroundColor(.yellow.opacity(0.8))
                    .font(.system(size: 14))
            } else {
                Text(dateStr)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
            }

            // セーブボタン
            Button {
                if isPremium {
                    viewModel.saveToSlot(slot)
                } else {
                    viewModel.showPremiumRequired()
                }
            } label: {
                Label("SAVE", systemImage: isPremium ? "square.and.arrow.down" : "lock.fill")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .frame(width: 80, height: 32)
                    .background(isPremium ? Color.green.opacity(0.6) : Color.gray.opacity(0.4))
                    .cornerRadius(8)
            }

            // セーブ時のサムネイル
            let thumbnail = viewModel.machine.loadThumbnail(slot: slot)
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.05))
                    .frame(width: 80, height: 60)
                if let thumb = thumbnail {
                    Image(uiImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 80, height: 60)
                        .clipped()
                        .cornerRadius(4)
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 20))
                        .foregroundColor(.white.opacity(0.2))
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
            )

            // ロードボタン
            Button {
                if isPremium {
                    viewModel.loadFromSlot(slot)
                } else {
                    viewModel.showPremiumRequired()
                }
            } label: {
                Label("LOAD", systemImage: isPremium ? "square.and.arrow.up" : "lock.fill")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .frame(width: 80, height: 32)
                    .background(isPremium && hasData ? Color.blue.opacity(0.6) : Color.gray.opacity(0.3))
                    .cornerRadius(8)
            }
            .disabled(isPremium && !hasData)
        }
    }

    private var romLoadPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "memorychip")
                .font(.system(size: 60))
                .foregroundColor(.green)
            Text("Please load an MSX BIOS ROM")
                .foregroundColor(.green)
                .font(.headline)
            Text("Supports Default BIOS (free)\nor original MSX BIOS ROM")
                .foregroundColor(.gray)
                .font(.caption)
                .multilineTextAlignment(.center)
            Button("Open ROM") {
                viewModel.openFilePicker()
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
        }
    }

    private var controlBar: some View {
        HStack(spacing: 20) {
            Button {
                viewModel.openSettings()
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 20))
            }
            .tint(.white.opacity(0.7))

            Button {
                viewModel.openFilePicker()
            } label: {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 20))
            }
            .tint(.orange)

            Button {
                viewModel.resetGame()
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 20))
            }
            .tint(.yellow)

            // 速度設定ボタン
            Button {
                viewModel.openSettings()
            } label: {
                Label(viewModel.speedLabel, systemImage: "speedometer")
                    .font(.caption)
            }
            .tint(.cyan)

            Spacer()

            Button { viewModel.togglePause() } label: {
                Image(systemName: viewModel.isRunning ? "pause.fill" : "play.fill")
                    .font(.system(size: 22))
                    .foregroundColor(viewModel.isRunning ? .green : .white.opacity(0.5))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(white: 0.1))
    }
}

// MARK: - ViewModel
@MainActor
final class EmulatorViewModel: ObservableObject {
    let machine = MSXMachine()
    let gamepadConfig = GamepadConfig.shared

    @Published var renderer: MSXRenderer? = nil {
        didSet { applySpeed(); renderer?.crtEnabled = crtEnabled }
    }
    @Published var crtEnabled: Bool = UserDefaults.standard.bool(forKey: "crtFilter") {
        didSet {
            UserDefaults.standard.set(crtEnabled, forKey: "crtFilter")
            renderer?.crtEnabled = crtEnabled
        }
    }
    @Published var showingFilePicker = false
    @Published var biosName: String = MSXMachine.savedBIOSName ?? "α-BIOS"
    @Published var showError        = false
    @Published var errorMessage     = ""
    @Published var isRunning        = false
    @Published var loadedCartridge  = false
    @Published var showSettings     = false
    /// true の間はスプラッシュで Metal 画面を隠す（C-BIOS ブート中）
    @Published var showSplash       = true

    /// ゲーム速度（0.5x〜3.0x、デフォルト1.0x）
    /// 体感キャリブレーション:
    ///   体感1.0x = multiplier 2.4
    ///   体感1.5x = multiplier 6.0
    ///   → multiplier = 2.4 * pow(speed, 2.26)
    @Published var speedValue: Double = 1.0 {
        didSet { applySpeed() }
    }

    /// 速度ラベル（HUDやコントロールバーに表示）
    var speedLabel: String {
        String(format: "%.1fx", speedValue)
    }

    /// べき乗指数（体感キャリブレーションから算出: log(2.5)/log(1.5)）
    private let speedExponent = log(2.5) / log(1.5)  // ≈ 2.26

    private func applySpeed() {
        renderer?.speedMultiplier = 2.4 * pow(speedValue, speedExponent)
    }

    /// セーブ/ロード操作のフィードバック用
    @Published var saveLoadMessage: String? = nil
    @Published var showPremiumSheet = false

    func togglePause() {
        isRunning.toggle()
        if isRunning { machine.start() } else { machine.stop() }
    }

    /// ファイルピッカーを開く（自動的に一時停止する）
    /// wasRunningBeforePicker: ピッカー表示前に動作中だったかを記録
    private var wasRunningBeforePicker = false

    func openFilePicker() {
        wasRunningBeforePicker = isRunning
        if isRunning {
            isRunning = false
            machine.stop()
        }
        showingFilePicker = true
    }

    /// ファイルピッカーが閉じた時（キャンセル含む）に元の状態を復帰
    func onFilePickerDismiss() {
        // handleFilePick() 内で isRunning=true / machine.start() が
        // 呼ばれなかった場合（キャンセル時）のみ復帰
        if wasRunningBeforePicker && !isRunning {
            isRunning = true
            machine.start()
        }
        wasRunningBeforePicker = false
    }

    /// 設定を開く（自動的に一時停止する）
    func openSettings() {
        if isRunning {
            isRunning = false
            machine.stop()
        }
        showSettings = true
    }

    /// セーブスロットに保存（設定スナップショットも一緒に保存）
    func saveToSlot(_ slot: Int) {
        let settings = gamepadConfig.snapshot(speedValue: speedValue)
        if machine.saveState(slot: slot, settings: settings) {
            saveLoadMessage = "Saved to Slot \(slot + 1)"
            // Clear message after a short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.saveLoadMessage = nil
            }
        } else {
            showError(message: "Failed to save state")
        }
    }

    /// セーブスロットから復元（設定も復元）
    func loadFromSlot(_ slot: Int) {
        let result = machine.loadState(slot: slot)
        if result.success {
            // 設定スナップショットがあれば復元（旧セーブは nil → スキップ）
            if let s = result.settings {
                speedValue = gamepadConfig.apply(s)
            }
            saveLoadMessage = "Loaded Slot \(slot + 1)"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.saveLoadMessage = nil
            }
        } else {
            showError(message: "Failed to load state")
        }
    }

    /// リセット（スプラッシュを再表示し、frame 165 コールバックでゲーム画面を解除）
    func resetGame() {
        machine.stop()       // PSG オーディオをクリーンに停止
        machine.reset()
        isRunning = true
        machine.start()      // PSG オーディオを再初期化して自動実行
        if loadedCartridge { showSplash = true }
    }

    init() {
        if machine.romLoaded {
            isRunning = true
            machine.start()
        }
        // frame 165 (C-BIOS が常にこのフレームでゲームに制御を渡す) でスプラッシュ解除
        machine.onGameReady = { [weak self] in
            withAnimation(.easeIn(duration: 0.4)) { self?.showSplash = false }
        }
    }

    func handleFilePick(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            showError(message: "No permission to access the file")
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            let data = try Data(contentsOf: url)
            if !machine.romLoaded {
                machine.loadBIOS(data: data)
                isRunning = true
                machine.start()
            } else {
                // Premium 未購入の場合、2本目の ROM 読み込みをブロック
                if loadedCartridge && !StoreKitManager.shared.isPremium {
                    showPremiumRequired()
                    return
                }

                let name = url.deletingPathExtension().lastPathComponent
                machine.cartridgeName = name

                let ext = url.pathExtension.lowercased()
                let supportedExts = ["rom", "bin", "zip", "dsk"]
                guard supportedExts.contains(ext) else {
                    showError(message: "非対応の拡張子です: .\(ext)\n対応形式: .rom / .bin / .zip / .dsk")
                    return
                }

                let ok: Bool
                if ext == "dsk" {
                    ok = machine.loadDisk(data: data)
                } else {
                    ok = machine.loadCartridge(data: data)
                }

                if ok {
                    machine.reset()
                    loadedCartridge = true
                    showSplash = true
                    if !isRunning {
                        isRunning = true
                        machine.start()
                    }
                } else {
                    if ext == "dsk" {
                        showError(message: "Invalid disk image.")
                    } else {
                        showError(message: "No cartridge found.")
                    }
                }
            }
        } catch {
            showError(message: "Failed to load file: \(error.localizedDescription)")
        }
    }

    // MARK: - BIOS 選択
    func handleBIOSPick(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            showError(message: "No permission to access the file")
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            let data = try Data(contentsOf: url)
            let name = url.deletingPathExtension().lastPathComponent

            if isRunning {
                isRunning = false
                machine.stop()
            }

            machine.loadCustomBIOS(data: data, name: name)
            biosName = name

            machine.reset()
            isRunning = true
            machine.start()
            showSplash = false
        } catch {
            showError(message: "Failed to load BIOS: \(error.localizedDescription)")
        }
    }

    func switchToAlphaBIOS() {
        if isRunning {
            isRunning = false
            machine.stop()
        }

        machine.loadAlphaBIOS()
        biosName = "α-BIOS"

        machine.reset()
        isRunning = true
        machine.start()
        showSplash = false  // α-BIOS は高速ブート
    }

    private func showError(message: String) {
        errorMessage = message
        showError    = true
    }

    func showPremiumRequired() {
        showPremiumSheet = true
    }
}

// MARK: - Document Picker
struct DocumentPicker: UIViewControllerRepresentable {
    let types: [UTType]
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            urls.first.map { onPick($0) }
        }
    }
}
