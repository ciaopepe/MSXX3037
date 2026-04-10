// VDP.swift - V9938 Video Display Processor (TMS9918A 上位互換)
// MSX1 (TMS9918A) 全モード + MSX2 (V9938) SCREEN 4-8 対応

import Foundation

final class VDP {
    // MARK: - Constants
    static let vramSize  = 0x20000  // 128KB VRAM (V9938)
    static let screenWidth  = 256
    static let screenHeight = 212   // V9938 max (TMS9918A = 192)
    static let totalLines   = 262   // NTSC

    // MARK: - State
    var vram = [UInt8](repeating: 0, count: vramSize)
    var regs = [UInt8](repeating: 0, count: 47)      // R#0 - R#46
    var statusRegs = [UInt8](repeating: 0, count: 10) // S#0 - S#9

    // Address latch (TMS9918A two-byte protocol)
    var addressLatch: UInt16 = 0
    var firstByte: UInt8 = 0
    var latchState: Int = 0  // 0 = first byte, 1 = second byte
    var readBuffer: UInt8 = 0

    // Interrupt
    var irqPending: Bool = false
    var irqEnabled: Bool { regs[1] & 0x20 != 0 }

    // Sprite collision persistence
    var spriteCollisionLatched: Bool = false

    // Diagnostics (one-shot, reset by MSXMachine.reset)
    var debugRenderGFX2 = true
    var debugPixelCount = true
    var debugSpriteSAT = true
    var debugRenderGFX4 = true

    // Line counter
    var currentLine: Int = 0

    // V9938 palette: 16 entries (raw bytes + pre-computed RGBA)
    var paletteRAM = [UInt8](repeating: 0, count: 32) // 16 × 2 bytes [0RRR0BBB, 00000GGG]
    var palette = [UInt32](repeating: 0, count: 16)
    var paletteLatchByte: UInt8 = 0
    var paletteLatchFirst = true // true = waiting for 1st byte

    // V9938 command engine
    var commandEngine: VDPCommandEngine!

    // R#14 tracking: MSX1 games never write R#14, so auto-increment on 16KB
    // boundary wrap should be suppressed to prevent address corruption.
    // Only enable auto-increment after explicit R#14 write (MSX2 games).
    var r14ExplicitlySet = false

    // Debug: direct VRAM write tracking
    var directWriteCountPage0 = 0   // writes to page 0 (0x00000-0x07FFF)
    var directWriteCountPage1 = 0   // writes to page 1 (0x08000-0x0FFFF)
    var directReadCountPage0 = 0
    var directReadCountPage1 = 0

    // Backward compat alias
    var statusReg: UInt8 {
        get { statusRegs[0] }
        set { statusRegs[0] = newValue }
    }

    // MARK: - Default palette (TMS9918A compatible)
    static let defaultPalette: [UInt32] = [
        0x000000FF, // 0: Transparent (Black)
        0x000000FF, // 1: Black
        0x3EB849FF, // 2: Medium Green
        0x74D07DFF, // 3: Light Green
        0x5955E0FF, // 4: Dark Blue
        0x8076F1FF, // 5: Light Blue
        0xB95E51FF, // 6: Dark Red
        0x65DBEFFF, // 7: Cyan
        0xDB6559FF, // 8: Medium Red
        0xFF897DFF, // 9: Light Red
        0xCCC35EFF, // 10: Dark Yellow
        0xDED087FF, // 11: Light Yellow
        0x3AA241FF, // 12: Dark Green
        0xB766B5FF, // 13: Magenta
        0xCCCCCCFF, // 14: Gray
        0xFFFFFFFF, // 15: White
    ]

    // Default palette in V9938 raw format (for paletteRAM init)
    static let defaultPaletteRAM: [UInt8] = [
        0x00, 0x00, // 0: transparent
        0x00, 0x00, // 1: black
        0x11, 0x06, // 2: medium green
        0x33, 0x07, // 3: light green
        0x17, 0x01, // 4: dark blue
        0x27, 0x03, // 5: light blue
        0x51, 0x01, // 6: dark red
        0x27, 0x06, // 7: cyan
        0x71, 0x01, // 8: medium red
        0x73, 0x03, // 9: light red
        0x61, 0x06, // 10: dark yellow
        0x64, 0x06, // 11: light yellow
        0x11, 0x04, // 12: dark green
        0x65, 0x02, // 13: magenta
        0x55, 0x05, // 14: gray
        0x77, 0x07, // 15: white
    ]

    init() {
        commandEngine = VDPCommandEngine(vdp: self)
        resetPalette()
    }

