// VDPCommands.swift - V9938 VDP Command Engine
// Handles HMMC, HMMM, HMMV, LMMC, LMCM, LMMM, LMMV, LINE, PSET, SRCH, POINT, YMMM

import Foundation

final class VDPCommandEngine {
    unowned let vdp: VDP

    // Command state
    var transferReady = false   // CPU→VRAM transfer pending (HMMC/LMMC)
    var readReady = false       // VRAM→CPU read pending (LMCM)
    var commandRunning = false

    // Current command parameters (from R#32-R#45)
    private var SX = 0, SY = 0
    private var DX = 0, DY = 0
    private var NX = 0, NY = 0
    private var CLR: UInt8 = 0
    private var ARG: UInt8 = 0

    // Transfer state for byte-by-byte commands
    private var transferDX = 0, transferDY = 0
    private var transferNX = 0, transferNY = 0
    private var transferCount = 0
    private var cmdByte: UInt8 = 0  // Full R#46 value for logical operation reference
    private var readByte: UInt8 = 0 // Data byte for LMCM

    init(vdp: VDP) {
        self.vdp = vdp
    }

    func reset() {
        transferReady = false
        readReady = false
        commandRunning = false
        SX = 0; SY = 0; DX = 0; DY = 0; NX = 0; NY = 0
        CLR = 0; ARG = 0
        transferDX = 0; transferDY = 0; transferNX = 0; transferNY = 0
        transferCount = 0; cmdByte = 0; readByte = 0
        updateStatus()
    }

    // MARK: - Read command parameters from VDP registers
    private func loadParams() {
        let r = vdp.regs
        SX = Int(r[32]) | (Int(r[33] & 0x01) << 8)
        SY = Int(r[34]) | (Int(r[35] & 0x03) << 8)
        DX = Int(r[36]) | (Int(r[37] & 0x01) << 8)
        DY = Int(r[38]) | (Int(r[39] & 0x03) << 8)
        NX = Int(r[40]) | (Int(r[41] & 0x01) << 8)
        NY = Int(r[42]) | (Int(r[43] & 0x03) << 8)
        CLR = r[44]
        ARG = r[45]
    }

    private var DIX: Int { (ARG & 0x04) != 0 ? -1 : 1 }  // X direction
    private var DIY: Int { (ARG & 0x08) != 0 ? -1 : 1 }  // Y direction

    // MARK: - Update status register S#2
    private func updateStatus() {
        if commandRunning || transferReady || readReady {
            vdp.statusRegs[2] |= 0x01   // CE (command executing)
        } else {
            vdp.statusRegs[2] &= ~0x01  // clear CE
        }
        if transferReady {
            vdp.statusRegs[2] |= 0x80   // TR (transfer ready)
        } else {
            vdp.statusRegs[2] &= ~0x80
        }
    }

    // MARK: - Execute command (called when R#46 is written)
    func execute(_ cmdReg: UInt8) {
        cmdByte = cmdReg
        let cmd = (cmdReg >> 4) & 0x0F

        // Stop any running command first
        transferReady = false
        readReady = false
        commandRunning = false

        loadParams()

        // NX=0/NY=0 → max: V9938 仕様では矩形コマンドのみ NX=0 を最大値として扱う。
        // LINE コマンドでは NX=描画ドット数, NY=誤差項なので 0 はそのまま 0。
        // POINT/PSET/SRCH も NX/NY をループカウントに使わないため変換不要。
        let needClampNXNY: Bool
        switch cmd {
        case 0x8, 0x9, 0xA, 0xB, 0xC, 0xD, 0xE, 0xF:
            // 矩形系コマンド: LMMV, LMMM, LMCM, LMMC, HMMV, HMMM, YMMM, HMMC
            needClampNXNY = true
        default:
            needClampNXNY = false
        }
        if needClampNXNY {
            if NX == 0 { NX = maxNX }
            if NY == 0 { NY = 1024 }
        }

        switch cmd {
        case 0x0: // STOP
            break
        case 0x4: // POINT
            execPoint()
        case 0x5: // PSET
            execPset()
        case 0x6: // SRCH
            execSrch()
        case 0x7: // LINE
            execLine()
        case 0x8: // LMMV (logical fill)
            execLMMV()
        case 0x9: // LMMM (logical copy VRAM→VRAM)
            execLMMM()
        case 0xA: // LMCM (logical copy VRAM→CPU)
            startLMCM()
        case 0xB: // LMMC (logical copy CPU→VRAM)
            startLMMC()
        case 0xC: // HMMV (high-speed fill)
            execHMMV()
        case 0xD: // HMMM (high-speed copy VRAM→VRAM)
            execHMMM()
        case 0xE: // YMMM (Y-only move)
            execYMMM()
        case 0xF: // HMMC (high-speed CPU→VRAM)
            startHMMC()
        default:
            break
        }

        updateStatus()
    }

