// MSXMachine.swift - MSX Computer System
// Integrates Z80 CPU, VDP, PSG, and Memory

import Foundation

final class MSXMachine {
    // MARK: - Components
    let cpu = Z80()
    let vdp = VDP()
    let psg = PSG()
    let memory = MSXMemory()

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
    private var debugVDP = false       // VDP register write logs (noisy, disabled)
    private var debugCartScan = false  // C-BIOS cartridge slot scan (noisy, disabled)
    private var lastScreenEnabled = false  // Track screen enable transitions
    #if DEBUG
    var pcHistogram = [UInt16: Int]()
    var ppiReadCount = 0       // PPI port B (0xA9) read counter
    var psgR14ReadCount = 0    // PSG R#14 read counter
    var debugInputLog = false  // Log individual I/O reads for input debugging
    #endif

    // Boot-phase PC trace for diagnosing game initialization loops
    private var pcTraceBuffer = [UInt16]()  // circular buffer of recent PCs
    private var pcTraceEnabled = false
    private var pcTraceMaxSize = 200
    // VDP status read counter (port 0x99 reads)
    private var vdpStatusReadCount = 0
    // Slot register change counter (after boot phase)
    private var slotChangeLog = [(frame: Int, value: UInt8, pc: UInt16)]()
    private var slotChangeLogEnabled = true
    // MegaROM diagnostic: log first N bank switch writes for debugging
    private var megaROMWriteLogCount = 0
    // MegaROM INIT detection: log when PC first reaches cartridge INIT address
    private var initAddressHitLogged = false
    // PC filter diagnostic: count blocked mapper writes (PC < 0x4000)
    private var blockedMapperWrites = 0
    private var blockedMapperWriteLogLimit = 10
    // SP tracking: detect when stack pointer enters cartridge ROM area
    private var spInCartAreaLogged = false
    private var lastSPLogValue: UInt16 = 0

    // MARK: - Game start detection
    var cartridgeLoaded = false
    var gameStartFired  = false
    /// 現在ロード中のカートリッジ名（セーブデータのディレクトリ名に使用）
    var cartridgeName: String = ""
    /// メインスレッドで呼ばれる: カートリッジのゲーム画面が表示可能になったとき（frame 165 post-reset）
    var onGameReady: (() -> Void)?

    // MARK: - Screen buffer (RGBA pixels)
    private(set) var screenPixels = [UInt32](repeating: 0, count: VDP.screenWidth * VDP.screenHeight)
    var onFrameReady: (([UInt32]) -> Void)?

    // MARK: - BIOS persistence
    private static var biosDirectory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BIOS")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 保存されたBIOS名（nil = Default BIOS）
    static var savedBIOSName: String? {
        UserDefaults.standard.string(forKey: "customBIOSName")
    }

    // MARK: - Init
    init() {
        connectComponents()
        let saved = MSXMachine.savedBIOSName
        if saved == "α-BIOS" {
            // α-BIOS を生成してロード
            loadAlphaBIOSInternal()
        } else if saved != nil, let customData = loadSavedCustomBIOS() {
            // ユーザー指定カスタム BIOS
            let bytes = [UInt8](customData)
            memory.loadROM(bytes, slot: 0)
            cpu.reset()
            romLoaded = true
            print("Custom BIOS loaded: \(saved ?? "?") (\(customData.count) bytes)")
        } else {
            loadBundledCBIOS()
        }

        // ── DEBUG: Documents/ にある .rom を自動ロード ──
        #if DEBUG
        do {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            if let files = try? FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil) {
                for file in files where file.pathExtension.lowercased() == "rom" {
                    if let data = try? Data(contentsOf: file) {
                        print("[DEBUG] Auto-loading: \(file.lastPathComponent) (\(data.count) bytes)")
                        if loadCartridge(data: data) { reset(); break }
                    }
                }
            }
        }
        #endif
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

    /// Default BIOS (C-BIOS) に戻す
    func revertToDefaultBIOS() {
        // カスタムBIOSファイルを削除
        let fileURL = MSXMachine.biosDirectory.appendingPathComponent("custom_bios.rom")
        try? FileManager.default.removeItem(at: fileURL)
        UserDefaults.standard.removeObject(forKey: "customBIOSName")

        // バンドルC-BIOSを再ロード
        memory.slots[0] = nil
        loadBundledCBIOS()
    }