    /// Reset all VDP state to power-on defaults.
    func reset() {
        vram = [UInt8](repeating: 0, count: VDP.vramSize)
        regs = [UInt8](repeating: 0, count: 47)
        statusRegs = [UInt8](repeating: 0, count: 10)
        addressLatch = 0
        firstByte = 0
        latchState = 0
        readBuffer = 0
        irqPending = false
        spriteCollisionLatched = false
        currentLine = 0
        paletteLatchFirst = true
        paletteLatchByte = 0
        r14ExplicitlySet = false
        resetPalette()
        commandEngine.reset()
    }

    private func resetPalette() {
        paletteRAM = VDP.defaultPaletteRAM
        for i in 0..<16 {
            palette[i] = VDP.defaultPalette[i]
        }
    }

    // MARK: - Register accessors

    // TMS9918A compatible table base addresses
    var nameTableBase: Int    { Int(regs[2] & 0x0F) << 10 }
    var colorTableBase: Int   { Int(regs[3]) << 6 }
    var patternTableBase: Int { Int(regs[4] & 0x07) << 11 }
    var spriteAttrBase: Int {
        // V9938 Sprite Mode 2 (SCREEN 4-7): R#5 bit 0 must be 1 but is
        // IGNORED for address calculation.  A14-A8 come from R#5[7:1].
        // TMS9918A Sprite Mode 1 (SCREEN 1-3): R#5 bit 7 is unused,
        // A13-A7 come from R#5[6:0].
        let highBits = Int(regs[11] & 0x03) << 15
        let isSM2 = (screenMode == .graphic3 || screenMode == .graphic4 ||
                      screenMode == .graphic5 || screenMode == .graphic6 ||
                      screenMode == .graphic7)
        let r5mask: UInt8 = isSM2 ? 0xFE : 0x7F
        let lowBits  = Int(regs[5] & r5mask) << 7
        return highBits | lowBits
    }
    // V9938: R#6[5:0] = A16-A11 (6 ビット, 128KB VRAM 対応)
    // TMS9918A は R#6[2:0] の 3 ビットのみ使用するが、
    // VRAM マスクにより上位ビットは安全に無視される。
    var spritePatBase: Int    { Int(regs[6] & 0x3F) << 11 }
    var bgColor: UInt8        { regs[7] & 0x0F }
    var fgColor: UInt8        { (regs[7] >> 4) & 0x0F }
    var screenEnabled: Bool   { regs[1] & 0x40 != 0 }
    var spriteSize: Int       { regs[1] & 0x02 != 0 ? 16 : 8 }
    var spriteMag: Bool       { regs[1] & 0x01 != 0 }

    // V9938 extended
    var is212Lines: Bool { regs[9] & 0x80 != 0 }
    var activeLines: Int { is212Lines ? 212 : 192 }

    /// Full 17-bit VRAM address from R#14 (high 3 bits) + addressLatch (low 14 bits)
    var fullAddress: Int {
        let high = Int(regs[14] & 0x07) << 14
        return (high | Int(addressLatch)) & (VDP.vramSize - 1)
    }

    // MARK: - Screen modes
    enum ScreenMode {
        case text        // SCREEN 0: 40x24 text
        case graphicsI   // SCREEN 1: 32x24 tiles
        case graphicsII  // SCREEN 2: 32x24 bitmap
        case multicolor  // SCREEN 3: 4x4 blocks
        case graphic3    // SCREEN 4: Enhanced GFX II (V9938)
        case graphic4    // SCREEN 5: 256×212, 4bpp
        case graphic5    // SCREEN 6: 512×212, 2bpp
        case graphic6    // SCREEN 7: 512×212, 4bpp
        case graphic7    // SCREEN 8: 256×212, 8bpp
    }

    var screenMode: ScreenMode {
        let m1 = (regs[1] >> 4) & 1
        let m2 = (regs[0] >> 1) & 1
        let m3 = (regs[1] >> 3) & 1
        let m4 = (regs[0] >> 2) & 1
        let m5 = (regs[0] >> 3) & 1

        // V9938 extended modes (M4/M5 bits)
        if m4 != 0 || m5 != 0 {
            let mode = (m5 << 2) | (m4 << 1) | m3
            switch mode {
            case 0b010: return .graphic3   // M5=0 M4=1 M3=0
            case 0b011: return .graphic3   // M5=0 M4=1 M3=1 (alt)
            case 0b100: return .graphic4   // M5=1 M4=0 M3=0
            case 0b101: return .graphic5   // M5=1 M4=0 M3=1
            case 0b110: return .graphic6   // M5=1 M4=1 M3=0
            case 0b111: return .graphic7   // M5=1 M4=1 M3=1
            default:    return .graphic4   // fallback
            }
        }

        // TMS9918A modes
        if m1 == 1 { return .text }
        if m2 == 1 { return .graphicsII }
        if m3 == 1 { return .multicolor }
        return .graphicsI
    }