    /// Max NX depends on screen mode
    private var maxNX: Int {
        switch vdp.screenMode {
        case .graphic4: return 256
        case .graphic5: return 512
        case .graphic6: return 512
        case .graphic7: return 256
        default: return 256
        }
    }

    // MARK: - Logical operation
    private func applyLogic(src: UInt8, dst: UInt8) -> UInt8 {
        let op = cmdByte & 0x0F
        let tFlag = (op & 0x08) != 0
        let logOp = op & 0x07

        // Transparency: if T flag set and src color == 0, don't modify dst
        if tFlag && src == 0 { return dst }

        switch logOp {
        case 0: return src              // IMP
        case 1: return src & dst        // AND
        case 2: return src | dst        // OR
        case 3: return src ^ dst        // XOR
        case 4: return ~src             // NOT
        default: return src
        }
    }

    // MARK: - HMMV: High-speed fill rectangle (byte-aligned)
    private func execHMMV() {
        let bpr = vdp.bytesPerPixelRow
        let ppb = vdp.pixelsPerByte
        let dix = DIX
        let diy = DIY
        var dy = DY

        for _ in 0..<NY {
            var dx = DX
            let byteCount = NX / ppb
            for _ in 0..<max(1, byteCount) {
                let wrappedDX = dx & (maxNX - 1)
                let wrappedDY = dy & 0x3FF
                let addr = (wrappedDY * bpr + wrappedDX / ppb) & (VDP.vramSize - 1)
                vdp.vram[addr] = CLR
                dx += dix * ppb
            }
            dy += diy
        }
    }

    // MARK: - HMMM: High-speed copy VRAM→VRAM (byte-aligned)
    private func execHMMM() {
        let bpr = vdp.bytesPerPixelRow
        let ppb = vdp.pixelsPerByte
        let dix = DIX
        let diy = DIY
        var sy = SY, dy = DY

        for _ in 0..<NY {
            var sx = SX, dx = DX
            let byteCount = NX / ppb
            for _ in 0..<max(1, byteCount) {
                let wrappedSX = sx & (maxNX - 1)
                let wrappedSY = sy & 0x3FF
                let wrappedDX = dx & (maxNX - 1)
                let wrappedDY = dy & 0x3FF
                let srcAddr = (wrappedSY * bpr + wrappedSX / ppb) & (VDP.vramSize - 1)
                let dstAddr = (wrappedDY * bpr + wrappedDX / ppb) & (VDP.vramSize - 1)
                vdp.vram[dstAddr] = vdp.vram[srcAddr]
                sx += dix * ppb
                dx += dix * ppb
            }
            sy += diy
            dy += diy
        }
    }

    // MARK: - YMMM: High-speed Y-only move
    private func execYMMM() {
        let bpr = vdp.bytesPerPixelRow
        let diy = DIY
        var sy = SY, dy = DY

        for _ in 0..<NY {
            let wrappedSY = sy & 0x3FF
            let wrappedDY = dy & 0x3FF
            let srcBase = (wrappedSY * bpr) & (VDP.vramSize - 1)
            let dstBase = (wrappedDY * bpr) & (VDP.vramSize - 1)
            // Copy entire row from DX position to end
            let startByte = DX / vdp.pixelsPerByte
            for b in startByte..<bpr {
                vdp.vram[(dstBase + b) & (VDP.vramSize - 1)] = vdp.vram[(srcBase + b) & (VDP.vramSize - 1)]
            }
            sy += diy
            dy += diy
        }
    }

