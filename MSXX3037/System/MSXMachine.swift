// MSXMachine.swift - MSX Computer System
// Integrates Z80 CPU, VDP, PSG, and Memory

import Foundation
import UIKit

final class MSXMachine {
    // MARK: - Components
    let cpu = Z80()
    let vdp = VDP()
    let psg = PSG()
    let memory = MSXMemory()
    let fdc = FDC()

    // MARK: - Disk System
    var diskMode = false                // true when .dsk is loaded (vs cartridge mode)
    private let diskROMSlot = 1         // Disk ROM stub goes in slot 1 (C-BIOS scans slot 1 first)

    // Disk ROM hook addresses (page 1: 0x4000+offset)
    private let dskioAddr:    UInt16 = 0x4010
    private let dskchgAddr:   UInt16 = 0x4013
    private let getdpbAddr:   UInt16 = 0x4016
    private let mtoffAddr:    UInt16 = 0x401F

    // Frame-based disk boot: C-BIOS 初期化完了後にブートセクタを直接ロード
    private var diskBootPending = false
    private let diskBootFrame = 25  // C-BIOS が VDP/RAM 初期化を完了する十分なフレーム数

    // MARK: - Timing
    static let cpuHz: Double = 3579545.0   // 3.58 MHz
    static let fps: Double = 60.0
    static let cyclesPerFrame = Int(cpuHz / fps)  // ~59658 cycles/frame
    static let linesPerFrame = 262
    static let cyclesPerLine = cyclesPerFrame / linesPerFrame

    private var cycleBudget: Int = 0
    private var psgAudio: PSGAudioEngine?

    // MARK: - State
    var isRunning = false
    var romLoaded = false
    var keyboardRow: UInt8 = 0
    var ppiPortC: UInt8 = 0  // PPI Port C full value (I/O 0xAA)

    // MARK: - Debug
    var frameCount = 0

    // MARK: - Game start detection
    var cartridgeLoaded = false
    var gameStartFired  = false
    /// 現在ロード中のカートリッジ名（セーブデータのディレクトリ名に使用）
    var cartridgeName: String = ""
    /// メインスレッドで呼ばれる: カートリッジのゲーム画面が表示可能になったとき（frame 165 post-reset）
    var onGameReady: (() -> Void)?

    // MARK: - Screen buffer (RGBA pixels)
    private(set) var screenPixels = [UInt32](repeating: 0, count: VDP.screenWidth * VDP.screenHeight)

    // MARK: - BIOS persistence
    private static var biosDirectory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BIOS")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 保存されたBIOS名（nil = α-BIOS（デフォルト））
    static var savedBIOSName: String? {
        UserDefaults.standard.string(forKey: "customBIOSName")
    }

    // MARK: - Init
    init() {
        connectComponents()
        let saved = MSXMachine.savedBIOSName
        if saved != nil && saved != "α-BIOS", let customData = loadSavedCustomBIOS() {
            // ユーザー指定カスタム BIOS
            let bytes = [UInt8](customData)
            memory.loadROM(bytes, slot: 0)
            cpu.reset()
            romLoaded = true
            print("Custom BIOS loaded: \(saved ?? "?") (\(customData.count) bytes)")
        } else {
            // デフォルト: α-BIOS を生成してロード
            loadAlphaBIOSInternal()
        }
    }

    /// Documents/BIOS/custom_bios.rom から読み込み
    private func loadSavedCustomBIOS() -> Data? {
        let fileURL = MSXMachine.biosDirectory.appendingPathComponent("custom_bios.rom")
        return try? Data(contentsOf: fileURL)
    }

    /// α-BIOS をパッチ生成してロード
    func loadAlphaBIOS() {
        UserDefaults.standard.set("α-BIOS", forKey: "customBIOSName")
        // カスタム BIOS ファイルがあれば削除（α-BIOS はランタイム生成）
        let fileURL = MSXMachine.biosDirectory.appendingPathComponent("custom_bios.rom")
        try? FileManager.default.removeItem(at: fileURL)
        loadAlphaBIOSInternal()
    }

    private func loadAlphaBIOSInternal() {
        guard let rom = AlphaBIOS.generate() else {
            print("[α-BIOS] Generation failed, falling back to C-BIOS")
            loadBundledCBIOS()
            return
        }
        memory.loadROM(rom, slot: 0)
        cpu.reset()
        romLoaded = true
        print("α-BIOS loaded: \(rom.count) bytes")
    }

    /// カスタムBIOSを保存して読み込む
    func loadCustomBIOS(data: Data, name: String) {
        // Documents/BIOS/ に永続化
        let fileURL = MSXMachine.biosDirectory.appendingPathComponent("custom_bios.rom")
        try? data.write(to: fileURL)
        UserDefaults.standard.set(name, forKey: "customBIOSName")

        // slot 0 にロード
        let bytes = [UInt8](data)
        memory.loadROM(bytes, slot: 0)
        cpu.reset()
        romLoaded = true
        print("Custom BIOS loaded: \(name) (\(data.count) bytes)")
    }

    // MARK: - Auto-load bundled C-BIOS (α-BIOS 生成失敗時のフォールバック)
    private func loadBundledCBIOS() {
        guard let mainURL = Bundle.main.url(forResource: "cbios_main_msx1", withExtension: "rom"),
              let logoURL = Bundle.main.url(forResource: "cbios_logo_msx1", withExtension: "rom") else {
            print("C-BIOS ROM not found in bundle")
            return
        }
        do {
            // Main BIOS: 32KB → slot 0 (pages 0-1)
            let mainData = try Data(contentsOf: mainURL)
            memory.loadROM([UInt8](mainData), slot: 0)

            // Logo ROM: 16KB → slot 0 page 2 (mapped to 0x8000)
            // We fold it into slot 0's upper half
            let logoData = try Data(contentsOf: logoURL)
            var slot0 = memory.slots[0] ?? [UInt8](repeating: 0xFF, count: 0x10000)
            let logoBytes = [UInt8](logoData)
            let logoLen = min(logoBytes.count, 0x4000)
            slot0[0x8000..<(0x8000 + logoLen)] = logoBytes[0..<logoLen]

            // C-BIOS ブートコードのバグ修正を適用
            AlphaBIOS.applyBootFixes(&slot0)
            memory.slots[0] = slot0

            cpu.reset()
            romLoaded = true
            print("C-BIOS loaded: main=\(mainData.count) bytes, logo=\(logoData.count) bytes")
        } catch {
            print("Failed to load C-BIOS: \(error)")
        }
    }