    /// Bytes per pixel row for current bitmap mode (used by command engine)
    var bytesPerPixelRow: Int {
        switch screenMode {
        case .graphic4: return 128    // 256px × 4bpp / 8
        case .graphic5: return 128    // 512px × 2bpp / 8
        case .graphic6: return 256    // 512px × 4bpp / 8
        case .graphic7: return 256    // 256px × 8bpp / 8
        default: return 128
        }
    }

    /// Pixels per byte for current bitmap mode
    var pixelsPerByte: Int {
        switch screenMode {
        case .graphic4: return 2
        case .graphic5: return 4
        case .graphic6: return 2
        case .graphic7: return 1
        default: return 2
        }
    }

    // MARK: - Control Port Write (0x99)
    func writeControl(_ value: UInt8) {
        if latchState == 0 {
            firstByte = value
            latchState = 1
        } else {
            latchState = 0
            if value & 0x80 != 0 {
                // Register write: V9938 supports R#0 - R#46
                let regNum = Int(value & 0x3F)
                if regNum < regs.count {
                    writeRegister(regNum, firstByte)
                }
            } else {
                // Address setup
                addressLatch = (UInt16(value & 0x3F) << 8) | UInt16(firstByte)
                if value & 0x40 == 0 {
                    // Read mode: pre-read from full VRAM address
                    readBuffer = vram[fullAddress]
                    incrementAddress()
                }
            }
        }
    }

    /// V9938 register write with side effects
    private func writeRegister(_ reg: Int, _ value: UInt8) {
        let oldValue = regs[reg]
        regs[reg] = value

        // Log V9938 mode changes
        if reg == 0 && (value & 0x0C) != (oldValue & 0x0C) {
            print(String(format: "[VDP] R#0 mode change: %02X → %02X (M5=%d M4=%d)", oldValue, value, (value >> 3) & 1, (value >> 2) & 1))
        }

        // Track R#2 (display page) changes during gameplay
        if reg == 2 && value != oldValue {
            let oldPage = (oldValue >> 5) & 0x03
            let newPage = (value >> 5) & 0x03
            if oldPage != newPage {
                print(String(format: "[VDP] R#2 page change: %02X → %02X (displayPage %d → %d)", oldValue, value, oldPage, newPage))
            }
        }

        switch reg {
        case 14:
            // VRAM address high bits: enable V9938 128KB addressing
            r14ExplicitlySet = true
        case 15:
            // S#n select: no side effect other than storing
            break
        case 16:
            // Palette pointer: reset latch
            paletteLatchFirst = true
        case 17:
            // Indirect register pointer: no side effect
            break
        case 44:
            // Command data port (for HMMC/LMMC)
            commandEngine.writeData(value)
        case 46:
            // Command register: start command execution
            commandEngine.execute(value)
        default:
            break
        }
    }

    // MARK: - Data Port Write (0x98)
    func writeData(_ value: UInt8) {
        latchState = 0

        // If command engine is waiting for CPU data (HMMC/LMMC)
        if commandEngine.transferReady {
            commandEngine.writeData(value)
            return
        }

        let addr = fullAddress
        vram[addr] = value
        if addr < 0x08000 { directWriteCountPage0 += 1 }
        else if addr < 0x10000 { directWriteCountPage1 += 1 }
        incrementAddress()
    }

    // MARK: - Data Port Read (0x98)
    func readData() -> UInt8 {
        latchState = 0

        // If command engine has data for CPU (LMCM)
        if commandEngine.readReady {
            return commandEngine.readData()
        }

        let addr = fullAddress
        let result = readBuffer
        readBuffer = vram[addr]
        if addr < 0x08000 { directReadCountPage0 += 1 }
        else if addr < 0x10000 { directReadCountPage1 += 1 }
        incrementAddress()
        return result
    }

    private func incrementAddress() {
        addressLatch = (addressLatch + 1) & 0x3FFF
        // R#14 auto-increment on 16KB boundary wrap (V9938 128KB mode only).
        // MSX1 games never write R#14, so skip auto-increment to prevent
        // VRAM address corruption after 16KB sequential writes.
        if addressLatch == 0 && r14ExplicitlySet {
            regs[14] = (regs[14] + 1) & 0x07
        }
    }

    // MARK: - Status Register Read (0x99)
    func readStatus() -> UInt8 {
        latchState = 0
        let regNum = Int(regs[15] & 0x0F)

        if regNum == 0 {
            let s = statusRegs[0]
            statusRegs[0] &= ~0xA0  // Clear F (bit 7) + 5S collision (bit 5)
            irqPending = false
            return s
        } else if regNum == 1 {
            let s = statusRegs[1]
            statusRegs[1] &= ~0x01  // Clear FH (line interrupt)
            return s
        } else if regNum == 2 {
            // S#2: bit 7=TR, bit 6=VR, bit 5=HR, bit 4=BD, bit 0=CE
            var s2 = statusRegs[2]
            // VR: Vertical Retrace — set when current scanline >= active display lines
            if currentLine >= activeLines {
                s2 |= 0x40  // VR = 1 (in VBlank)
            } else {
                s2 &= ~0x40 // VR = 0 (active display)
            }
            // HR: Horizontal Retrace — approximate as toggling (not cycle-accurate)
            // Many games just need VR, but some check HR for VRAM access timing.
            // Set HR during the "retrace" portion of each scanline (~25% of the time).
            // We approximate using bit 1 of a simple counter.
            s2 &= ~0x20
            return s2
        } else if regNum < 10 {
            return statusRegs[regNum]
        }
        return 0xFF
    }