    // MARK: - HMMC: High-speed CPU→VRAM transfer (byte-aligned)
    private func startHMMC() {
        transferDX = DX
        transferDY = DY
        transferNX = 0
        transferNY = 0
        transferReady = true
        commandRunning = true
        // First byte comes from R#44
        writeTransferByteHMMC(CLR)
    }

    // MARK: - LMMV: Logical fill rectangle (pixel-level)
    private func execLMMV() {
        let dix = DIX
        let diy = DIY
        var dy = DY

        for _ in 0..<NY {
            var dx = DX
            for _ in 0..<NX {
                let dst = vdp.readPixel(x: dx & (maxNX - 1), y: dy & 0x3FF)
                let result = applyLogic(src: CLR, dst: dst)
                vdp.writePixel(x: dx & (maxNX - 1), y: dy & 0x3FF, color: result)
                dx += dix
            }
            dy += diy
        }
    }

    // MARK: - LMMM: Logical copy VRAM→VRAM (pixel-level)
    private func execLMMM() {
        let dix = DIX
        let diy = DIY
        var sy = SY, dy = DY

        for _ in 0..<NY {
            var sx = SX, dx = DX
            for _ in 0..<NX {
                let src = vdp.readPixel(x: sx & (maxNX - 1), y: sy & 0x3FF)
                let dst = vdp.readPixel(x: dx & (maxNX - 1), y: dy & 0x3FF)
                let result = applyLogic(src: src, dst: dst)
                vdp.writePixel(x: dx & (maxNX - 1), y: dy & 0x3FF, color: result)
                sx += dix
                dx += dix
            }
            sy += diy
            dy += diy
        }
    }

    // MARK: - LMMC: Logical CPU→VRAM transfer (pixel-level)
    private func startLMMC() {
        transferDX = DX
        transferDY = DY
        transferNX = 0
        transferNY = 0
        transferReady = true
        commandRunning = true
        // First byte from R#44
        writeTransferByteLMMC(CLR)
    }

    // MARK: - LMCM: Logical VRAM→CPU read (pixel-level)
    private func startLMCM() {
        transferDX = SX
        transferDY = SY
        transferNX = 0
        transferNY = 0
        readReady = true
        commandRunning = true
        prepareNextReadByte()
    }

    // MARK: - LINE: Draw line (Bresenham)
    private func execLine() {
        guard NX > 0 else { return }  // NX=0 → no dots to draw

        let dix = DIX
        let diy = DIY
        let maj = (ARG & 0x01) != 0  // MAJ: 1=Y is major axis, 0=X is major axis

        let longSide = NX   // "number of dots" along major axis
        let shortSide = NY  // "number of dots" along minor axis (used as error term init)
        var dx = DX, dy = DY
        var err = 0

        for _ in 0..<longSide {
            let dst = vdp.readPixel(x: dx & (maxNX - 1), y: dy & 0x3FF)
            let result = applyLogic(src: CLR, dst: dst)
            vdp.writePixel(x: dx & (maxNX - 1), y: dy & 0x3FF, color: result)

            // Major axis step
            if maj {
                dy += diy
            } else {
                dx += dix
            }

            // Error accumulation for minor axis
            err += shortSide
            if err >= longSide {
                err -= longSide
                if maj {
                    dx += dix
                } else {
                    dy += diy
                }
            }
        }
    }

    // MARK: - PSET: Set single pixel
    private func execPset() {
        let dst = vdp.readPixel(x: DX & (maxNX - 1), y: DY & 0x3FF)
        let result = applyLogic(src: CLR, dst: dst)
        vdp.writePixel(x: DX & (maxNX - 1), y: DY & 0x3FF, color: result)
    }

    // MARK: - POINT: Read single pixel
    private func execPoint() {
        let color = vdp.readPixel(x: SX & (maxNX - 1), y: SY & 0x3FF)
        vdp.statusRegs[7] = color
    }

