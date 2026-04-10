// Memory.swift - MSX Memory Management
// MSX uses a slot system: 4 pages x 16KB, each page can be mapped to a slot

import Foundation

final class MSXMemory {
    // MARK: - Memory
    static let totalRAM = 0x10000  // 64KB address space

    var ram = [UInt8](repeating: 0, count: 0x10000)

    // Slot contents (up to 4 slots x 64KB each)
    // slot 0: BIOS ROM
    // slot 1: cartridge (optional)
    // slot 2: cartridge (optional)
    // slot 3: RAM
    var slots = [[UInt8]?](repeating: nil, count: 4)

    // Page-to-slot mapping (4 pages of 16KB)
    // Controlled by I/O port 0xA8 (primary slot register)
    var pageSlot = [UInt8](repeating: 0, count: 4)  // slot # for each page

    // MSX keyboard matrix (9 rows x 8 columns)
    // Row 0-7: standard keys; Row 8: SPACE / cursor keys / edit keys
    // Row selected by PPI Port C (0xAA) bits 0-3, column data read from PPI Port B (0xA9)
    var keyMatrix = [UInt8](repeating: 0xFF, count: 9)  // 0xFF = no keys pressed

    // MARK: - Slot register (I/O port 0xA8)
    var primarySlotReg: UInt8 = 0x00 {
        didSet {
            pageSlot[0] = (primarySlotReg >> 0) & 0x03
            pageSlot[1] = (primarySlotReg >> 2) & 0x03
            pageSlot[2] = (primarySlotReg >> 4) & 0x03
            pageSlot[3] = (primarySlotReg >> 6) & 0x03
        }
    }

    // MARK: - Init
    init() {
        // Hardware reset default: all pages mapped to slot 0 (BIOS).
        // C-BIOS configures slot 3 (RAM) in page 3 during its init sequence.
        primarySlotReg = 0x00
    }

    // MARK: - Load ROM into slot
    func loadROM(_ data: [UInt8], slot: Int) {
        guard slot >= 0 && slot < 4 else { return }
        var slotData = [UInt8](repeating: 0xFF, count: 0x10000)
        let copyLen = min(data.count, 0x10000)
        slotData[0..<copyLen] = data[0..<copyLen]
        slots[slot] = slotData
    }

    // MARK: - MegaROM support
    /// Full ROM image for MegaROMs (> 64KB). nil = normal cartridge.
    var megaROMData: [UInt8]?
    /// MegaROM mapper type
    enum MegaROMMapper { case none, ascii8, ascii16, konami, konamiSCC }
    var megaROMMapper: MegaROMMapper = .none
    /// Bank registers for MegaROM (4 banks covering 0x4000-0xBFFF)
    var megaROMBanks: [Int] = [0, 1, 2, 3]  // default: banks 0-3
    /// Slot number that holds the MegaROM cartridge
    var megaROMSlot: Int = -1
    /// Debug: bank switch counter
    var bankSwitchCount = 0

    /// INIT entry-point address from the cartridge header (for diagnostics).
    var megaROMInitAddress: UInt16 = 0

    /// Clear MegaROM state (called when loading a non-MegaROM cartridge or resetting).
    func clearMegaROM() {
        megaROMData = nil
        megaROMMapper = .none
        megaROMBanks = [0, 1, 2, 3]
        megaROMSlot = -1
        bankSwitchCount = 0
        megaROMInitAddress = 0
    }