    // MARK: - Palette Port Write (0x9A)
    func writePalette(_ value: UInt8) {
        latchState = 0
        let entry = Int(regs[16] & 0x0F)

        if paletteLatchFirst {
            paletteLatchByte = value
            paletteLatchFirst = false
        } else {
            // Write both bytes to paletteRAM
            paletteRAM[entry * 2]     = paletteLatchByte  // 0RRR0BBB
            paletteRAM[entry * 2 + 1] = value             // 00000GGG

            // Convert to RGBA
            let r = Int((paletteLatchByte >> 4) & 0x07)
            let b = Int(paletteLatchByte & 0x07)
            let g = Int(value & 0x07)
            let r8 = UInt32(r * 255 / 7)
            let g8 = UInt32(g * 255 / 7)
            let b8 = UInt32(b * 255 / 7)
            palette[entry] = (r8 << 24) | (g8 << 16) | (b8 << 8) | 0xFF

            // Auto-increment palette pointer
            regs[16] = UInt8(((entry + 1) & 0x0F))
            paletteLatchFirst = true
        }
    }

    // MARK: - Indirect Register Port Write (0x9B)
    var debugIndirectCmdRegs = true  // One-shot: log first indirect write to R#32-R#46
    var indirectWriteCount = 0       // Total indirect register writes

    func writeIndirectRegister(_ value: UInt8) {
        latchState = 0
        let regPtr = Int(regs[17] & 0x3F)
        let autoInc = (regs[17] & 0x80) == 0
        indirectWriteCount += 1

        if debugIndirectCmdRegs && regPtr >= 32 && regPtr <= 46 {
            debugIndirectCmdRegs = false
            print(String(format: "[VDP] First indirect write to R#%d = 0x%02X (R17=0x%02X autoInc=%@)",
                regPtr, value, regs[17], autoInc ? "YES" : "NO"))
        }

        if regPtr < regs.count && regPtr != 17 {
            writeRegister(regPtr, value)
        }

        if autoInc {
            regs[17] = (regs[17] & 0x80) | UInt8(((regPtr + 1) & 0x3F))
        }
    }

    // MARK: - VRAM pixel access for command engine

    /// Read a pixel from VRAM at (x, y) in current bitmap mode
    func readPixel(x: Int, y: Int) -> UInt8 {
        switch screenMode {
        case .graphic4:
            let addr = y * 128 + x / 2
            let b = vram[addr & (VDP.vramSize - 1)]
            return (x & 1) == 0 ? (b >> 4) : (b & 0x0F)
        case .graphic5:
            let addr = y * 128 + x / 4
            let b = vram[addr & (VDP.vramSize - 1)]
            let shift = (3 - (x & 3)) * 2
            return (b >> shift) & 0x03
        case .graphic6:
            let addr = y * 256 + x / 2
            let b = vram[addr & (VDP.vramSize - 1)]
            return (x & 1) == 0 ? (b >> 4) : (b & 0x0F)
        case .graphic7:
            let addr = y * 256 + x
            return vram[addr & (VDP.vramSize - 1)]
        default:
            return 0
        }
    }

    /// Write a pixel to VRAM at (x, y) in current bitmap mode
    func writePixel(x: Int, y: Int, color: UInt8) {
        switch screenMode {
        case .graphic4:
            let addr = (y * 128 + x / 2) & (VDP.vramSize - 1)
            if (x & 1) == 0 {
                vram[addr] = (vram[addr] & 0x0F) | (color << 4)
            } else {
                vram[addr] = (vram[addr] & 0xF0) | (color & 0x0F)
            }
        case .graphic5:
            let addr = (y * 128 + x / 4) & (VDP.vramSize - 1)
            let shift = (3 - (x & 3)) * 2
            let mask = UInt8(0x03 << shift)
            vram[addr] = (vram[addr] & ~mask) | ((color & 0x03) << shift)
        case .graphic6:
            let addr = (y * 256 + x / 2) & (VDP.vramSize - 1)
            if (x & 1) == 0 {
                vram[addr] = (vram[addr] & 0x0F) | (color << 4)
            } else {
                vram[addr] = (vram[addr] & 0xF0) | (color & 0x0F)
            }
        case .graphic7:
            let addr = (y * 256 + x) & (VDP.vramSize - 1)
            vram[addr] = color
        default:
            break
        }
    }