    // MARK: - Auto-load bundled C-BIOS
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
            // Diagnostic: detect writes to mapper register range that are blocked by PC filter
            if self.memory.megaROMData != nil && addr >= 0x4000 && addr < 0xC000 && pc < 0x4000 {
                let page = Int(addr >> 14)
                if Int(self.memory.pageSlot[page]) == self.memory.megaROMSlot {
                    self.blockedMapperWrites += 1
                    if self.blockedMapperWrites <= self.blockedMapperWriteLogLimit {
                        print(String(format: "[FILTER] Blocked mapper write: addr=%04X val=%02X PC=%04X frame=%d slot=%02X",
                                     addr, val, pc, self.frameCount, self.memory.primarySlotReg))
                    }
                }
            }
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
            vdpStatusReadCount += 1
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
            #if DEBUG
            ppiReadCount += 1
            if debugInputLog {
                print(String(format: "[INPUT] PPI-B row=%d val=%02X", row, val))
            }
            #endif
            return val
        case 0xAA:          // PPI Port C: read back stored value
            return ppiPortC
        case 0xA2:          // PSG data read (read only mirror)
            let val = psg.readData()
            #if DEBUG
            if psg.addressLatch == 14 {
                psgR14ReadCount += 1
                if debugInputLog {
                    let r15 = psg.regs[15]
                    print(String(format: "[INPUT] PSG-R14 r15=%02X (row=%d joy=%d) val=%02X",
                                 r15, r15 & 0x0F, (r15 >> 6) & 1, val))
                }
            }
            #endif
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
            let latchBefore = vdp.latchState
            vdp.writeControl(value)
            // Debug: log VDP register writes
            if debugVDP && latchBefore == 1 && vdp.latchState == 0 && (value & 0x80) != 0 {
                let regNum = Int(value & 0x3F)
                print(String(format: "[VDP] REG[%d] = 0x%02X  (PC=0x%04X)", regNum, regNum < vdp.regs.count ? vdp.regs[regNum] : 0, cpu.PC))
            }
        case 0x9A:          // V9938 palette port
            vdp.writePalette(value)
        case 0x9B:          // V9938 indirect register port
            vdp.writeIndirectRegister(value)
        case 0xA8:          // PPI Port A: Primary slot register
            memory.primarySlotReg = value
            // One-shot: log when C-BIOS maps page 1 → slot 1 (cartridge scan)
            if debugCartScan && (value & 0x0C) == 0x04 {
                print(String(format:
                    "[MSX] C-BIOS cartridge scan: slotReg=0x%02X PC=0x%04X",
                    value, Int(cpu.PC)))
                debugCartScan = false
            }
            // Log slot register changes during early game init (after boot phase starts)
            if slotChangeLogEnabled && cartridgeLoaded && slotChangeLog.count < 80 {
                slotChangeLog.append((frame: frameCount, value: value, pc: cpu.PC))
            }
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

    // MARK: - Sprite Debug Dump to File
    #if DEBUG
    private func dumpSpriteDebugToFile() {
        var lines = [String]()
        let mode = vdp.screenMode
        lines.append("=== Sprite Debug Dump (frame \(frameCount)) ===")
        lines.append("Screen mode: \(mode)")
        let regStr = (0..<16).map { String(format: "R%d=%02X", $0, vdp.regs[$0]) }.joined(separator: " ")
        lines.append("VDP Regs: \(regStr)")

        let satBase = vdp.spriteAttrBase
        let patBase = vdp.spritePatBase
        let isSM2 = (mode == .graphic4 || mode == .graphic5 || mode == .graphic6 || mode == .graphic7)
        let colorTbl = isSM2 ? (satBase &- 512) : 0

        lines.append(String(format: "SAT base: 0x%05X  Pat base: 0x%05X  Mode2: %@  ColorTbl: 0x%05X",
                            satBase, patBase, isSM2 ? "YES" : "NO", colorTbl))
        lines.append(String(format: "spriteSize: %d  spriteMag: %@  screenEnabled: %@",
                            vdp.spriteSize, vdp.spriteMag ? "YES" : "NO", vdp.screenEnabled ? "YES" : "NO"))

        // Dump SAT entries
        lines.append("\n--- SAT entries ---")
        let terminator = (vdp.regs[9] & 0x80 != 0) ? 0xD8 : 0xD0
        for i in 0..<32 {
            let a = satBase + i * 4
            let sy = Int(vdp.vram[a & (VDP.vramSize - 1)])
            let sx = Int(vdp.vram[(a+1) & (VDP.vramSize - 1)])
            let sn = Int(vdp.vram[(a+2) & (VDP.vramSize - 1)])
            let sc = Int(vdp.vram[(a+3) & (VDP.vramSize - 1)])
            if sy == terminator {
                lines.append(String(format: "sprite[%2d]: TERMINATOR (Y=0x%02X)", i, terminator))
                break
            }
            if isSM2 {
                let ct = colorTbl + i * 16
                let colors = (0..<16).map { String(format: "%02X", vdp.vram[(ct + $0) & (VDP.vramSize - 1)]) }.joined(separator: " ")
                lines.append(String(format: "sprite[%2d]: Y=%3d X=%3d name=%3d attr=%02X  CT: %@",
                                    i, sy, sx, sn, sc, colors))
            } else {
                lines.append(String(format: "sprite[%2d]: Y=%3d X=%3d name=%3d color=%d EC=%d",
                                    i, sy, sx, sn, sc & 0x0F, (sc >> 7) & 1))
            }
        }

        // Dump pattern data for first few sprites
        lines.append("\n--- Sprite Pattern data ---")
        for i in 0..<min(4, 32) {
            let a = satBase + i * 4
            let sy = Int(vdp.vram[a & (VDP.vramSize - 1)])
            if sy == terminator { break }
            let sn = Int(vdp.vram[(a+2) & (VDP.vramSize - 1)])
            let pAddr = patBase + sn * 8
            let patBytes = (0..<32).map { String(format: "%02X", vdp.vram[(pAddr + $0) & (VDP.vramSize - 1)]) }.joined(separator: " ")
            lines.append(String(format: "sprite[%d] name=%d pat@%05X: %@", i, sn, pAddr, patBytes))
        }

        // Check VRAM non-zero around SAT/color table
        var satNZ = 0
        for j in 0..<128 { if vdp.vram[(satBase + j) & (VDP.vramSize - 1)] != 0 { satNZ += 1 } }
        var ctNZ = 0
        for j in 0..<512 { if vdp.vram[(colorTbl + j) & (VDP.vramSize - 1)] != 0 { ctNZ += 1 } }
        var patNZ = 0
        for j in 0..<2048 { if vdp.vram[(patBase + j) & (VDP.vramSize - 1)] != 0 { patNZ += 1 } }
        lines.append(String(format: "\nVRAM occupancy: SAT=%d/128 CT=%d/512 PAT=%d/2048", satNZ, ctNZ, patNZ))

        // VDP Command execution counters
        let cmdNames = ["STOP","?1","?2","?3","POINT","PSET","SRCH","LINE",
                        "LMMV","LMMM","LMCM","LMMC","HMMV","HMMM","YMMM","HMMC"]
        lines.append("\n--- VDP Command Counts ---")
        for i in 0..<16 {
            if vdp.commandEngine.cmdCounts[i] > 0 {
                lines.append(String(format: "  %@ (0x%X): %d", cmdNames[i], i, vdp.commandEngine.cmdCounts[i]))
            }
        }

        // VDP Command log (last 30 commands)
        lines.append("\n--- VDP Command Log (last \(vdp.commandEngine.cmdLog.count)) ---")
        for (idx, entry) in vdp.commandEngine.cmdLog.enumerated() {
            let name = cmdNames[Int(entry.cmd)]
            let logOp = entry.cmdReg & 0x0F
            let tFlag = (logOp & 0x08) != 0
            let opNames = ["IMP","AND","OR","XOR","NOT","?5","?6","?7"]
            let opName = opNames[Int(logOp & 0x07)]
            lines.append(String(format: "  [%2d] %@ reg=%02X SX=%d SY=%d DX=%d DY=%d NX=%d NY=%d CLR=%02X ARG=%02X op=%@%@",
                idx, name, entry.cmdReg, entry.sx, entry.sy, entry.dx, entry.dy, entry.nx, entry.ny,
                entry.clr, entry.arg, opName, tFlag ? "+T" : ""))
        }

        // VRAM page scan: count non-zero bytes per 32-line block
        lines.append("\n--- VRAM Page Scan (non-zero bytes per 32-line block, SCREEN 5) ---")
        for blockY in stride(from: 0, to: 1024, by: 32) {
            var nz = 0
            let baseAddr = blockY * 128
            for offset in 0..<(32 * 128) {
                if vdp.vram[(baseAddr + offset) & (VDP.vramSize - 1)] != 0 { nz += 1 }
            }
            if nz > 0 {
                let page = blockY / 256
                let localY = blockY % 256
                lines.append(String(format: "  Y=%4d-%4d (page%d Y%d-%d) addr=%05X: %d/%d non-zero",
                    blockY, blockY+31, page, localY, localY+31,
                    baseAddr & (VDP.vramSize - 1), nz, 32*128))
            }
        }

        // Dump specific VRAM lines in visible area (Y=80-120, center of game area)
        lines.append("\n--- VRAM visible area sample (Y=96-99, page 0) ---")
        for y in 96..<100 {
            let rowBase = y * 128
            let rowBytes = (0..<128).map { String(format: "%02X", vdp.vram[(rowBase + $0) & (VDP.vramSize - 1)]) }
            // Show first 64 bytes (128 pixels)
            lines.append(String(format: "  Y=%3d: %@", y, rowBytes.prefix(64).joined(separator: " ")))
        }

        let text = lines.joined(separator: "\n")
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let fileURL = docs.appendingPathComponent("sprite_debug.txt")
        try? text.write(to: fileURL, atomically: true, encoding: .utf8)
        print("[DEBUG] Sprite debug written to \(fileURL.path)")
    }
    #endif