    // MARK: - Load cartridge
    func loadCartridge(_ data: [UInt8], slot: Int = 1) {
        guard slot >= 1 && slot < 3 else { return }
        print(String(format: "[Cart] loadCartridge: size=%d (0x%X) slot=%d header=%02X %02X",
                     data.count, data.count, slot,
                     data.count > 1 ? data[0] : 0, data.count > 1 ? data[1] : 0))
        // Always clear previous MegaROM state before loading new cartridge
        clearMegaROM()
        var cartData = [UInt8](repeating: 0xFF, count: 0x10000)

        if data.count > 0x10000 {
            // ── MegaROM: store full image, set up banking ──
            megaROMData = data
            megaROMSlot = slot
            megaROMMapper = detectMapper(data)
            megaROMBanks = [0, 1, 2, 3]  // default power-on banks

            // Store INIT address from cartridge header (for diagnostics).
            if data.count >= 4 && data[0] == 0x41 && data[1] == 0x42 {
                let initAddr = UInt16(data[2]) | (UInt16(data[3]) << 8)
                if initAddr >= 0x4000 && initAddr < 0xC000 {
                    megaROMInitAddress = initAddr
                }
            }

            // Fill initial slot view (first 32KB at 0x4000-0xBFFF)
            let bankSize = (megaROMMapper == .ascii16) ? 0x4000 : 0x2000
            rebuildMegaROMView(&cartData, bankSize: bankSize)
            print(String(format: "[Cart] MegaROM %dKB mapper=%@ slot=%d INIT=%04X",
                         data.count / 1024, "\(megaROMMapper)", slot, megaROMInitAddress))
        } else if data.count <= 0x8000 {
            // ≤ 32KB: load at 0x4000
            let offset = 0x4000
            let end = min(offset + data.count, 0x10000)
            cartData[offset..<end] = data[0..<(end-offset)]
        } else {
            // 32KB < size ≤ 64KB: load at 0x4000 (first 32KB) + 0x0000 region
            // The AB header is at data[0] which maps to MSX 0x4000.
            let firstPart = min(data.count, 0x8000)
            cartData[0x4000..<(0x4000 + firstPart)] = data[0..<firstPart]
            if data.count > 0x8000 {
                let remaining = data.count - 0x8000
                cartData[0..<remaining] = data[0x8000..<(0x8000+remaining)]
            }
        }
        slots[slot] = cartData
    }

    /// Detect MegaROM mapper type.
    /// 1) CRC32-based ROM database (reliable)
    /// 2) Heuristic fallback (LD (nn),A opcode scan)
    private func detectMapper(_ data: [UInt8]) -> MegaROMMapper {
        // ── Stage 1: ROM database lookup ──
        if let dbMapper = Self.lookupMapperDB(data) {
            print(String(format: "[Cart] Mapper DB hit: %@ (CRC32=%08X)",
                         "\(dbMapper)", Self.crc32(data)))
            return dbMapper
        }

        // ── Stage 2: Heuristic (fMSX-style LD (nn),A scan) ──
        // Scan for opcode 0x32 = LD (nnnn), A and classify target addresses.
        // Key principle: only count addresses UNIQUE to each mapper type.
        //   - 0x6000-0x7FFF is shared by ASCII8/ASCII16/Konami → count for ASCII8/16 only
        //   - 0x8000-0x9FFF, 0xA000-0xBFFF → Konami unique (bank 2-3)
        //   - 0x5000-0x57FF, 0x9000-0x97FF, 0xB000-0xB7FF → KonamiSCC unique
        //   - 0x4000-0x5FFF → Konami (bank 0 region, rarely used)
        // Scanning the FULL ROM improves accuracy over first-64KB-only.
        var ascii8 = 0, ascii16 = 0, konami = 0, konamiSCC = 0
        let limit = data.count
        for i in 0..<(limit - 2) {
            if data[i] == 0x32 {
                let addr = Int(data[i+1]) | (Int(data[i+2]) << 8)
                switch addr {
                case 0x4000...0x4FFF: konami += 1                   // Konami bank 0
                case 0x5000...0x57FF: konamiSCC += 1                // SCC bank 0
                case 0x6000...0x67FF: ascii8 += 1; ascii16 += 1     // ASCII8 b0 / ASCII16 b0
                case 0x6800...0x6FFF: ascii8 += 1                   // ASCII8 bank 1
                case 0x7000...0x77FF: ascii8 += 1; ascii16 += 1; konamiSCC += 1 // ASCII8 b2 / ASCII16 b1 / SCC b1
                case 0x7800...0x7FFF: ascii8 += 1                   // ASCII8 bank 3
                case 0x8000...0x8FFF: konami += 1                   // Konami bank 2
                case 0x9000...0x97FF: konami += 1; konamiSCC += 1   // Konami b2 / SCC b2
                case 0x9800...0x9FFF: konami += 1                   // Konami bank 2
                case 0xA000...0xAFFF: konami += 1                   // Konami bank 3
                case 0xB000...0xB7FF: konami += 1; konamiSCC += 1   // Konami b3 / SCC b3
                case 0xB800...0xBFFF: konami += 1                   // Konami bank 3
                default: break
                }
            }
        }
        // Resolve: highest score wins. On tie, prefer ASCII8 (most common).
        // max(by: <) returns the FIRST max element, so place ascii8 LAST to
        // lose ties. Instead we use <= so the LAST element replaces on tie.
        let scores = [
            (MegaROMMapper.konamiSCC, konamiSCC),
            (.konami, konami),
            (.ascii16, ascii16),
            (.ascii8, ascii8),              // last → wins ties with <=
        ]
        let best = scores.max(by: { $0.1 <= $1.1 })!   // <= makes last-wins-ties
        let result = best.1 > 0 ? best.0 : .ascii8
        print(String(format: "[Cart] Mapper heuristic: ASCII8=%d ASCII16=%d Konami=%d KonamiSCC=%d → %@",
                     ascii8, ascii16, konami, konamiSCC, "\(result)"))
        return result
    }