    private func connectComponents() {
        // CPU memory callbacks
        cpu.memRead = { [unowned self] addr in
            return self.memory.read(addr)
        }
        cpu.memWrite = { [unowned self] addr, val in
            let pc = self.cpu.PC
            // Pass current PC to Memory.write for PC-based bank switch filtering.
            self.memory.write(addr, val, pc: pc)
        }

        // CPU I/O callbacks
        cpu.ioRead = { [unowned self] port in self.ioRead(port) }
        cpu.ioWrite = { [unowned self] port, val in self.ioWrite(port, val) }

        // PSG keyboard/joystick reading
        // PSG R#14 (Port A) on MSX is shared between keyboard and joystick.
        // R#15 (Port B) controls what data appears on R#14:
        //   Bits 3-0: keyboard row select (same lines as PPI Port C)
        //   Bits 5-4: trigger pulse control (active low)
        //   Bit 6: joystick port select (0 = port 1, 1 = port 2)
        //   Bit 7: Kana LED
        //
        // On real hardware, keyboard column data and joystick data are AND-ed
        // together on the PA0-PA5 lines. Since we have no physical joystick,
        // we always return keyboard matrix data for the selected row.
        // Additionally, when cursor keys/SPACE are pressed in the keyboard
        // matrix, we AND in virtual joystick data so that both GTSTCK(0)
        // (keyboard) and GTSTCK(1) (joystick) return the correct state.
        //
        // MSX joystick: bit 0=Up, 1=Down, 2=Left, 3=Right, 4=TrigA, 5=TrigB (0=pressed)
        psg.portARead = { [unowned self] in
            let portB = self.psg.regs[15]
            let row = Int(portB & 0x0F)

            // Start with keyboard matrix data for the selected row
            var result: UInt8 = (row < 9) ? self.memory.keyMatrix[row] : 0xFF

            // AND in virtual joystick data (from cursor keys / SPACE)
            // This makes keyboard cursor keys visible to joystick reads too.
            // On real hardware, joystick and keyboard share the same port lines.
            let km = self.memory.keyMatrix
            var joy: UInt8 = 0xFF  // All bits high = nothing pressed
            let cursorRow = km[8]
            if cursorRow & (1 << 5) == 0 { joy &= ~0x01 }  // UP → joy bit 0
            if cursorRow & (1 << 6) == 0 { joy &= ~0x02 }  // DOWN → joy bit 1
            if cursorRow & (1 << 4) == 0 { joy &= ~0x04 }  // LEFT → joy bit 2
            if cursorRow & (1 << 7) == 0 { joy &= ~0x08 }  // RIGHT → joy bit 3
            if cursorRow & (1 << 0) == 0 { joy &= ~0x10 }  // SPACE → Trigger A
            if km[6] & (1 << 2) == 0 { joy &= ~0x20 }      // GRAPH → Trigger B

            result &= joy
            return result
        }
        psg.portBWrite = { [unowned self] val in
            // Bits 0-3: keyboard row select (also updates PPI keyboard row)
            self.keyboardRow = val & 0x0F
        }
    }

    // MARK: - I/O Port handling
    private func ioRead(_ port: UInt8) -> UInt8 {
        switch port {
        case 0x98:          // VDP data read
            return vdp.readData()
        case 0x99:          // VDP status read
            return vdp.readStatus()
        case 0x9A:          // V9938 palette port (write only)
            return 0xFF
        case 0x9B:          // V9938 indirect register port (write only)
            return 0xFF
        case 0xA8:          // PPI Port A: Primary slot register (read back)
            return memory.primarySlotReg
        case 0xA9:          // PPI Port B: Keyboard row data
            let row = Int(keyboardRow & 0x0F)
            let val = row < 9 ? memory.keyMatrix[row] : 0xFF
            return val
        case 0xAA:          // PPI Port C: read back stored value
            return ppiPortC
        case 0xA2:          // PSG data read (read only mirror)
            let val = psg.readData()
            return val
        default:
            return 0xFF
        }
    }

    private func ioWrite(_ port: UInt8, _ value: UInt8) {
        switch port {
        case 0x98:          // VDP data write
            vdp.writeData(value)
        case 0x99:          // VDP control write
            vdp.writeControl(value)
        case 0x9A:          // V9938 palette port
            vdp.writePalette(value)
        case 0x9B:          // V9938 indirect register port
            vdp.writeIndirectRegister(value)
        case 0xA8:          // PPI Port A: Primary slot register
            memory.primarySlotReg = value
        case 0xAA:          // PPI Port C: keyboard row select (bits 0-3) + misc
            ppiPortC = value
            keyboardRow = value & 0x0F
        case 0xAB:          // PPI Control register
            if value & 0x80 != 0 {
                // Mode set command (bit 7 = 1): configure PPI mode.
                // We handle ports directly, so no action needed.
            } else {
                // Bit set/reset for Port C (bit 7 = 0):
                // Bits 3:1 = bit number (0-7), Bit 0 = 1 to set / 0 to reset
                let bitNum = Int((value >> 1) & 0x07)
                if value & 0x01 != 0 {
                    ppiPortC |= UInt8(1 << bitNum)
                } else {
                    ppiPortC &= ~UInt8(1 << bitNum)
                }
                // Update keyboard row if bits 0-3 changed
                keyboardRow = ppiPortC & 0x0F
            }
        case 0xA0:          // PSG address latch
            psg.writeAddress(value)
        case 0xA1:          // PSG data write
            psg.writeData(value)
        default:
            break
        }
    }