    // MARK: - Frame rendering
    func renderFrame(into pixels: inout [UInt32]) {
        let totalPixels = VDP.screenWidth * VDP.screenHeight
        guard pixels.count == totalPixels else { return }
        let bg = palette[Int(bgColor)]

        if !screenEnabled {
            pixels = [UInt32](repeating: bg, count: totalPixels)
            return
        }

        let lines = activeLines

        switch screenMode {
        case .graphicsI:
            renderGraphicsI(into: &pixels, bg: bg, lines: lines)
        case .graphicsII, .graphic3:
            renderGraphicsII(into: &pixels, bg: bg, lines: lines)
        case .text:
            renderText(into: &pixels, bg: bg, lines: lines)
        case .multicolor:
            renderMulticolor(into: &pixels, bg: bg, lines: lines)
        case .graphic4:
            renderGraphic4(into: &pixels, bg: bg, lines: lines)
        case .graphic5:
            renderGraphic5(into: &pixels, bg: bg, lines: lines)
        case .graphic6:
            renderGraphic6(into: &pixels, bg: bg, lines: lines)
        case .graphic7:
            renderGraphic7(into: &pixels, bg: bg, lines: lines)
        }

        // Border fill for 192-line modes (lines 192-211)
        if lines < VDP.screenHeight {
            let borderStart = lines * VDP.screenWidth
            for i in borderStart..<totalPixels {
                pixels[i] = bg
            }
        }

        // Sprites (character modes only; bitmap modes also support sprites)
        switch screenMode {
        case .graphic5, .graphic6:
            break  // High-res modes have limited sprite support; skip for now
        default:
            renderSprites(into: &pixels, lines: lines)
        }
    }

    // MARK: - Graphics Mode I (SCREEN 1: 32x24 tiles)
    private func renderGraphicsI(into pixels: inout [UInt32], bg: UInt32, lines: Int) {
        let nameBase = nameTableBase
        let patBase = patternTableBase
        let colBase = colorTableBase
        let rows = lines / 8

        for row in 0..<rows {
            for col in 0..<32 {
                let nameIdx = nameBase + row * 32 + col
                let charCode = Int(vram[nameIdx & (VDP.vramSize - 1)])
                let colorEntry = vram[(colBase + (charCode >> 3)) & (VDP.vramSize - 1)]
                let fg = palette[Int(colorEntry >> 4)]
                let bg2 = colorEntry & 0xF == 0 ? bg : palette[Int(colorEntry & 0xF)]

                for line in 0..<8 {
                    let patByte = vram[(patBase + charCode * 8 + line) & (VDP.vramSize - 1)]
                    let pixRow = row * 8 + line
                    let pixColBase = col * 8
                    for bit in 0..<8 {
                        let on = (patByte >> (7 - bit)) & 1 != 0
                        pixels[pixRow * VDP.screenWidth + pixColBase + bit] = on ? fg : bg2
                    }
                }
            }
        }
    }

    // MARK: - Graphics Mode II (SCREEN 2 & 4: 32x24 bitmap)
    private func renderGraphicsII(into pixels: inout [UInt32], bg: UInt32, lines: Int) {
        let nameBase = nameTableBase
        let patBase = patternTableBase & 0x2000
        let colBase = colorTableBase & 0x2000
        let rows = lines / 8

        if debugRenderGFX2 {
            let firstChar = Int(vram[nameBase & (VDP.vramSize - 1)])
            if firstChar != 0 {
                debugRenderGFX2 = false
                let cc = firstChar
                let patAddr = (patBase + cc * 8) & (VDP.vramSize - 1)
                let colAddr = (colBase + cc * 8) & (VDP.vramSize - 1)
                let patStr = (0..<8).map { String(format: "%02X", vram[(patAddr + $0) & (VDP.vramSize - 1)]) }.joined(separator: " ")
                let colStr = (0..<8).map { String(format: "%02X", vram[(colAddr + $0) & (VDP.vramSize - 1)]) }.joined(separator: " ")
                print(String(format: "[GFX2] name[0,0]=0x%02X  patBase=%04X: %@  colBase=%04X: %@",
                    firstChar, patAddr, patStr, colAddr, colStr))
            }
        }

        for row in 0..<rows {
            let third = row / 8
            for col in 0..<32 {
                let nameIdx = nameBase + row * 32 + col
                let charCode = Int(vram[nameIdx & (VDP.vramSize - 1)]) + third * 256

                for line in 0..<8 {
                    let patByte = vram[(patBase + charCode * 8 + line) & (VDP.vramSize - 1)]
                    let colorEntry = vram[(colBase + charCode * 8 + line) & (VDP.vramSize - 1)]
                    let fg = palette[Int(colorEntry >> 4)]
                    let bg2 = colorEntry & 0xF == 0 ? bg : palette[Int(colorEntry & 0xF)]
                    let pixRow = row * 8 + line
                    let pixColBase = col * 8
                    for bit in 0..<8 {
                        let on = (patByte >> (7 - bit)) & 1 != 0
                        pixels[pixRow * VDP.screenWidth + pixColBase + bit] = on ? fg : bg2
                    }
                }
            }
        }

        if debugPixelCount {
            debugPixelCount = false
            let black: UInt32 = 0x000000FF
            let nonBlack = pixels.prefix(192 * VDP.screenWidth).filter { $0 != black }.count
            print(String(format: "[GFX2 render] nonBlack=%d/%d", nonBlack, 192 * VDP.screenWidth))
        }
    }