    // MARK: - ROM database (CRC32 → mapper)
    // Pure heuristic detection is unreliable: random data in ROMs produces
    // false-positive opcode patterns.  A CRC32 database gives correct results
    // for known games.  The heuristic is kept as a fallback for unknown ROMs.

    /// CRC32 → mapper lookup table for known MegaROM cartridges.
    /// Sources: openMSX softwaredb, blueMSX, MSX.org.
    private static let mapperDB: [UInt32: MegaROMMapper] = [
        // ── Konami (without SCC) ──
        // NOTE: Metal Gear (J) CRC32=0x60E0FA79 uses ASCII8-style bank switch
        // addresses (LD (68FFh),A / LD (70FFh),A / LD (78FFh),A) instead of
        // standard Konami addresses (6000h/8000h/A000h). Classified as ASCII8.
        0x840CF905: .konami,  // Metal Gear (EN translated)
        0xB8E2D4AF: .konami,  // Knightmare (Konami)
        0x4EF14CD2: .konami,  // Knightmare (alt)
        0xC06E0EC2: .konami,  // King's Valley 2 (J)
        0x5FCFFA1E: .konami,  // Maze of Galious (J)
        0xEBD437A5: .konami,  // Maze of Galious (EN)
        0x40CE0100: .konami,  // Parodius (J)
        0x7C684B04: .konami,  // Penguin Adventure (J)
        0x4CDE891C: .konami,  // Nemesis 2 (J)
        0xF2EA7E00: .konami,  // Q-Bert
        0x3757C222: .konami,  // Contra (J) / Gryzor
        0xDE180F6F: .konami,  // Yie Ar Kung-Fu 2

        // ── KonamiSCC ──
        0x0AE5CCA1: .konamiSCC, // Nemesis 3 (J)
        0xCDB89C2A: .konamiSCC, // Salamander (J)
        0x6B4B044A: .konamiSCC, // Metal Gear 2: Solid Snake (J)
        0x45B1B3A6: .konamiSCC, // Snatcher (J)
        0xBD8D6CF0: .konamiSCC, // Space Manbow (J)
        0xE316C585: .konamiSCC, // Gradius 2 (J)
        0xB64B3724: .konamiSCC, // King's Valley 2 SCC
        0x3B4F9F4E: .konamiSCC, // SD Snatcher (J)
        0x5BFE7F41: .konamiSCC, // F1 Spirit (J)
        0x0C8B4318: .konamiSCC, // Parodius SCC

        // ── ASCII8 ──
        0x60E0FA79: .ascii8,  // Metal Gear (J) — uses 68FF/70FF/78FF bank regs
        0x8076FEC6: .ascii8,  // Dragon Quest 2 (J)
        0x3E21E9B3: .ascii8,  // Dragon Quest 2 (J, alt)
        0x4F618C85: .ascii8,  // Ys (J)
        0xD7E67702: .ascii8,  // Ys II (J)
        0xB5C9B3BC: .ascii8,  // Ys III (J)
        0x7C539B3B: .ascii8,  // Final Fantasy (J)
        0x5B1084E0: .ascii8,  // Dragon Slayer IV (J)
        0x37B1E108: .ascii8,  // Hydlide 3 (J)
        0x85B06612: .ascii8,  // Xak (J)
        0xEC544C45: .ascii8,  // Andorogynus (J)
        0xA1B592B0: .ascii8,  // R-Type (J)
        0xBFBBB6A0: .ascii8,  // Zanac-EX (J)
        0x0D0AADDE: .ascii8,  // Valis (J)
        0xD6F26E0D: .ascii8,  // Dragon Quest (J) / Dragon Warrior
        0x3706CDAB: .ascii8,  // Xanadu (J)

        // ── ASCII16 ──
        0xC2B2B4D2: .ascii16, // Treasure of Usas (J)
        0x5D5C4C04: .ascii16, // Romancia (J)
        0xCAC76788: .ascii16, // Gallforce (J)
        0x8C0CF5C4: .ascii16, // Super Laydock (J)
    ]