    // MARK: - VDP State Dump (diagnostic)
    private func dumpVDPState() {
        let nameBase = vdp.nameTableBase
        // GFX2 uses masked addresses (only top bit matters for each table)
        let isGFX2 = vdp.screenMode == .graphicsII
        let patBase  = isGFX2 ? (vdp.patternTableBase & 0x2000) : vdp.patternTableBase
        let colBase  = isGFX2 ? (vdp.colorTableBase   & 0x2000) : vdp.colorTableBase

        // Dump all 8 VDP registers
        print(String(format:
            "[VDP DUMP frame=%d] REG: %02X %02X %02X %02X %02X %02X %02X %02X  mode=%@",
            frameCount,
            Int(vdp.regs[0]), Int(vdp.regs[1]), Int(vdp.regs[2]), Int(vdp.regs[3]),
            Int(vdp.regs[4]), Int(vdp.regs[5]), Int(vdp.regs[6]), Int(vdp.regs[7]),
            isGFX2 ? "GFX2" : "other"))

        // Show table base addresses (GFX2-corrected)
        print(String(format:
            "[VDP DUMP frame=%d] nameBase=%04X patBase=%04X colBase=%04X (GFX2-masked=%@)",
            frameCount, nameBase, patBase, colBase, isGFX2 ? "yes" : "no"))

        // Name table: full 24 rows × 32 cols dump
        for r in 0..<24 {
            let rowHex = (0..<32).map { String(format: "%02X", vdp.vram[(nameBase + r*32 + $0) & 0x3FFF]) }.joined(separator: " ")
            print("[VDP DUMP frame=\(frameCount)] name[row\(String(format:"%02d",r))]: \(rowHex)")
        }

        // Pattern table: first 32 bytes (GFX2-corrected base)
        let patHex = (0..<32).map { String(format: "%02X", vdp.vram[(patBase + $0) & 0x3FFF]) }.joined(separator: " ")
        print("[VDP DUMP frame=\(frameCount)] pat [\(String(format:"%04X", patBase))]: \(patHex)")

        // Color table: first 32 bytes (GFX2-corrected base)
        let colHex = (0..<32).map { String(format: "%02X", vdp.vram[(colBase + $0) & 0x3FFF]) }.joined(separator: " ")
        print("[VDP DUMP frame=\(frameCount)] col [\(String(format:"%04X", colBase))]: \(colHex)")

        if isGFX2 {
            // In GFX2, also check char 0xF0 (common game char) pattern & color
            let char = 0xF0
            let patF0 = (0..<8).map { String(format: "%02X", vdp.vram[(patBase + char*8 + $0) & 0x3FFF]) }.joined(separator: " ")
            let colF0 = (0..<8).map { String(format: "%02X", vdp.vram[(colBase + char*8 + $0) & 0x3FFF]) }.joined(separator: " ")
            print(String(format: "[VDP DUMP frame=%d] pat[%04X] (char 0xF0): %@",
                         frameCount, (patBase + char*8) & 0x3FFF, patF0))
            print(String(format: "[VDP DUMP frame=%d] col[%04X] (char 0xF0): %@",
                         frameCount, (colBase + char*8) & 0x3FFF, colF0))

            // Count non-zero bytes in each major region
            let patRegion = vdp.vram[0..<0x1800].filter { $0 != 0 }.count
            let nameRegion = vdp.vram[0x1800..<0x2000].filter { $0 != 0 }.count
            let colRegion  = vdp.vram[0x2000..<0x3800].filter { $0 != 0 }.count
            print("[VDP DUMP frame=\(frameCount)] non-zero: pat(0000-17FF)=\(patRegion)  name(1800-1FFF)=\(nameRegion)  col(2000-37FF)=\(colRegion)")
        }

        // Sprite attribute table and pattern table
        let spAttrBase = Int(vdp.regs[5] & 0x7F) << 7
        let spPatBase  = Int(vdp.regs[6] & 0x07) << 11
        let spSize = (vdp.regs[1] & 0x02) != 0 ? 16 : 8
        print(String(format: "[VDP DUMP frame=%d] sprite: attrBase=%04X patBase=%04X size=%d",
                     frameCount, spAttrBase, spPatBase, spSize))
        // First 4 sprites
        for i in 0..<4 {
            let a = spAttrBase + i * 4
            let sy = Int(vdp.vram[a & 0x3FFF])
            let sx = Int(vdp.vram[(a+1) & 0x3FFF])
            let sn = Int(vdp.vram[(a+2) & 0x3FFF])
            let sc = Int(vdp.vram[(a+3) & 0x3FFF])
            if sy == 0xD0 {
                print(String(format: "[VDP DUMP frame=%d] sprite[%d]: TERMINATOR", frameCount, i)); break
            }
            let p0 = vdp.vram[(spPatBase + sn*8) & 0x3FFF]
            print(String(format: "[VDP DUMP frame=%d] sprite[%d]: y=%3d x=%3d name=%3d color=%d pat[0]=%02X",
                         frameCount, i, sy, sx, sn, sc & 0x0F, p0))
        }
        // Sprite pattern table fill
        let spPatNZ = (0..<2048).filter { vdp.vram[(spPatBase + $0) & 0x3FFF] != 0 }.count
        print("[VDP DUMP frame=\(frameCount)] sprite pat(\(String(format:"%04X",spPatBase))): \(spPatNZ)/2048 non-zero")

        // JIFFY counter
        let jiffy = memory.read(0xFC9E)
        print("[VDP DUMP frame=\(frameCount)] JIFFY(0xFC9E)=\(jiffy)")

        // Total VRAM stats
        let nonZero = vdp.vram.filter { $0 != 0 }.count
        let nonFF   = vdp.vram.filter { $0 != 0xFF }.count
        print("[VDP DUMP frame=\(frameCount)] VRAM total: \(nonZero) non-zero, \(nonFF) non-FF bytes out of \(VDP.vramSize)")
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
        // Reset debug counters so we see fresh logs after reset
        frameCount = 0
        debugVDP = false
        debugCartScan = false
        lastScreenEnabled = false
        megaROMWriteLogCount = 0
        initAddressHitLogged = false
        blockedMapperWrites = 0
        spInCartAreaLogged = false
        lastSPLogValue = 0
        gameStartFired = false      // 次のカートリッジブートで再度コールバックを許可
        vdp.debugRenderGFX2 = false
        vdp.debugPixelCount = false
        vdp.debugSpriteSAT  = false
        vdp.debugRenderGFX4 = false
        cpu.reset()
    }