    // MARK: - Text Mode (SCREEN 0: 40x24)
    private func renderText(into pixels: inout [UInt32], bg: UInt32, lines: Int) {
        let nameBase = nameTableBase
        let patBase = patternTableBase
        let fgC = palette[Int(self.fgColor == 0 ? 15 : self.fgColor)]
        let bgC = palette[Int(self.bgColor == 0 ? 1 : self.bgColor)]
        let leftMargin = (256 - 240) / 2
        let rows = lines / 8

        // Fill background
        for i in 0..<(lines * VDP.screenWidth) { pixels[i] = bgC }

        for row in 0..<rows {
            for col in 0..<40 {
                let charCode = Int(vram[(nameBase + row * 40 + col) & (VDP.vramSize - 1)])
                for line in 0..<8 {
                    let patByte = vram[(patBase + charCode * 8 + line) & (VDP.vramSize - 1)]
                    let pixRow = row * 8 + line
                    for bit in 0..<6 {
                        let on = (patByte >> (7 - bit)) & 1 != 0
                        let x = leftMargin + col * 6 + bit
                        if x < VDP.screenWidth {
                            pixels[pixRow * VDP.screenWidth + x] = on ? fgC : bgC
                        }
                    }
                }
            }
        }
    }

    // MARK: - Multicolor Mode (SCREEN 3)
    private func renderMulticolor(into pixels: inout [UInt32], bg: UInt32, lines: Int) {
        let nameBase = nameTableBase
        let patBase = patternTableBase
        let rows = lines / 8

        for row in 0..<rows {
            for col in 0..<32 {
                let charCode = Int(vram[(nameBase + row * 32 + col) & (VDP.vramSize - 1)])
                let line = ((row & 3) * 2)
                let patByte0 = vram[(patBase + charCode * 8 + line) & (VDP.vramSize - 1)]
                let patByte1 = vram[(patBase + charCode * 8 + line + 1) & (VDP.vramSize - 1)]

                let tl = palette[Int(patByte0 >> 4)]
                let tr = palette[Int(patByte0 & 0xF)]
                let bl = palette[Int(patByte1 >> 4)]
                let br = palette[Int(patByte1 & 0xF)]

                for dy in 0..<8 {
                    let pixRow = row * 8 + dy
                    let pixColBase = col * 8
                    let isBottom = dy >= 4
                    for dx in 0..<8 {
                        let isRight = dx >= 4
                        let color: UInt32
                        if !isBottom && !isRight { color = tl }
                        else if !isBottom && isRight { color = tr }
                        else if isBottom && !isRight { color = bl }
                        else { color = br }
                        pixels[pixRow * VDP.screenWidth + pixColBase + dx] = color
                    }
                }
            }
        }
    }

    // MARK: - Graphic 4 (SCREEN 5: 256×212, 4bpp)
    private func renderGraphic4(into pixels: inout [UInt32], bg: UInt32, lines: Int) {
        // VRAM layout: Y * 128 + X/2, high nibble = even X, low nibble = odd X
        // Page offset from R#2 bits 6-5 (page 0-3)
        let page = (Int(regs[2]) >> 5) & 0x03
        let pageOffset = page * 0x08000

        if debugRenderGFX4 {
            debugRenderGFX4 = false
            let regStr = (0..<12).map { String(format: "R%d=%02X", $0, regs[$0]) }.joined(separator: " ")
            let r14Str = String(format: "R14=%02X", regs[14])
            print("[GFX4] SCREEN 5 render: \(regStr) \(r14Str) page=\(page) pageOff=\(String(format: "%05X", pageOffset)) lines=\(lines)")
            // VRAM first line (128 bytes at pageOffset)
            let line0 = (0..<32).map { String(format: "%02X", vram[(pageOffset + $0) & (VDP.vramSize - 1)]) }.joined(separator: " ")
            print("[GFX4] VRAM[\(String(format: "%05X", pageOffset))]: \(line0)")
            // VRAM line 100 (middle area)
            let mid = pageOffset + 100 * 128
            let lineMid = (0..<32).map { String(format: "%02X", vram[(mid + $0) & (VDP.vramSize - 1)]) }.joined(separator: " ")
            print("[GFX4] VRAM[\(String(format: "%05X", mid))]: \(lineMid)")
            // Count non-zero bytes in bitmap area
            var nonZero = 0
            for i in 0..<(lines * 128) {
                if vram[(pageOffset + i) & (VDP.vramSize - 1)] != 0 { nonZero += 1 }
            }
            print("[GFX4] nonZero bytes in bitmap: \(nonZero)/\(lines * 128)")
            // Palette
            let palStr = (0..<16).map { String(format: "%08X", palette[$0]) }.joined(separator: " ")
            print("[GFX4] palette: \(palStr)")
        }

        // R#23: vertical scroll offset (V9938 feature)
        // Display line `y` shows VRAM line `(y + R#23) % 256` from the current page
        let scrollOffset = Int(regs[23])

        for y in 0..<lines {
            let vramY = (y + scrollOffset) & 0xFF  // wrap within 256-line page
            let rowBase = pageOffset + vramY * 128
            let pixRow = y * VDP.screenWidth
            for xByte in 0..<128 {
                let b = vram[(rowBase + xByte) & (VDP.vramSize - 1)]
                let x = xByte * 2
                pixels[pixRow + x]     = palette[Int(b >> 4)]
                pixels[pixRow + x + 1] = palette[Int(b & 0x0F)]
            }
        }
    }

