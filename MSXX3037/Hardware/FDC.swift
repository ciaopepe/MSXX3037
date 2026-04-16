// FDC.swift - MSX Floppy Disk Controller (BIOS-level emulation)
// Manages disk image data and provides sector-level read/write operations.
// Instead of emulating WD2793 hardware, disk I/O is handled by PC hooks
// in MSXMachine that intercept Disk BIOS entry points.

import Foundation

final class FDC {
    // MARK: - Constants
    static let sectorSize = 512
    static let sectorsPerTrack = 9
    static let tracksPerSide = 80
    static let sides = 2
    /// Standard 720KB disk: 80 tracks × 2 sides × 9 sectors × 512 bytes
    static let diskSize720K = sectorSize * sectorsPerTrack * tracksPerSide * sides  // 737,280
    /// Single-sided 360KB disk
    static let diskSize360K = sectorSize * sectorsPerTrack * tracksPerSide * 1      // 368,640

    // MARK: - Disk State
    var diskImage: [UInt8]?
    var diskInserted: Bool { diskImage != nil }
    var diskChanged = false
    var motorOn = false

    // MARK: - Load / Eject

    /// Load a raw disk image (.dsk). Returns true on success.
    @discardableResult
    func loadDisk(_ data: [UInt8]) -> Bool {
        // Accept standard 720KB and single-sided 360KB formats,
        // and also smaller/non-standard sizes (some games use truncated images)
        guard data.count > 0 && data.count <= FDC.diskSize720K else {
            print("[FDC] Invalid disk image size: \(data.count)")
            return false
        }
        // Pad to 720KB if smaller (simplifies sector access bounds checking)
        if data.count < FDC.diskSize720K {
            var padded = data
            padded.append(contentsOf: [UInt8](repeating: 0xE5, count: FDC.diskSize720K - data.count))
            diskImage = padded
        } else {
            diskImage = data
        }
        diskChanged = true
        print(String(format: "[FDC] Disk loaded: %d bytes (padded to 720KB), boot sig=0x%02X",
                     data.count, data.first ?? 0))
        return true
    }

    /// Eject the current disk.
    func ejectDisk() {
        diskImage = nil
        diskChanged = true
        motorOn = false
    }

    // MARK: - Sector I/O

    /// Read a single sector (512 bytes) by logical sector number.
    /// MSX logical sector layout: sector 0 = track 0, side 0, physical sector 1.
    func readSector(logicalSector: Int) -> [UInt8]? {
        guard let disk = diskImage else { return nil }
        let offset = logicalSector * FDC.sectorSize
        guard offset >= 0, offset + FDC.sectorSize <= disk.count else { return nil }
        return Array(disk[offset..<(offset + FDC.sectorSize)])
    }

    /// Write a single sector (512 bytes) by logical sector number.
    func writeSector(logicalSector: Int, data: [UInt8]) -> Bool {
        guard diskImage != nil else { return false }
        let offset = logicalSector * FDC.sectorSize
        guard offset >= 0, offset + FDC.sectorSize <= diskImage!.count else { return false }
        guard data.count >= FDC.sectorSize else { return false }
        for i in 0..<FDC.sectorSize {
            diskImage![offset + i] = data[i]
        }
        return true
    }

    /// Read multiple contiguous sectors. Returns nil on error.
    func readSectors(startSector: Int, count: Int) -> [UInt8]? {
        guard let disk = diskImage, count > 0 else { return nil }
        let offset = startSector * FDC.sectorSize
        let length = count * FDC.sectorSize
        guard offset >= 0, offset + length <= disk.count else { return nil }
        return Array(disk[offset..<(offset + length)])
    }

    /// Write multiple contiguous sectors from a buffer. Returns true on success.
    func writeSectors(startSector: Int, data: [UInt8], count: Int) -> Bool {
        guard diskImage != nil, count > 0 else { return false }
        let offset = startSector * FDC.sectorSize
        let length = count * FDC.sectorSize
        guard offset >= 0, offset + length <= diskImage!.count else { return false }
        guard data.count >= length else { return false }
        for i in 0..<length {
            diskImage![offset + i] = data[i]
        }
        return true
    }
}