    /// Look up mapper type from ROM database using CRC32.
    private static func lookupMapperDB(_ data: [UInt8]) -> MegaROMMapper? {
        let crc = crc32(data)
        return mapperDB[crc]
    }

    /// Compute CRC32 of a byte array.
    private static func crc32(_ data: [UInt8]) -> UInt32 {
        // Standard CRC32 (ISO 3309 / ITU-T V.42)
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (crc & 1 != 0 ? 0xEDB88320 : 0)
            }
        }
        return crc ^ 0xFFFFFFFF
    }

    /// Rebuild the 64KB slot view from MegaROM banks.
    private func rebuildMegaROMView(_ cartData: inout [UInt8], bankSize: Int) {
        guard let rom = megaROMData else { return }
        // Page 1 (0x4000-0x7FFF): banks 0-1 (ASCII8) or bank 0 (ASCII16)
        // Page 2 (0x8000-0xBFFF): banks 2-3 (ASCII8) or bank 1 (ASCII16)
        if bankSize == 0x2000 {
            // ASCII8 / Konami: 4 × 8KB banks
            for i in 0..<4 {
                let srcOff = megaROMBanks[i] * bankSize
                let dstOff = 0x4000 + i * bankSize
                let srcEnd = min(srcOff + bankSize, rom.count)
                if srcOff < rom.count {
                    let len = srcEnd - srcOff
                    cartData[dstOff..<(dstOff+len)] = rom[srcOff..<srcEnd]
                }
            }
        } else {
            // ASCII16: 2 × 16KB banks
            for i in 0..<2 {
                let srcOff = megaROMBanks[i] * bankSize
                let dstOff = 0x4000 + i * bankSize
                let srcEnd = min(srcOff + bankSize, rom.count)
                if srcOff < rom.count {
                    let len = srcEnd - srcOff
                    cartData[dstOff..<(dstOff+len)] = rom[srcOff..<srcEnd]
                }
            }
        }
    }

    // MARK: - Memory Read
    func read(_ addr: UInt16) -> UInt8 {
        let page = Int(addr >> 14)
        let slot = Int(pageSlot[page])

        // MegaROM dynamic bank read (0x4000-0xBFFF)
        if slot == megaROMSlot && megaROMData != nil && addr >= 0x4000 && addr < 0xC000 {
            return readMegaROM(addr)
        }

        if let slotData = slots[slot] {
            return slotData[Int(addr)]
        }

        // Slot 3 = RAM
        if slot == 3 {
            return ram[Int(addr)]
        }

        return 0xFF
    }

    /// Read a byte from MegaROM with dynamic bank mapping.
    private func readMegaROM(_ addr: UInt16) -> UInt8 {
        guard let rom = megaROMData else { return 0xFF }
        let a = Int(addr)

        switch megaROMMapper {
        case .ascii8, .konami, .konamiSCC:
            // 4 × 8KB banks: 0x4000-0x5FFF, 0x6000-0x7FFF, 0x8000-0x9FFF, 0xA000-0xBFFF
            let bankIndex = (a - 0x4000) / 0x2000          // 0-3
            let offsetInBank = (a - 0x4000) % 0x2000
            // Wrap bank value by ROM size (real hardware mirrors ROM address lines)
            let maxBanks = max(1, rom.count / 0x2000)
            let romOffset = (megaROMBanks[bankIndex] % maxBanks) * 0x2000 + offsetInBank
            return rom[romOffset]

        case .ascii16:
            // 2 × 16KB banks: 0x4000-0x7FFF, 0x8000-0xBFFF
            let bankIndex = (a - 0x4000) / 0x4000          // 0-1
            let offsetInBank = (a - 0x4000) % 0x4000
            let maxBanks = max(1, rom.count / 0x4000)
            let romOffset = (megaROMBanks[bankIndex] % maxBanks) * 0x4000 + offsetInBank
            return rom[romOffset]

        case .none:
            return 0xFF
        }
    }

    // MARK: - Memory Write
    func write(_ addr: UInt16, _ value: UInt8, pc: UInt16 = 0) {
        // MegaROM bank switching: intercept writes to mapper register addresses.
        // On real hardware the MegaROM chip only sees bus writes when its slot
        // is selected for the page being written to.
        //
        // PC-based filtering: Block bank switches from BIOS code (PC < 0x4000).
        // C-BIOS's slot scan routine at ~0x0D43 writes test values to
        // 0x6000-0xBFFF to detect RAM/ROM, which corrupts MegaROM bank
        // registers.  Game code (PC 0x4000-0xBFFF) and RAM trampolines
        // (PC 0xC000-0xFFFF, used by ASCII mappers for self-switching)
        // are allowed through.
        if megaROMData != nil && addr >= 0x4000 && addr < 0xC000 {
            let page = Int(addr >> 14)
            if Int(pageSlot[page]) == megaROMSlot && pc >= 0x4000 {
                writeMegaROMRegister(addr, value, pc: pc)
            }
        }

        // On MSX1 hardware, the RAM chip is always present on the write bus
        // regardless of slot selection. Slot mapping only affects reads.
        // This allows C-BIOS to use the stack (page 3) before configuring
        // port 0xA8 to officially map RAM to page 3.
        ram[Int(addr)] = value
    }

    /// Handle MegaROM mapper register writes and update bank selection.
    private func writeMegaROMRegister(_ addr: UInt16, _ value: UInt8, pc: UInt16 = 0) {
        let a = Int(addr)
        let bank = Int(value)
        let oldBanks = megaROMBanks

        switch megaROMMapper {
        case .ascii8:
            // 4 × 8KB bank registers
            switch a {
            case 0x6000...0x67FF: megaROMBanks[0] = bank
            case 0x6800...0x6FFF: megaROMBanks[1] = bank
            case 0x7000...0x77FF: megaROMBanks[2] = bank
            case 0x7800...0x7FFF: megaROMBanks[3] = bank
            default: break
            }

        case .ascii16:
            // 2 × 16KB bank registers
            switch a {
            case 0x6000...0x6FFF: megaROMBanks[0] = bank
            case 0x7000...0x7FFF: megaROMBanks[1] = bank
            default: break
            }

        case .konami:
            // Konami (without SCC): bank 0 at 0x4000-0x5FFF is fixed
            switch a {
            case 0x6000...0x7FFF: megaROMBanks[1] = bank
            case 0x8000...0x9FFF: megaROMBanks[2] = bank
            case 0xA000...0xBFFF: megaROMBanks[3] = bank
            default: break
            }

        case .konamiSCC:
            switch a {
            case 0x5000...0x57FF: megaROMBanks[0] = bank
            case 0x7000...0x77FF: megaROMBanks[1] = bank
            case 0x9000...0x97FF: megaROMBanks[2] = bank
            case 0xB000...0xB7FF: megaROMBanks[3] = bank
            default: break
            }

        case .none:
            break
        }

        // Log bank switches
        if megaROMBanks != oldBanks {
            bankSwitchCount += 1
            if bankSwitchCount <= 50 {
                print(String(format: "[BANK #%d] addr=%04X val=%d banks=[%d,%d,%d,%d] slot=%02X PC=%04X",
                             bankSwitchCount, a, bank,
                             megaROMBanks[0], megaROMBanks[1], megaROMBanks[2], megaROMBanks[3],
                             primarySlotReg, pc))
            }
        }
    }
}