    // MARK: - Graphic 5 (SCREEN 6: 512×212, 2bpp → 256 wide display)
    private func renderGraphic5(into pixels: inout [UInt32], bg: UInt32, lines: Int) {
        let pageOffset = (Int(regs[2]) & 0x20) != 0 ? 0x08000 : 0x00000

        for y in 0..<lines {
            let rowBase = pageOffset + y * 128
            let pixRow = y * VDP.screenWidth
            // 512 pixels → 256 display: average or take every other pixel
            for xByte in 0..<128 {
                let b = vram[(rowBase + xByte) & (VDP.vramSize - 1)]
                // 4 pixels per byte (2bpp each): bits 7-6, 5-4, 3-2, 1-0
                // Map to 2 display pixels (simple: take pixel 0 and 2)
                let p0 = Int((b >> 6) & 0x03)
                let p2 = Int((b >> 2) & 0x03)
                let x = xByte * 2
                pixels[pixRow + x]     = palette[p0]
                pixels[pixRow + x + 1] = palette[p2]
            }
        }
    }

    // MARK: - Graphic 6 (SCREEN 7: 512×212, 4bpp → 256 wide display)
    private func renderGraphic6(into pixels: inout [UInt32], bg: UInt32, lines: Int) {
        let pageOffset = (Int(regs[2]) & 0x20) != 0 ? 0x10000 : 0x00000

        for y in 0..<lines {
            let rowBase = pageOffset + y * 256
            let pixRow = y * VDP.screenWidth
            // 512 pixels → 256 display: take every other pixel
            for xByte in 0..<256 {
                let b = vram[(rowBase + xByte) & (VDP.vramSize - 1)]
                // 2 pixels per byte: high nibble = even, low nibble = odd
                // Take first pixel of each byte for 256-wide display
                let x = xByte
                if x < VDP.screenWidth {
                    pixels[pixRow + x] = palette[Int(b >> 4)]
                }
            }
        }
    }

    // MARK: - Graphic 7 (SCREEN 8: 256×212, 8bpp direct color)
    private func renderGraphic7(into pixels: inout [UInt32], bg: UInt32, lines: Int) {
        let pageOffset = (Int(regs[2]) & 0x20) != 0 ? 0x10000 : 0x00000

        for y in 0..<lines {
            let rowBase = pageOffset + y * 256
            let pixRow = y * VDP.screenWidth
            for x in 0..<256 {
                let b = vram[(rowBase + x) & (VDP.vramSize - 1)]
                // SCREEN 8: direct color GGGRRRBB
                let g = Int((b >> 5) & 0x07)
                let r = Int((b >> 2) & 0x07)
                let bl = Int(b & 0x03)
                let r8 = UInt32(r * 255 / 7)
                let g8 = UInt32(g * 255 / 7)
                let b8 = UInt32(bl * 255 / 3)
                pixels[pixRow + x] = (r8 << 24) | (g8 << 16) | (b8 << 8) | 0xFF
            }
        }
    }