    // MARK: - ROM Loading
    func loadBIOS(data: Data) {
        let bytes = [UInt8](data)
        memory.loadROM(bytes, slot: 0)
        cpu.reset()
        romLoaded = true
    }

    /// カートリッジを読み込む。成功なら true、失敗なら false を返す。
    @discardableResult
    func loadCartridge(data: Data, slot: Int = 1) -> Bool {
        // Detect ZIP-wrapped ROMs (0x50 0x4B = "PK" magic).
        // Many MSX ROMs are distributed inside .zip archives, so we
        // extract the first .rom/.bin entry automatically.
        let romData: Data
        if data.count >= 4 && data[0] == 0x50 && data[1] == 0x4B {
            if let extracted = extractROMFromZIP(data) {
                print(String(format: "[Cart] ZIP: extracted %d bytes", extracted.count))
                romData = extracted
            } else {
                print("[Cart] *** ERROR: Could not find a .rom/.bin file inside the ZIP. Please extract manually.")
                return false
            }
        } else {
            romData = data
        }

        // Clear disk mode BEFORE loading cartridge (disk ROM is in same slot 1)
        if diskMode {
            diskMode = false
            fdc.ejectDisk()
            // Don't nil out slots here — loadCartridge below will overwrite slot 1
        }

        let bytes = [UInt8](romData)
        memory.loadCartridge(bytes, slot: slot)

        // Debug: validate the ROM header that C-BIOS will inspect at 0x4000.
        // Standard MSX cartridges start with 'A'(0x41) 'B'(0x42) followed by
        // the INIT vector (2 bytes LE) that C-BIOS calls on boot.
        if let slotData = memory.slots[slot] {
            let id0 = slotData[0x4000], id1 = slotData[0x4001]
            let initLo = slotData[0x4002], initHi = slotData[0x4003]
            let initAddr = UInt16(initHi) << 8 | UInt16(initLo)
            print(String(format:
                "[Cart] slot=%d  header=0x%02X%02X (need 4142)  INIT=0x%04X  size=%d bytes",
                slot, id0, id1, initAddr, romData.count))
            if id0 != 0x41 || id1 != 0x42 {
                print("[Cart] *** WARNING: 'AB' header missing – C-BIOS will NOT auto-start this ROM")
                return false
            }
        } else {
            return false
        }
        // Don't force slot mapping here.
        // reset() will set primarySlotReg = 0x00 so C-BIOS
        // performs its own slot scan and detects the cartridge.
        cartridgeLoaded = true
        return true
    }

    // MARK: - Disk Image Loading

    /// .dsk ファイルを読み込む。成功なら true を返す。
    @discardableResult
    func loadDisk(data: Data) -> Bool {
        let bytes = [UInt8](data)

        guard fdc.loadDisk(bytes) else {
            print("[Disk] Failed to load disk image (\(bytes.count) bytes)")
            return false
        }

        // Clear any cartridge / MegaROM data first
        memory.clearMegaROM()
        // Clear slot 2 in case it had old data
        memory.slots[2] = nil

        // Generate Disk ROM stub and load into slot 1
        let diskROM = AlphaBIOS.generateDiskROM()
        var slotData = [UInt8](repeating: 0xFF, count: 0x10000)
        for i in 0..<diskROM.count {
            slotData[0x4000 + i] = diskROM[i]
        }
        memory.slots[diskROMSlot] = slotData

        diskMode = true
        diskBootPending = true
        cartridgeLoaded = true
        print("[Disk] Disk mode enabled, Disk ROM stub loaded in slot \(diskROMSlot)")
        return true
    }

    // MARK: - ZIP ROM Extraction

    /// Scan a ZIP archive and return the data of the first .rom or .bin entry.
    /// Supports both stored (method 0) and deflate (method 8) entries.
    private func extractROMFromZIP(_ zip: Data) -> Data? {
        var pos = 0
        while pos + 30 <= zip.count {
            // Local file header signature: PK\x03\x04
            guard zip[pos]   == 0x50, zip[pos+1] == 0x4B,
                  zip[pos+2] == 0x03, zip[pos+3] == 0x04 else { break }

            let method   = Int(zip[pos+8])  | Int(zip[pos+9])  << 8
            let cSize    = Int(zip[pos+18]) | Int(zip[pos+19]) << 8
                         | Int(zip[pos+20]) << 16 | Int(zip[pos+21]) << 24
            let uSize    = Int(zip[pos+22]) | Int(zip[pos+23]) << 8
                         | Int(zip[pos+24]) << 16 | Int(zip[pos+25]) << 24
            let nameLen  = Int(zip[pos+26]) | Int(zip[pos+27]) << 8
            let extraLen = Int(zip[pos+28]) | Int(zip[pos+29]) << 8

            let dataStart = pos + 30 + nameLen + extraLen
            guard cSize >= 0, uSize > 0, dataStart + cSize <= zip.count else {
                pos = dataStart + max(cSize, 0); continue
            }

            // Get entry name and look for ROM/BIN files (skip directories)
            let nameBytes = zip[(pos+30) ..< (pos+30+nameLen)]
            let name = (String(bytes: nameBytes, encoding: .utf8) ?? "").lowercased()

            if !name.hasSuffix("/") && (name.hasSuffix(".rom") || name.hasSuffix(".bin")) {
                let compressed = zip.subdata(in: dataStart ..< (dataStart + cSize))
                if method == 0 {
                    // Stored – no compression
                    print("[Cart] ZIP entry '\(name)' stored (\(uSize) bytes)")
                    return compressed
                } else if method == 8 {
                    // Deflate (raw DEFLATE, RFC 1951)
                    if let out = zipInflate(compressed, outputSize: uSize) {
                        print("[Cart] ZIP entry '\(name)' deflated → \(uSize) bytes")
                        return out
                    }
                }
            }
            pos = dataStart + cSize
        }
        return nil
    }