    // MARK: - Execute one frame
    func runFrame() {
        guard isRunning else { return }

        frameCount += 1

        // C-BIOSは常に frame ~160 でゲームに制御を渡す（決定論的）
        // frame 165 でスプラッシュを解除すると最初のゲームフレームが確実に描画済みになる
        if cartridgeLoaded && !gameStartFired && frameCount == 165 {
            gameStartFired = true
            let cb = onGameReady
            DispatchQueue.main.async { cb?() }
        }

        // Track screenEnabled transitions (silent)
        let se = vdp.screenEnabled
        if se != lastScreenEnabled {
            lastScreenEnabled = se
            if se { vdp.debugPixelCount = true }
        }

        // Debug: log at frame 1 only (periodic logging disabled to reduce noise)
        if frameCount == 1 {
            let seStr = vdp.screenEnabled ? "YES" : "no"
            let modeStr: String
            let isGFX2 = vdp.screenMode == .graphicsII
            switch vdp.screenMode {
            case .text:       modeStr = "TEXT"
            case .graphicsI:  modeStr = "GFX1"
            case .graphicsII: modeStr = "GFX2"
            case .multicolor: modeStr = "MCOL"
            case .graphic3:   modeStr = "GFX3"
            case .graphic4:   modeStr = "GFX4"
            case .graphic5:   modeStr = "GFX5"
            case .graphic6:   modeStr = "GFX6"
            case .graphic7:   modeStr = "GFX7"
            }
            let nameBase = vdp.nameTableBase
            // Use GFX2-corrected patBase for meaningful diagnostic
            let patBase  = isGFX2 ? (vdp.patternTableBase & 0x2000) : vdp.patternTableBase
            let vramName = Int(vdp.vram[nameBase & 0x3FFF])
            let vramPat  = Int(vdp.vram[patBase  & 0x3FFF])
            // Count unique tiles in name table (768 bytes) to detect real game graphics
            let nameTableBytes = (0..<768).map { vdp.vram[(nameBase + $0) & 0x3FFF] }
            let uniqueTiles = Set(nameTableBytes).count
            // JIFFY counter at 0xFC9E: incremented by C-BIOS VBlank ISR each frame
            let jiffy = memory.read(0xFC9E)
            // Sprite pattern table non-zero count (spot-check)
            let spPatBase = Int(vdp.regs[6] & 0x07) << 11
            let spPatNZ = (0..<256).filter { vdp.vram[(spPatBase + $0) & 0x3FFF] != 0 }.count
            // Sample pixel at center of rendered frame (reflects actual display content)
            let cx = VDP.screenWidth / 2, cy = VDP.screenHeight / 2
            let centerPix = screenPixels[cy * VDP.screenWidth + cx]
            // Also sample top-left area (row 1, col 5) to detect title/score area
            let topPix = screenPixels[8 * VDP.screenWidth + 40]
            print(String(format:
                "[MSX frame=%d] PC=%04X SP=%04X slot=%02X " +
                "R0=%02X R1=%02X R2=%02X R3=%02X R4=%02X R7=%02X " +
                "mode=\(modeStr) screen=\(seStr) JIFFY=%d " +
                "name@%04X=%02X uniqueTiles=%d pat@%04X(gfx2=%@)=%02X spPatNZ=%d " +
                "pix[center]=%08X pix[top]=%08X",
                frameCount, Int(cpu.PC), Int(cpu.SP), Int(memory.primarySlotReg),
                Int(vdp.regs[0]), Int(vdp.regs[1]), Int(vdp.regs[2]),
                Int(vdp.regs[3]), Int(vdp.regs[4]), Int(vdp.regs[7]),
                Int(jiffy),
                nameBase, vramName, uniqueTiles, patBase, isGFX2 ? "yes" : "no", vramPat,
                spPatNZ,
                centerPix, topPix))
        }

        // VDP+VRAM state dump (disabled - game never reaches SCREEN 5)
        // if frameCount == 180 || frameCount == 300 || frameCount == 420 { dumpVDPState() }

        // ── Periodic sprite / VDP command diagnostic (SCREEN 5 games) ──
        if cartridgeLoaded && (frameCount == 300 || frameCount == 600 || frameCount == 900) {
            let mode = vdp.screenMode
            let r8 = vdp.regs[8]
            let spd = (r8 & 0x02) != 0  // Sprite Disable
            let r1 = vdp.regs[1]
            let sprSize = (r1 & 0x02 != 0) ? 16 : 8
            let sprMag = (r1 & 0x01 != 0) ? 2 : 1
            // Sprite render stats from VDP
            print(String(format: "[SPR DIAG @%d] spriteRenderFrames=%d lastPixels=%d (frames where SPD=0 and sprites drawn)",
                         frameCount, vdp.spriteRenderCount, vdp.lastSpritePixelCount))
            let attrBase = vdp.spriteAttrBase
            let patBase = vdp.spritePatBase
            let lines = vdp.activeLines
            let terminator = lines > 192 ? 0xD8 : 0xD0

            print(String(format: "[SPR DIAG @%d] mode=%@ R#1=%02X R#5=%02X R#6=%02X R#8=%02X R#11=%02X SPD=%d size=%d mag=%d",
                         frameCount, "\(mode)", r1, vdp.regs[5], vdp.regs[6], r8, vdp.regs[11],
                         spd ? 1 : 0, sprSize, sprMag))
            print(String(format: "[SPR DIAG @%d] attrBase=%05X patBase=%05X lines=%d term=0x%02X",
                         frameCount, attrBase, patBase, lines, terminator))

            // Dump first 8 sprite entries from SAT
            var activeCount = 0
            for i in 0..<min(32, 8) {
                let a = attrBase + i * 4
                let sy = Int(vdp.vram[a & (VDP.vramSize - 1)])
                if sy == terminator {
                    print(String(format: "[SPR DIAG @%d] sprite[%d]: TERMINATOR (0x%02X) — %d active sprites",
                                 frameCount, i, terminator, activeCount))
                    break
                }
                activeCount += 1
                let sx = Int(vdp.vram[(a+1) & (VDP.vramSize - 1)])
                let sn = Int(vdp.vram[(a+2) & (VDP.vramSize - 1)])
                let sa = vdp.vram[(a+3) & (VDP.vramSize - 1)]

                // Check pattern data (first 8 bytes)
                let patAddr = patBase + sn * 8
                var patNonZero = 0
                var patBytes = [String]()
                let patSize = sprSize == 16 ? 32 : 8  // 16x16 uses 4 patterns
                for j in 0..<patSize {
                    let b = vdp.vram[(patAddr + j) & (VDP.vramSize - 1)]
                    if b != 0 { patNonZero += 1 }
                    if j < 8 { patBytes.append(String(format: "%02X", b)) }
                }

                // Mode 2 color table
                let isSM2 = (mode == .graphic3 || mode == .graphic4 || mode == .graphic5 ||
                              mode == .graphic6 || mode == .graphic7)
                var colorStr = ""
                if isSM2 {
                    let colorBase = attrBase &- 512
                    var colors = [String]()
                    for j in 0..<min(sprSize, 16) {
                        let cb = vdp.vram[(colorBase + i * 16 + j) & (VDP.vramSize - 1)]
                        colors.append(String(format: "%02X", cb))
                    }
                    colorStr = " ct=[\(colors.joined(separator: " "))]"
                }

                print(String(format: "[SPR DIAG @%d] sprite[%d]: y=%3d x=%3d name=%3d attr=%02X patNZ=%d/%d pat0=[%@]%@",
                             frameCount, i, sy, sx, sn, sa, patNonZero, patSize,
                             patBytes.joined(separator: " "), colorStr))

                if i == 7 && activeCount == 8 {
                    print(String(format: "[SPR DIAG @%d] (showing first 8 of possibly more sprites)", frameCount))
                }
            }

            // VDP command engine summary
            let ce = vdp.commandEngine!
            let cmdNames = ["STOP","?1","?2","?3","POINT","PSET","SRCH","LINE",
                            "LMMV","LMMM","LMCM","LMMC","HMMV","HMMM","YMMM","HMMC"]
            var cmdSummary = [String]()
            for j in 0..<16 {
                if ce.cmdCounts[j] > 0 {
                    cmdSummary.append("\(cmdNames[j])=\(ce.cmdCounts[j])")
                }
            }
            print(String(format: "[SPR DIAG @%d] VDP cmds: %@ hmmm_play=%d hmmm_status=%d lmmm_play=%d",
                         frameCount,
                         cmdSummary.isEmpty ? "(none)" : cmdSummary.joined(separator: " "),
                         ce.hmmmPlayArea, ce.hmmmStatusBar, ce.lmmmPlayArea))

            // Last 5 VDP commands from log
            let logCount = min(ce.cmdLog.count, 5)
            if logCount > 0 {
                for j in (ce.cmdLog.count - logCount)..<ce.cmdLog.count {
                    let e = ce.cmdLog[j]
                    print(String(format: "[SPR DIAG @%d] cmdLog[%d]: %@ SX=%d SY=%d DX=%d DY=%d NX=%d NY=%d CLR=%02X ARG=%02X",
                                 frameCount, j, cmdNames[Int(e.cmd)], e.sx, e.sy, e.dx, e.dy, e.nx, e.ny, e.clr, e.arg))
                }
            }

            // VRAM stats for sprite areas
            var patAreaNZ = 0
            for j in 0..<(256 * 8) {  // check first 256 patterns (2KB)
                if vdp.vram[(patBase + j) & (VDP.vramSize - 1)] != 0 { patAreaNZ += 1 }
            }
            print(String(format: "[SPR DIAG @%d] patArea(%05X): %d/2048 non-zero bytes",
                         frameCount, patBase, patAreaNZ))

            // ── VRAM scan: find actual SAT location ──
            // Scan candidate addresses (128-byte aligned) around the expected region
            // and dump hex to find where the real SAT data is
            let scanStart = max(0, attrBase - 0x400)  // 1KB before current attrBase
            let scanEnd = min(VDP.vramSize, attrBase + 0x400)  // 1KB after
            print(String(format: "[VRAM SCAN @%d] Scanning %05X-%05X for SAT-like data (current attrBase=%05X):",
                         frameCount, scanStart, scanEnd, attrBase))

            // Also compute alternative SAT addresses for comparison
            let altBase_FC = (Int(vdp.regs[11] & 0x03) << 15) | (Int(vdp.regs[5] & 0xFC) << 7)
            let altSAT_FC = altBase_FC + 0x200
            let altSAT_FE = (Int(vdp.regs[11] & 0x03) << 15) | (Int(vdp.regs[5] & 0xFE) << 7)
            let altSAT_A7 = altSAT_FE | 0x80
            print(String(format: "[VRAM SCAN @%d] Candidates: &FC+200=%05X  &FE=%05X  &FE|80=%05X  current=%05X",
                         frameCount, altSAT_FC, altSAT_FE, altSAT_A7, attrBase))

            // Dump 32 bytes at each candidate address
            for candidate in [altSAT_FE, altSAT_A7, altSAT_FC, altSAT_FC - 0x80, altSAT_FC + 0x80] {
                let addr = candidate & (VDP.vramSize - 1)
                var bytes = [String]()
                var nz = 0
                for j in 0..<32 {
                    let b = vdp.vram[(addr + j) & (VDP.vramSize - 1)]
                    bytes.append(String(format: "%02X", b))
                    if b != 0 { nz += 1 }
                }
                // Also check full 128 bytes for non-zero count
                var nz128 = 0
                for j in 0..<128 {
                    if vdp.vram[(addr + j) & (VDP.vramSize - 1)] != 0 { nz128 += 1 }
                }
                print(String(format: "[VRAM SCAN @%d] @%05X (nz=%d/128): %@",
                             frameCount, addr, nz128, bytes.joined(separator: " ")))
            }

            // Dump full 0xF000-0xF800 with non-zero summary per 128-byte block
            print(String(format: "[VRAM SCAN @%d] Block non-zero summary:", frameCount))
            var blockSummary = [String]()
            let blkStart = attrBase & 0x1F000  // align to 4KB page
            for blk in stride(from: blkStart, to: min(blkStart + 0x1000, VDP.vramSize), by: 128) {
                var nzBlock = 0
                for j in 0..<128 {
                    if vdp.vram[(blk + j) & (VDP.vramSize - 1)] != 0 { nzBlock += 1 }
                }
                if nzBlock > 0 {
                    blockSummary.append(String(format: "%05X:%d", blk, nzBlock))
                }
            }
            print(String(format: "[VRAM SCAN @%d] %@", frameCount, blockSummary.joined(separator: " ")))
        }

        // ── White pixel diagnostic (SCREEN 5) ──
        // Scan visible VRAM area for color 15 (white) pixels to identify
        // the source of "diagonal white lines" artifact.
        if cartridgeLoaded && (frameCount == 300 || frameCount == 600) {
            let mode = vdp.screenMode
            if mode == .graphic4 {
                let page = (Int(vdp.regs[2]) >> 5) & 0x03
                let pageOffset = page * 0x08000
                var white4bppCount = 0
                var firstWhiteLocations = [String]()
                for y in 0..<vdp.activeLines {
                    for xByte in 0..<128 {
                        let addr = (pageOffset + y * 128 + xByte) & (VDP.vramSize - 1)
                        let b = vdp.vram[addr]
                        let hiNibble = (b >> 4) & 0x0F
                        let loNibble = b & 0x0F
                        if hiNibble == 0x0F {
                            white4bppCount += 1
                            if firstWhiteLocations.count < 10 {
                                firstWhiteLocations.append(String(format: "(%d,%d)=F_", xByte * 2, y))
                            }
                        }
                        if loNibble == 0x0F {
                            white4bppCount += 1
                            if firstWhiteLocations.count < 10 {
                                firstWhiteLocations.append(String(format: "(%d,%d)=_F", xByte * 2 + 1, y))
                            }
                        }
                    }
                }
                print(String(format: "[WHITE DIAG @%d] page=%d white(0xF) pixels=%d  first: %@",
                             frameCount, page, white4bppCount,
                             firstWhiteLocations.isEmpty ? "none" : firstWhiteLocations.joined(separator: " ")))
                // Also dump palette entry 15 to see what "white" maps to
                let pal15 = vdp.palette[15]
                print(String(format: "[WHITE DIAG @%d] palette[15]=%08X  LINE cmd count=%d",
                             frameCount, pal15, vdp.commandEngine.cmdCounts[7]))
            }
        }

        // Auto keypress injection disabled (game doesn't boot yet)
        #if DEBUG
        #endif

        // Early-frame diagnostics: track boot progress of MegaROM games
        if cartridgeLoaded && (frameCount == 5 || frameCount == 10 || frameCount == 50 || frameCount == 170) {
            let htimi0 = memory.ram[0xFD9F]  // H.TIMI hook byte 0
            let htimi1 = memory.ram[0xFDA0]
            let htimi2 = memory.ram[0xFDA1]
            let hstke0 = memory.ram[0xFEDA]  // H.STKE hook byte 0
            let hstke1 = memory.ram[0xFEDB]
            let hstke2 = memory.ram[0xFEDC]
            let msxVer = memory.read(0x002D)  // via slot mapping (page 0)
            print(String(format: "[BOOT @%d] PC=%04X SP=%04X SLOT=%02X banks=[%d,%d,%d,%d] bankSW=%d",
                         frameCount, cpu.PC, cpu.SP, memory.primarySlotReg,
                         memory.megaROMBanks[0], memory.megaROMBanks[1],
                         memory.megaROMBanks[2], memory.megaROMBanks[3],
                         memory.bankSwitchCount))
            print(String(format: "[BOOT @%d] R#0=%02X R#1=%02X mode=%@ H.TIMI=%02X %02X %02X H.STKE=%02X %02X %02X MSXVER=%d",
                         frameCount, vdp.regs[0], vdp.regs[1], "\(vdp.screenMode)",
                         htimi0, htimi1, htimi2, hstke0, hstke1, hstke2, msxVer))
            // Extended diagnostics: IFF state, VDP reads, CPU registers
            print(String(format: "[BOOT @%d] IFF1=%d IFF2=%d IM=%d halted=%d A=%02X HL=%04X DE=%04X BC=%04X vdpStatRd=%d",
                         frameCount,
                         cpu.IFF1 ? 1 : 0, cpu.IFF2 ? 1 : 0, cpu.IM, cpu.halted ? 1 : 0,
                         cpu.A, UInt16(cpu.H) << 8 | UInt16(cpu.L),
                         UInt16(cpu.D) << 8 | UInt16(cpu.E),
                         UInt16(cpu.B) << 8 | UInt16(cpu.C),
                         vdpStatusReadCount))
            // Dump RAM/code around current PC (32 bytes)
            let pc = Int(cpu.PC)
            var codeBytes = [String]()
            for i in 0..<32 {
                let addr = (pc + i) & 0xFFFF
                codeBytes.append(String(format: "%02X", memory.ram[addr]))
            }
            print(String(format: "[BOOT @%d] RAM@PC(%04X): %@",
                         frameCount, pc, codeBytes.joined(separator: " ")))
            // Also dump what memory.read() returns (respects slot mapping)
            var slotBytes = [String]()
            for i in 0..<32 {
                let addr = UInt16(truncatingIfNeeded: pc + i)
                slotBytes.append(String(format: "%02X", memory.read(addr)))
            }
            print(String(format: "[BOOT @%d] MEM@PC(%04X): %@",
                         frameCount, pc, slotBytes.joined(separator: " ")))
            // PC filter diagnostic summary
            print(String(format: "[BOOT @%d] blockedMapperWrites=%d initHit=%@",
                         frameCount, blockedMapperWrites,
                         initAddressHitLogged ? "YES" : "no"))
            // Dump what the cartridge header looks like from slot 1
            if let slot1 = memory.slots[1] {
                let h0 = slot1[0x4000], h1 = slot1[0x4001], h2 = slot1[0x4002], h3 = slot1[0x4003]
                print(String(format: "[BOOT @%d] Cart slot1 header: %02X %02X INIT=%04X  MegaROM@4000=%02X",
                             frameCount, h0, h1, UInt16(h3) << 8 | UInt16(h2),
                             memory.megaROMData != nil ? memory.megaROMData![0] : 0xFF))
            }

        }

        // Dump PC trace at frame 52 (after capturing frames 48-52)
        if cartridgeLoaded && frameCount == 52 && !pcTraceBuffer.isEmpty {
            print("[TRACE @52] PC trace (\(pcTraceBuffer.count) samples, frames 48-52):")
            // Show first 100 PCs with opcodes
            let count = min(pcTraceBuffer.count, 100)
            var traceLines = [String]()
            for i in 0..<count {
                let pc = pcTraceBuffer[i]
                // Read opcode from RAM (the game runs from RAM)
                let op = memory.ram[Int(pc)]
                let op2 = memory.ram[Int((pc &+ 1) & 0xFFFF)]
                let op3 = memory.ram[Int((pc &+ 2) & 0xFFFF)]
                traceLines.append(String(format: "%04X:%02X %02X %02X", pc, op, op2, op3))
            }
            // Print in groups of 10 for readability
            for start in stride(from: 0, to: traceLines.count, by: 10) {
                let end = min(start + 10, traceLines.count)
                print("[TRACE] \(traceLines[start..<end].joined(separator: "  "))")
            }
            // Also show PC frequency histogram
            var hist = [UInt16: Int]()
            for pc in pcTraceBuffer { hist[pc, default: 0] += 1 }
            let sorted = hist.sorted { $0.value > $1.value }.prefix(20)
            var histStr = sorted.map { String(format: "%04X×%d", $0.key, $0.value) }
            print("[TRACE] Top PCs: \(histStr.joined(separator: " "))")
            pcTraceBuffer.removeAll()
        }

        // Dump slot change log at frame 55
        if cartridgeLoaded && frameCount == 55 && !slotChangeLog.isEmpty {
            print("[SLOT LOG] \(slotChangeLog.count) slot changes during boot:")
            for (i, entry) in slotChangeLog.enumerated() {
                print(String(format: "[SLOT #%d] frame=%d slotReg=%02X PC=%04X (p0=%d p1=%d p2=%d p3=%d)",
                             i, entry.frame, entry.value, entry.pc,
                             entry.value & 0x03, (entry.value >> 2) & 0x03,
                             (entry.value >> 4) & 0x03, (entry.value >> 6) & 0x03))
            }
            slotChangeLogEnabled = false  // stop logging
        }

        // Late diagnostic disabled (game stuck at boot, not useful)
        // if frameCount == 200 ... if frameCount == 3800 ...

        // debugVDP is false by default; no need to turn off

        // Enable PC trace for specific frames to diagnose stuck loops
        pcTraceEnabled = (frameCount >= 48 && frameCount <= 52) && cartridgeLoaded
        if pcTraceEnabled && frameCount == 48 { pcTraceBuffer.removeAll() }

        var cycles = 0
        let target = MSXMachine.cyclesPerFrame

        #if DEBUG
        // PC histogram: sample every 100 instructions during gameplay frames
        var stepCount = 0
        #endif

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

            // Capture PC trace for diagnosis
            if pcTraceEnabled && pcTraceBuffer.count < pcTraceMaxSize {
                pcTraceBuffer.append(cpu.PC)
            }

            // Detect when PC first reaches cartridge INIT address
            if !initAddressHitLogged && memory.megaROMInitAddress != 0 && cpu.PC == memory.megaROMInitAddress {
                initAddressHitLogged = true
                // Read MSXVER through slot mapping (correct) not raw RAM
                let msxVer = memory.read(0x002D)
                print(String(format: "[INIT HIT] PC reached INIT=%04X at frame=%d SP=%04X SLOT=%02X banks=[%d,%d,%d,%d] MSXVER=%d",
                             memory.megaROMInitAddress, frameCount, cpu.SP, memory.primarySlotReg,
                             memory.megaROMBanks[0], memory.megaROMBanks[1],
                             memory.megaROMBanks[2], memory.megaROMBanks[3],
                             msxVer))
                // Dump first 32 bytes of code at INIT address (read via slot mapping)
                var initBytes = [String]()
                for i in 0..<32 {
                    let addr = UInt16(truncatingIfNeeded: Int(memory.megaROMInitAddress) + i)
                    initBytes.append(String(format: "%02X", memory.read(addr)))
                }
                print(String(format: "[INIT HIT] code@%04X: %@",
                             memory.megaROMInitAddress, initBytes.joined(separator: " ")))
            }

            let c = cpu.step()
            cycles += c

            // SP tracking: detect when SP enters cartridge area (0x8000-0xBFFF)
            // This causes stack operations (PUSH/CALL) to trigger mapper bank switches
            if memory.megaROMData != nil && !spInCartAreaLogged {
                let sp = cpu.SP
                if sp >= 0x8000 && sp < 0xC000 {
                    let page2Slot = (memory.primarySlotReg >> 4) & 0x03
                    if Int(page2Slot) == memory.megaROMSlot {
                        spInCartAreaLogged = true
                        print(String(format: "[SP ALERT] SP=%04X entered cart area! PC=%04X frame=%d SLOT=%02X banks=[%d,%d,%d,%d]",
                                     sp, cpu.PC, frameCount, memory.primarySlotReg,
                                     memory.megaROMBanks[0], memory.megaROMBanks[1],
                                     memory.megaROMBanks[2], memory.megaROMBanks[3]))
                        // Dump stack contents (16 bytes from SP upward)
                        var stackBytes = [String]()
                        for i in 0..<16 {
                            let addr = UInt16(truncatingIfNeeded: Int(sp) + i)
                            stackBytes.append(String(format: "%02X", memory.read(addr)))
                        }
                        print(String(format: "[SP ALERT] stack@%04X: %@", sp, stackBytes.joined(separator: " ")))
                    }
                }
            }

            #if DEBUG
            stepCount += 1
            if frameCount >= 800 && frameCount <= 810 && stepCount % 64 == 0 {
                let pc = cpu.PC
                pcHistogram[pc, default: 0] += 1
            }
            #endif

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
                    onFrameReady?(screenPixels)
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
}