    // MARK: - SRCH: Search for color
    private func execSrch() {
        let dix = DIX
        let eq = (ARG & 0x02) != 0  // EQ: 1=search for equal, 0=search for not-equal
        var x = SX

        for _ in 0..<maxNX {
            let pix = vdp.readPixel(x: x & (maxNX - 1), y: SY & 0x3FF)
            let found = eq ? (pix == CLR) : (pix != CLR)
            if found {
                // Set border detect flag and X coordinate in S#8-S#9
                vdp.statusRegs[2] |= 0x10  // BD (border detect)
                vdp.statusRegs[8] = UInt8(x & 0xFF)
                vdp.statusRegs[9] = UInt8((x >> 8) & 0x01)
                return
            }
            x += dix
            if x < 0 || x >= maxNX { break }
        }
        // Not found
        vdp.statusRegs[2] &= ~0x10
    }

    // MARK: - CPU transfer: write data byte (port 0x98 or R#44)
    func writeData(_ value: UInt8) {
        guard commandRunning else { return }

        let cmd = (cmdByte >> 4) & 0x0F
        switch cmd {
        case 0xF: writeTransferByteHMMC(value)
        case 0xB: writeTransferByteLMMC(value)
        default: break
        }
    }

    // MARK: - CPU transfer: read data byte (port 0x98 for LMCM)
    func readData() -> UInt8 {
        guard readReady else { return 0xFF }
        let result = readByte
        prepareNextReadByte()
        return result
    }

    // MARK: - HMMC byte write
    private func writeTransferByteHMMC(_ value: UInt8) {
        let bpr = vdp.bytesPerPixelRow
        let ppb = vdp.pixelsPerByte
        let dix = DIX

        let wrappedDX = transferDX & (maxNX - 1)
        let wrappedDY = transferDY & 0x3FF
        let addr = (wrappedDY * bpr + wrappedDX / ppb) & (VDP.vramSize - 1)
        vdp.vram[addr] = value

        transferDX += dix * ppb
        transferNX += ppb

        if transferNX >= NX {
            transferNX = 0
            transferDX = DX
            transferDY += DIY
            transferNY += 1
            if transferNY >= NY {
                finishCommand()
                return
            }
        }
        transferReady = true
        updateStatus()
    }

    // MARK: - LMMC byte write (pixel-level with logic)
    private func writeTransferByteLMMC(_ value: UInt8) {
        let ppb = vdp.pixelsPerByte
        let dix = DIX

        // Write pixels from the byte
        for p in 0..<ppb {
            let color: UInt8
            switch ppb {
            case 2:
                color = (p == 0) ? (value >> 4) : (value & 0x0F)
            case 4:
                color = (value >> ((3 - p) * 2)) & 0x03
            default:
                color = value
            }

            let x = transferDX & (maxNX - 1)
            let y = transferDY & 0x3FF
            let dst = vdp.readPixel(x: x, y: y)
            let result = applyLogic(src: color, dst: dst)
            vdp.writePixel(x: x, y: y, color: result)

            transferDX += dix
            transferNX += 1

            if transferNX >= NX {
                transferNX = 0
                transferDX = DX
                transferDY += DIY
                transferNY += 1
                if transferNY >= NY {
                    finishCommand()
                    return
                }
            }
        }

        transferReady = true
        updateStatus()
    }

    // MARK: - LMCM next byte read
    private func prepareNextReadByte() {
        let ppb = vdp.pixelsPerByte
        let dix = DIX
        var byte: UInt8 = 0

        for p in 0..<ppb {
            let x = transferDX & (maxNX - 1)
            let y = transferDY & 0x3FF
            let color = vdp.readPixel(x: x, y: y)

            switch ppb {
            case 2:
                if p == 0 { byte |= (color << 4) } else { byte |= (color & 0x0F) }
            case 4:
                byte |= (color & 0x03) << ((3 - p) * 2)
            default:
                byte = color
            }

            transferDX += dix
            transferNX += 1

            if transferNX >= NX {
                transferNX = 0
                transferDX = SX
                transferDY += DIY
                transferNY += 1
                if transferNY >= NY {
                    readByte = byte
                    finishCommand()
                    return
                }
            }
        }

        readByte = byte
        readReady = true
        updateStatus()
    }

    private func finishCommand() {
        transferReady = false
        readReady = false
        commandRunning = false
        updateStatus()
    }
}