    // MARK: - Sprite rendering
    private func renderSprites(into pixels: inout [UInt32], lines: Int) {
        let attrBase = spriteAttrBase
        let patBase = spritePatBase
        let size = spriteSize
        let mag = spriteMag ? 2 : 1
        let actualSize = size * mag

        // Sprite Mode 2: V9938 ビットマップモードで有効
        // カラーテーブルは SAT の 512 バイト前に配置される
        let isSpriteMode2: Bool
        switch screenMode {
        case .graphic3, .graphic4, .graphic5, .graphic6, .graphic7:
            isSpriteMode2 = true
        default:
            isSpriteMode2 = false
        }
        let colorTableBase = isSpriteMode2 ? (attrBase &- 512) : 0

        // 212ライン時のターミネータ値
        let terminator: Int = (lines > 192) ? 0xD8 : 0xD0

        if debugSpriteSAT {
            debugSpriteSAT = false
            print(String(format: "[SAT] attrBase=%05X patBase=%05X size=%d mag=%d mode2=%d colorTbl=%05X",
                attrBase, patBase, size, mag, isSpriteMode2 ? 1 : 0, colorTableBase))
            for i in 0..<8 {
                let a = attrBase + i * 4
                let sy = Int(vram[a & (VDP.vramSize - 1)])
                if sy == terminator {
                    print(String(format: "[SAT] sprite %d: TERMINATOR (0x%02X)", i, terminator)); break
                }
                let sx = Int(vram[(a+1) & (VDP.vramSize - 1)])
                let sn = Int(vram[(a+2) & (VDP.vramSize - 1)])
                let sc = Int(vram[(a+3) & (VDP.vramSize - 1)])
                if isSpriteMode2 {
                    // Mode 2: カラーテーブルの先頭バイトも表示
                    let ct = colorTableBase + i * 16
                    let c0 = vram[ct & (VDP.vramSize - 1)]
                    print(String(format: "[SAT] sprite %d: y=%3d x=%3d name=%3d attr=%02X ct0=%02X",
                        i, sy, sx, sn, sc, c0))
                } else {
                    print(String(format: "[SAT] sprite %d: y=%3d x=%3d name=%3d color=%d",
                        i, sy, sx, sn, sc & 0x0F))
                }
            }
        }

        var collisionDetected = false
        var spritePixels = [Int: UInt32]()
        var touchedPixels = Set<Int>()

        for i in 0..<32 {
            let attrAddr = attrBase + i * 4
            let y = Int(vram[attrAddr & (VDP.vramSize - 1)])
            if y == terminator { break }
            let x = Int(vram[(attrAddr + 1) & (VDP.vramSize - 1)])
            let name = Int(vram[(attrAddr + 2) & (VDP.vramSize - 1)])
            let attr = vram[(attrAddr + 3) & (VDP.vramSize - 1)]

            // Mode 1: 色と EC はアトリビュートバイトから取得
            let mode1EarlyC = attr & 0x80 != 0
            let mode1Color = Int(attr & 0x0F)
            let actualY = (y + 1) & 0xFF

            for dy in 0..<actualSize {
                let pixY = actualY + dy
                if pixY >= lines { continue }

                let patY = dy / mag

                // Mode 2: ライン毎のカラーをスプライトカラーテーブルから取得
                let lineColor: Int
                let lineEC: Bool
                let lineCC: Bool  // Collision Cancel (Mode 2)

                if isSpriteMode2 {
                    let colorAddr = colorTableBase + i * 16 + patY
                    let colorByte = vram[colorAddr & (VDP.vramSize - 1)]
                    lineColor = Int(colorByte & 0x0F)
                    lineEC = colorByte & 0x80 != 0   // bit 7: Early Clock
                    lineCC = colorByte & 0x40 != 0   // bit 6: Collision Cancel
                } else {
                    lineColor = mode1Color
                    lineEC = mode1EarlyC
                    lineCC = false
                }

                let lineActualX = lineEC ? x - 32 : x

                for dx in 0..<actualSize {
                    let pixX = lineActualX + dx
                    if pixX < 0 || pixX >= VDP.screenWidth { continue }

                    let patX = dx / mag
                    let patIdx: Int
                    if size == 16 {
                        let qx = patX / 8; let qy = patY / 8
                        let patNum = (name & 0xFC) + qx * 2 + qy
                        patIdx = patBase + patNum * 8 + (patY & 7)
                    } else {
                        patIdx = patBase + name * 8 + patY
                    }
                    let patByte = vram[patIdx & (VDP.vramSize - 1)]
                    let bit = (patByte >> (7 - (patX & 7))) & 1

                    if bit != 0 {
                        let idx = pixY * VDP.screenWidth + pixX
                        if !lineCC {
                            if touchedPixels.contains(idx) {
                                collisionDetected = true
                            } else {
                                touchedPixels.insert(idx)
                            }
                        }
                        if lineColor != 0 && spritePixels[idx] == nil {
                            spritePixels[idx] = palette[lineColor]
                        }
                    }
                }
            }
        }

        for (idx, color) in spritePixels {
            pixels[idx] = color
        }

        spriteCollisionLatched = collisionDetected
        if collisionDetected { statusRegs[0] |= 0x20 }
    }

    // MARK: - VBlank
    func triggerVBlank() {
        statusRegs[0] |= 0x80  // S#0 F flag
        if irqEnabled {
            irqPending = true
        }
    }
}