    /// Decompress a raw DEFLATE stream as used inside ZIP entries (method=8, RFC 1951).
    ///
    /// Uses zlib's inflateInit2 with windowBits=-15 which processes raw DEFLATE
    /// without any zlib/gzip framing – exactly what ZIP stores.
    private func zipInflate(_ data: Data, outputSize: Int) -> Data? {
        var output = Data(count: outputSize)
        let ok = data.withUnsafeBytes { srcBuf -> Bool in
            output.withUnsafeMutableBytes { dstBuf -> Bool in
                guard let src = srcBuf.baseAddress,
                      let dst = dstBuf.baseAddress else { return false }

                var stream = z_stream()
                stream.next_in   = UnsafeMutablePointer(mutating: src.assumingMemoryBound(to: Bytef.self))
                stream.avail_in  = uInt(data.count)
                stream.next_out  = dst.assumingMemoryBound(to: Bytef.self)
                stream.avail_out = uInt(outputSize)

                // windowBits = -15 → raw DEFLATE (no zlib/gzip wrapper)
                guard inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                    return false
                }
                let result = inflate(&stream, Z_FINISH)
                inflateEnd(&stream)
                return result == Z_STREAM_END && Int(stream.total_out) == outputSize
            }
        }
        return ok ? output : nil
    }

    // MARK: - Start/Stop
    func start() {
        guard romLoaded else { return }
        isRunning = true
        psgAudio = PSGAudioEngine(psg: psg)
    }

    func stop() {
        isRunning = false
        psgAudio?.stop()
        psgAudio = nil
    }

    func reset() {
        // Reset slot register to hardware default (all pages = slot 0 = BIOS).
        // C-BIOS then configures RAM in page 3 and scans for cartridges.
        memory.primarySlotReg = 0x00
        // Clear RAM to guarantee C-BIOS cold boot.
        // Without this, C-BIOS finds its warm-start signature still in RAM and
        // may skip the cartridge slot-scan, so a newly loaded cartridge would
        // never be detected.
        memory.ram = [UInt8](repeating: 0, count: 0x10000)
        // Full VDP reset: registers, VRAM, status, latches, palette, commands
        vdp.reset()
        cycleBudget = 0
        frameCount = 0
        gameStartFired = false      // 次のカートリッジブートで再度コールバックを許可

        // Disk mode: re-install Disk ROM stub in slot 1 (RAM was cleared above)
        if diskMode {
            let diskROM = AlphaBIOS.generateDiskROM()
            var slotData = [UInt8](repeating: 0xFF, count: 0x10000)
            for i in 0..<diskROM.count {
                slotData[0x4000 + i] = diskROM[i]
            }
            memory.slots[diskROMSlot] = slotData
            diskBootPending = true  // リセット後に再度ディスクブートを行う
        }

        cpu.reset()
    }

    // MARK: - Execute one frame
    func runFrame() {
        guard isRunning else { return }

        frameCount += 1

        // ── Frame-based disk boot ──
        // C-BIOS が VDP/RAM 初期化を完了した後にブートセクタを直接ロードして実行。
        // AB ヘッダを使わないので C-BIOS のスロットスキャンに干渉しない。
        if diskMode && diskBootPending && frameCount == diskBootFrame {
            diskBootPending = false
            performDiskBoot()
        }

        // C-BIOSは常に frame ~160 でゲームに制御を渡す（決定論的）
        // frame 165 でスプラッシュを解除すると最初のゲームフレームが確実に描画済みになる
        if cartridgeLoaded && !gameStartFired && frameCount == 165 {
            gameStartFired = true
            let cb = onGameReady
            DispatchQueue.main.async { cb?() }
        }

        var cycles = 0
        let target = MSXMachine.cyclesPerFrame

        while cycles < target {
            // Check VDP IRQ
            if vdp.irqPending && cpu.IFF1 {
                let irqCycles = cpu.interrupt()
                if irqCycles > 0 {
                    vdp.irqPending = false
                    cycles += irqCycles
                    continue
                }
            }

            // ── Disk BIOS PC hooks ──
            // Intercept before cpu.step() executes the RET at hook addresses.
            if diskMode {
                let pc = cpu.PC

                // Hook 1: PHYDIO (0x0144) — BIOS-level disk I/O entry point
                // Boot sector code and MSX-DOS call PHYDIO in the BIOS (page 0, slot 0).
                // Since C-BIOS doesn't implement PHYDIO, we intercept it here and
                // route to our handleDSKIO() which reads/writes the .dsk image directly.
                if pc == 0x0144 {
                    let page0Slot = Int(memory.primarySlotReg & 0x03)
                    if page0Slot == 0 {
                        handleDSKIO()
                        cycles += 100
                        continue
                    }
                }

                // Hook 2: Disk ROM entry points (page 1 mapped to diskROMSlot)
                // ブートセクタコードがインタースロットCALLで DSKIO 等を呼ぶケース
                if pc >= 0x4000 && pc < 0x4020 {
                    let page1Slot = Int((memory.primarySlotReg >> 2) & 0x03)
                    if page1Slot == diskROMSlot {
                        var hooked = true
                        switch pc {
                        case dskioAddr:    handleDSKIO()
                        case dskchgAddr:   handleDSKCHG()
                        case getdpbAddr:   handleGETDPB()
                        case mtoffAddr:    handleMTOFF()
                        default:           hooked = false
                        }
                        if hooked {
                            cycles += 100
                            continue
                        }
                    }
                }
            }

            let c = cpu.step()
            cycles += c

            // Update scanline
            let line = (cycles * MSXMachine.linesPerFrame) / target
            if line != vdp.currentLine {
                vdp.currentLine = line
                // TMS9918A collision persistence: on real hardware the VDP
                // re-detects sprite collisions on every scanline during active
                // display (lines 0-191). KEYINT reads VDP status at VBlank,
                // clearing the collision flag before the game's main-loop can
                // read it via RDVDP.  Re-applying the latched collision at
                // line 0 simulates the continuous detection so the flag is
                // available when the game polls.
                if line == 0 && vdp.spriteCollisionLatched {
                    vdp.statusReg |= 0x20
                }
                let vblankLine = vdp.activeLines
                if line == vblankLine {
                    // VBlank start
                    vdp.triggerVBlank()
                    vdp.renderFrame(into: &screenPixels)
                }
            }
        }
    }

    // MARK: - Keyboard
    func setKey(_ row: Int, _ col: Int, pressed: Bool) {
        guard row >= 0 && row < 9 && col >= 0 && col < 8 else { return }
        if pressed {
            memory.keyMatrix[row] &= ~(1 << col)
        } else {
            memory.keyMatrix[row] |= (1 << col)
        }
    }

    // MSX key matrix layout
    // Row 0: 7 6 5 4 3 2 1 0
    // Row 1: ; ] [ \ = - 9 8
    // Row 2: B A ACC / . , ` '
    // Row 3: J I H G F E D C
    // Row 4: R Q P O N M L K
    // Row 5: Z Y X W V U T S
    // Row 6: F3 F2 F1 CODE CAP GRAPH CTRL SHIFT
    // Row 7: RET SEL BS STOP TAB ESC F5 F4

    static let keyMap: [String: (row: Int, col: Int)] = [
        "0": (0,0), "1": (0,1), "2": (0,2), "3": (0,3), "4": (0,4),
        "5": (0,5), "6": (0,6), "7": (0,7),
        "8": (1,0), "9": (1,1), "-": (1,2), "=": (1,3),
        "A": (2,1), "B": (2,0),
        "C": (3,0), "D": (3,1), "E": (3,2), "F": (3,3),
        "G": (3,4), "H": (3,5), "I": (3,6), "J": (3,7),
        "K": (4,0), "L": (4,1), "M": (4,2), "N": (4,3),
        "O": (4,4), "P": (4,5), "Q": (4,6), "R": (4,7),
        "S": (5,0), "T": (5,1), "U": (5,2), "V": (5,3),
        "W": (5,4), "X": (5,5), "Y": (5,6), "Z": (5,7),
        "SHIFT": (6,0), "CTRL": (6,1), "GRAPH": (6,2), "CAP": (6,3),
        "CODE": (6,4),
        "F1": (6,5), "F2": (6,6), "F3": (6,7),
        "F4": (7,0), "F5": (7,1), "ESC": (7,2), "TAB": (7,3),
        "STOP": (7,4), "BS": (7,5), "SEL": (7,6), "RET": (7,7),
        " ": (8,0), "HOME": (8,1), "INS": (8,2), "DEL": (8,3),
        "LEFT": (8,4), "UP": (8,5), "DOWN": (8,6), "RIGHT": (8,7),
    ]

    func pressKey(_ name: String) {
        if let key = MSXMachine.keyMap[name.uppercased()] {
            setKey(key.row, key.col, pressed: true)
        }
    }

    func releaseKey(_ name: String) {
        if let key = MSXMachine.keyMap[name.uppercased()] {
            setKey(key.row, key.col, pressed: false)
        }
    }

    // MARK: - Save State

    /// セーブステートに必要な全データを格納するCodable構造体
    struct SaveState: Codable {
        // Z80
        var cpuA: UInt8; var cpuF: UInt8; var cpuB: UInt8; var cpuC: UInt8
        var cpuD: UInt8; var cpuE: UInt8; var cpuH: UInt8; var cpuL: UInt8
        var cpuA2: UInt8; var cpuF2: UInt8; var cpuB2: UInt8; var cpuC2: UInt8
        var cpuD2: UInt8; var cpuE2: UInt8; var cpuH2: UInt8; var cpuL2: UInt8
        var cpuIXH: UInt8; var cpuIXL: UInt8; var cpuIYH: UInt8; var cpuIYL: UInt8
        var cpuSP: UInt16; var cpuPC: UInt16
        var cpuI: UInt8; var cpuR: UInt8
        var cpuIFF1: Bool; var cpuIFF2: Bool; var cpuIM: UInt8
        var cpuHalted: Bool; var cpuPendingEI: Bool

        // VDP
        var vdpVram: [UInt8]
        var vdpRegs: [UInt8]
        var vdpStatusReg: UInt8        // S#0 (legacy)
        var vdpAddressLatch: UInt16
        var vdpFirstByte: UInt8
        var vdpLatchState: Int
        var vdpReadBuffer: UInt8
        var vdpIrqPending: Bool
        var vdpCurrentLine: Int
        // V9938 extensions (optional for backward compat)
        var vdpStatusRegs: [UInt8]?
        var vdpPaletteRAM: [UInt8]?

        // PSG
        var psgRegs: [UInt8]
        var psgAddressLatch: UInt8
        var psgPortA: UInt8
        var psgPortB: UInt8

        // Memory
        var memRam: [UInt8]
        var memSlot1: [UInt8]?   // カートリッジスロットのみ保存
        var memPageSlot: [UInt8]
        var memPrimarySlotReg: UInt8

        // Machine
        var frameCount: Int
        var keyboardRow: UInt8
        var ppiPortC: UInt8
        var cartridgeLoaded: Bool
        var gameStartFired: Bool

        // Settings (optional for backward compatibility with old save files)
        var settings: SettingsSnapshot?
    }

    /// 現在の状態をスナップショットとして取得
    func createSnapshot() -> SaveState {
        SaveState(
            cpuA: cpu.A, cpuF: cpu.F, cpuB: cpu.B, cpuC: cpu.C,
            cpuD: cpu.D, cpuE: cpu.E, cpuH: cpu.H, cpuL: cpu.L,
            cpuA2: cpu.A2, cpuF2: cpu.F2, cpuB2: cpu.B2, cpuC2: cpu.C2,
            cpuD2: cpu.D2, cpuE2: cpu.E2, cpuH2: cpu.H2, cpuL2: cpu.L2,
            cpuIXH: cpu.IXH, cpuIXL: cpu.IXL, cpuIYH: cpu.IYH, cpuIYL: cpu.IYL,
            cpuSP: cpu.SP, cpuPC: cpu.PC,
            cpuI: cpu.I, cpuR: cpu.R,
            cpuIFF1: cpu.IFF1, cpuIFF2: cpu.IFF2, cpuIM: cpu.IM,
            cpuHalted: cpu.halted, cpuPendingEI: cpu.pendingEI,
            vdpVram: vdp.vram, vdpRegs: vdp.regs,
            vdpStatusReg: vdp.statusRegs[0],
            vdpAddressLatch: vdp.addressLatch,
            vdpFirstByte: vdp.firstByte,
            vdpLatchState: vdp.latchState,
            vdpReadBuffer: vdp.readBuffer,
            vdpIrqPending: vdp.irqPending,
            vdpCurrentLine: vdp.currentLine,
            vdpStatusRegs: vdp.statusRegs,
            vdpPaletteRAM: vdp.paletteRAM,
            psgRegs: psg.regs,
            psgAddressLatch: psg.addressLatch,
            psgPortA: psg.portA, psgPortB: psg.portB,
            memRam: memory.ram,
            memSlot1: memory.slots[1],
            memPageSlot: memory.pageSlot,
            memPrimarySlotReg: memory.primarySlotReg,
            frameCount: frameCount,
            keyboardRow: keyboardRow,
            ppiPortC: ppiPortC,
            cartridgeLoaded: cartridgeLoaded,
            gameStartFired: gameStartFired
        )
    }

    /// スナップショットからマシン状態を復元
    func restoreSnapshot(_ s: SaveState) {
        // Z80
        cpu.A = s.cpuA; cpu.F = s.cpuF; cpu.B = s.cpuB; cpu.C = s.cpuC
        cpu.D = s.cpuD; cpu.E = s.cpuE; cpu.H = s.cpuH; cpu.L = s.cpuL
        cpu.A2 = s.cpuA2; cpu.F2 = s.cpuF2; cpu.B2 = s.cpuB2; cpu.C2 = s.cpuC2
        cpu.D2 = s.cpuD2; cpu.E2 = s.cpuE2; cpu.H2 = s.cpuH2; cpu.L2 = s.cpuL2
        cpu.IXH = s.cpuIXH; cpu.IXL = s.cpuIXL; cpu.IYH = s.cpuIYH; cpu.IYL = s.cpuIYL
        cpu.SP = s.cpuSP; cpu.PC = s.cpuPC
        cpu.I = s.cpuI; cpu.R = s.cpuR
        cpu.IFF1 = s.cpuIFF1; cpu.IFF2 = s.cpuIFF2; cpu.IM = s.cpuIM
        cpu.halted = s.cpuHalted; cpu.pendingEI = s.cpuPendingEI

        // VDP - restore VRAM (backward compat: expand 16KB → 128KB)
        if s.vdpVram.count < VDP.vramSize {
            vdp.vram = s.vdpVram + [UInt8](repeating: 0, count: VDP.vramSize - s.vdpVram.count)
        } else {
            vdp.vram = s.vdpVram
        }
        // Restore registers (backward compat: expand 8 → 47)
        if s.vdpRegs.count < 47 {
            vdp.regs = s.vdpRegs + [UInt8](repeating: 0, count: 47 - s.vdpRegs.count)
        } else {
            vdp.regs = s.vdpRegs
        }
        vdp.statusRegs[0] = s.vdpStatusReg
        if let sr = s.vdpStatusRegs {
            for i in 0..<min(sr.count, 10) { vdp.statusRegs[i] = sr[i] }
        }
        if let pr = s.vdpPaletteRAM, pr.count == 32 {
            vdp.paletteRAM = pr
            // Rebuild RGBA palette from RAM
            for i in 0..<16 {
                let byte0 = pr[i * 2]
                let byte1 = pr[i * 2 + 1]
                let r = Int((byte0 >> 4) & 0x07)
                let b = Int(byte0 & 0x07)
                let g = Int(byte1 & 0x07)
                vdp.palette[i] = (UInt32(r * 255 / 7) << 24) | (UInt32(g * 255 / 7) << 16) | (UInt32(b * 255 / 7) << 8) | 0xFF
            }
        }
        vdp.addressLatch = s.vdpAddressLatch
        vdp.firstByte = s.vdpFirstByte
        vdp.latchState = s.vdpLatchState
        vdp.readBuffer = s.vdpReadBuffer
        vdp.irqPending = s.vdpIrqPending
        vdp.currentLine = s.vdpCurrentLine

        // PSG
        psg.regs = s.psgRegs
        psg.addressLatch = s.psgAddressLatch
        psg.portA = s.psgPortA; psg.portB = s.psgPortB

        // Memory
        memory.ram = s.memRam
        if let slot1 = s.memSlot1 { memory.slots[1] = slot1 }
        memory.primarySlotReg = s.memPrimarySlotReg  // pageSlot も自動更新

        // Machine
        frameCount = s.frameCount
        keyboardRow = s.keyboardRow
        ppiPortC = s.ppiPortC
        cartridgeLoaded = s.cartridgeLoaded
        gameStartFired = s.gameStartFired

        // キーマトリクスをクリア（全キー離す）
        for i in 0..<9 { memory.keyMatrix[i] = 0xFF }

        // 画面を即座に再描画
        vdp.renderFrame(into: &screenPixels)
    }

    // MARK: - Save/Load to File

    /// カートリッジ名からファイルシステム安全な名前を生成
    private static func sanitizeName(_ name: String) -> String {
        let safe = name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        return safe.isEmpty ? "_unknown" : safe
    }

    /// セーブデータのベースディレクトリ
    private static var saveBaseDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("SaveStates")
    }

    /// 現在のカートリッジ用セーブディレクトリ
    private var saveDirectory: URL {
        let dir = MSXMachine.saveBaseDirectory
            .appendingPathComponent(MSXMachine.sanitizeName(cartridgeName))
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// スロット番号に対応するファイルパス（カートリッジ別）
    private func saveURL(slot: Int) -> URL {
        saveDirectory.appendingPathComponent("save_slot\(slot).bin")
    }

    // MARK: - Screenshot / Thumbnail

    /// サムネイル JPEG の保存先 URL
    func thumbnailURL(slot: Int) -> URL {
        saveDirectory.appendingPathComponent("save_slot\(slot)_thumb.jpg")
    }

    /// 現在の screenPixels を UIImage に変換して返す
    ///
    /// screenPixels の各 UInt32 は Swift 値として 0xRRGGBBAA だが、
    /// リトルエンディアン iOS のメモリ上では [AA, BB, GG, RR] の順に並ぶ。
    /// CGContext に直接渡すとチャンネルが入れ替わるため、
    /// R/G/B を明示的に取り出して [R, G, B, 0xFF] バイト列を構築してから渡す。
    func makeScreenshot() -> UIImage? {
        let width  = VDP.screenWidth
        let height = VDP.screenHeight
        let count  = width * height

        // 0xRRGGBBAA → [R, G, B, 0xFF] の連続バイト列に変換
        var bytes = [UInt8](repeating: 0xFF, count: count * 4)
        for i in 0..<count {
            let p = screenPixels[i]
            bytes[i * 4]     = UInt8((p >> 24) & 0xFF)  // R
            bytes[i * 4 + 1] = UInt8((p >> 16) & 0xFF)  // G
            bytes[i * 4 + 2] = UInt8((p >> 8)  & 0xFF)  // B
            // bytes[i * 4 + 3] = 0xFF (alpha, skipped)
        }

        return bytes.withUnsafeMutableBytes { ptr -> UIImage? in
            guard let base = ptr.baseAddress else { return nil }
            guard let ctx = CGContext(
                data: base,
                width: width, height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ), let cgImg = ctx.makeImage() else { return nil }
            return UIImage(cgImage: cgImg)
        }
    }

    /// セーブ時に現在画面をサムネイルとして保存
    private func saveThumbnail(slot: Int) {
        guard let img = makeScreenshot(),
              let data = img.jpegData(compressionQuality: 0.75) else { return }
        try? data.write(to: thumbnailURL(slot: slot))
    }

    /// セーブスロットのサムネイルを読み込む（データがなければ nil）
    func loadThumbnail(slot: Int) -> UIImage? {
        guard let data = try? Data(contentsOf: thumbnailURL(slot: slot)) else { return nil }
        return UIImage(data: data)
    }

    /// 状態をセーブスロットに保存。成功なら true
    /// settings を渡すとセーブデータに設定スナップショットも含める
    @discardableResult
    func saveState(slot: Int, settings: SettingsSnapshot? = nil) -> Bool {
        guard !cartridgeName.isEmpty else {
            print("[Save] ERROR: no cartridge loaded")
            return false
        }
        do {
            var snapshot = createSnapshot()
            snapshot.settings = settings
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: saveURL(slot: slot))
            saveThumbnail(slot: slot)   // 現在画面をサムネイルとして保存
            print("[Save] \(cartridgeName) slot \(slot): \(data.count) bytes saved")
            return true
        } catch {
            print("[Save] ERROR slot \(slot): \(error)")
            return false
        }
    }

    /// セーブスロットから状態を復元。成功時は settings を返す（旧セーブは nil）
    func loadState(slot: Int) -> (success: Bool, settings: SettingsSnapshot?) {
        let url = saveURL(slot: slot)
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("[Load] \(cartridgeName) slot \(slot): no save file")
            return (false, nil)
        }
        do {
            let data = try Data(contentsOf: url)
            let snapshot = try JSONDecoder().decode(SaveState.self, from: data)
            restoreSnapshot(snapshot)
            print("[Load] \(cartridgeName) slot \(slot): restored (\(data.count) bytes)")
            return (true, snapshot.settings)
        } catch {
            print("[Load] ERROR slot \(slot): \(error)")
            return (false, nil)
        }
    }

    /// セーブスロットにデータが存在するか（カートリッジ別）
    func hasSaveData(slot: Int) -> Bool {
        FileManager.default.fileExists(atPath: saveURL(slot: slot).path)
    }

    /// セーブデータの更新日時を取得（カートリッジ別）
    func saveDate(slot: Int) -> Date? {
        let url = saveURL(slot: slot)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return attrs[.modificationDate] as? Date
    }

    // MARK: - Disk BIOS Hook Handlers

    /// RET 命令をシミュレート: スタックからリターンアドレスを POP して PC に設定
    private func diskRET() {
        let lo = UInt16(memory.read(cpu.SP))
        let hi = UInt16(memory.read(cpu.SP &+ 1))
        cpu.SP = cpu.SP &+ 2
        cpu.PC = (hi << 8) | lo
    }

    /// DSKIO — ディスクセクタ読み書き (最重要フック)
    /// 入力: CF=0:読み出し/CF=1:書き込み, A=ドライブ, B=セクタ数,
    ///       C=メディアID, DE=論理セクタ番号, HL=転送先RAMアドレス
    /// 出力: CF=0:成功/CF=1:エラー, B=残セクタ数, A=エラーコード
    private func handleDSKIO() {
        let isWrite = cpu.flagC
        let drive = cpu.A
        let sectorCount = Int(cpu.B)
        let startSector = Int(cpu.DE)
        let bufferAddr = Int(cpu.HL)

        // Drive 0 のみサポート
        guard drive == 0, fdc.diskInserted else {
            cpu.A = 2           // Not ready
            cpu.B = UInt8(sectorCount)
            cpu.flagC = true
            diskRET()
            return
        }

        if isWrite {
            // RAM → Disk
            var data = [UInt8]()
            for i in 0..<(sectorCount * FDC.sectorSize) {
                data.append(memory.ram[(bufferAddr + i) & 0xFFFF])
            }
            if fdc.writeSectors(startSector: startSector, data: data, count: sectorCount) {
                cpu.B = 0
                cpu.flagC = false
            } else {
                cpu.A = 6       // Seek error
                cpu.B = UInt8(sectorCount)
                cpu.flagC = true
            }
        } else {
            // Disk → RAM
            guard let data = fdc.readSectors(startSector: startSector, count: sectorCount) else {
                cpu.A = 2       // Not ready
                cpu.B = UInt8(sectorCount)
                cpu.flagC = true
                diskRET()
                return
            }
            for (i, byte) in data.enumerated() {
                memory.ram[(bufferAddr + i) & 0xFFFF] = byte
            }
            cpu.B = 0
            cpu.flagC = false
        }

        if frameCount <= 300 {
            print(String(format: "[DSKIO] %@ drive=%d sect=%d+%d buf=%04X → %@",
                         isWrite ? "WRITE" : "READ", drive, startSector, sectorCount,
                         bufferAddr, cpu.flagC ? "ERR" : "OK"))
        }
        diskRET()
    }

    /// DSKCHG — ディスク交換チェック
    /// 出力: B=0:不明, B=1:未交換, B=0xFF(-1):交換済み, CF=0:成功
    private func handleDSKCHG() {
        if fdc.diskChanged {
            cpu.B = 0xFF        // Disk changed
            fdc.diskChanged = false
        } else {
            cpu.B = 0x01        // Not changed
        }
        cpu.flagC = false       // Success
        diskRET()
    }

    /// GETDPB — Disk Parameter Block を返す (720KB 3.5" standard)
    /// 出力: HL+1 以降に DPB データを書き込む
    private func handleGETDPB() {
        // DPB for 720KB double-sided double-density (MSX-DOS standard)
        let dpb: [UInt8] = [
            0xF9,                   // Media descriptor
            0x00, 0x02,             // Sector size (512)
            0x0F,                   // Directory mask
            0x04,                   // Directory shift
            0x01,                   // Cluster mask
            0x02,                   // Cluster shift
            0x01, 0x00,             // First FAT sector
            0x02,                   // Number of FATs
            0x70,                   // Max directory entries (112)
            0x0E, 0x00,             // First data sector
            0x5A, 0x02,             // Number of clusters + 1 (602)
            0x03,                   // Sectors per FAT
            0x07, 0x00,             // First directory sector
        ]
        // Write DPB starting at HL+1 (standard MSX convention)
        let addr = Int(cpu.HL) + 1
        for (i, byte) in dpb.enumerated() {
            memory.ram[(addr + i) & 0xFFFF] = byte
        }
        cpu.flagC = false
        diskRET()
    }

    /// MTOFF — モーターオフ (何もしない)
    private func handleMTOFF() {
        fdc.motorOn = false
        diskRET()
    }

    /// performDiskBoot — C-BIOS 初期化完了後にブートセクタを直接ロードして実行
    /// runFrame() からフレームカウンタで呼ばれる（AB ヘッダ不要・H.STKE 不要）。
    private func performDiskBoot() {
        guard let bootSector = fdc.readSector(logicalSector: 0) else {
            print("[Disk Boot] ERROR: Cannot read boot sector")
            return
        }

        // ── ディスクワークエリア変数の設定 ──
        memory.ram[0xF341] = 3                      // RAMAD0: Page 0 RAM slot
        memory.ram[0xF342] = 3                      // RAMAD1: Page 1 RAM slot
        memory.ram[0xF343] = 3                      // RAMAD2: Page 2 RAM slot
        memory.ram[0xF344] = 3                      // RAMAD3: Page 3 RAM slot
        memory.ram[0xFB21] = UInt8(diskROMSlot)     // MASTER: Disk ROM slot number
        memory.ram[0xF347] = 1                      // DEVICE count (1 drive)

        // ブートセクタシグネチャチェック
        let sig = bootSector[0]
        if sig != 0xEB && sig != 0xE9 {
            print(String(format: "[Disk Boot] WARNING: Non-standard boot signature 0x%02X (expected 0xEB/0xE9)", sig))
        }

        // ブートセクタを 0xC000 にコピー
        for (i, byte) in bootSector.enumerated() {
            memory.ram[0xC000 + i] = byte
        }

        // ── CPU 状態を設定してブートコードにジャンプ ──
        // MSX 標準: ブートセクタは 0xC01E から実行される
        // スロット: page 0=BIOS(0), page 1=DiskROM(1), page 2=RAM(3), page 3=RAM(3)
        //          = 0b11_11_01_00 = 0xF4
        cpu.SP = 0xF380
        memory.primarySlotReg = UInt8(0xC0 | 0x30 | (diskROMSlot << 2) | 0x00)
        cpu.PC = 0xC01E

        print(String(format: "[Disk Boot] frame=%d Boot sector → 0xC000, jumping to 0xC01E (sig=0x%02X, SP=%04X, SLOT=%02X)",
                     frameCount, sig, cpu.SP, memory.primarySlotReg))
    }
}
