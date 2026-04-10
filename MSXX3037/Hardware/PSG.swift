// PSG.swift - AY-3-8910 Programmable Sound Generator
// Reference: AY-3-8910 Datasheet

import Foundation
import AVFoundation

final class PSG {
    // MARK: - Registers
    var regs = [UInt8](repeating: 0, count: 16)
    var addressLatch: UInt8 = 0

    // MARK: - I/O ports (MSX keyboard matrix)
    var portA: UInt8 = 0xFF  // Keyboard row input
    var portB: UInt8 = 0xFF  // Output (slot/keyboard select on MSX)
    var portARead: (() -> UInt8)?
    var portBWrite: ((UInt8) -> Void)?

    // MARK: - Register access
    func writeAddress(_ value: UInt8) {
        addressLatch = value & 0x0F
    }

    func writeData(_ value: UInt8) {
        regs[Int(addressLatch)] = value
        if addressLatch == 14 { portARead.map { _ in } }
        if addressLatch == 15 { portBWrite?(value) }
    }

    func readData() -> UInt8 {
        if addressLatch == 14 {
            return portARead?() ?? portA
        }
        return regs[Int(addressLatch)]
    }

    // MARK: - Audio generation
    // Tone period for each channel (A=regs 0,1; B=regs 2,3; C=regs 4,5)
    func tonePeriod(_ ch: Int) -> UInt16 {
        let lo = UInt16(regs[ch * 2] & 0xFF)
        let hi = UInt16(regs[ch * 2 + 1] & 0x0F)
        return (hi << 8) | lo
    }

    func noisePeriod() -> UInt8 { regs[6] & 0x1F }

    func mixerControl() -> UInt8 { regs[7] }

    func volume(_ ch: Int) -> UInt8 { regs[8 + ch] & 0x1F }

    func envelopePeriod() -> UInt16 {
        return UInt16(regs[11]) | (UInt16(regs[12]) << 8)
    }

    func envelopeShape() -> UInt8 { regs[13] }
}

// MARK: - Audio Engine
final class PSGAudioEngine {
    private let psg: PSG
    private var audioEngine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?

    // Synthesis state
    private var phaseA: Double = 0
    private var phaseB: Double = 0
    private var phaseC: Double = 0
    private var envelopePhase: Double = 0
    private var envelopeLevel: Double = 1.0
    private let sampleRate: Double = 44100.0
    private let cpuClock: Double = 3579545.0  // 3.58 MHz MSX

    init(psg: PSG) {
        self.psg = psg
        setupAudio()
    }

    private func setupAudio() {
        // AVAudioSession を playback カテゴリに設定
        // 未設定だと iOS が通知・画面ロック等で音声セッションを中断する
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            print("PSG AudioSession: \(error)")
        }

        let engine = AVAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

        let node = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, bufferList in
            guard let self = self else { return noErr }
            self.fillBuffer(bufferList: bufferList, frameCount: Int(frameCount))
            return noErr
        }

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.3

        do {
            try engine.start()
            audioEngine = engine
            sourceNode = node
        } catch {
            print("PSG Audio Engine failed: \(error)")
        }
    }

    private func fillBuffer(bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        let ablPointer = UnsafeMutableAudioBufferListPointer(bufferList)
        guard let buffer = ablPointer[0].mData?.assumingMemoryBound(to: Float.self) else { return }

        let mixer = psg.mixerControl()
        let toneEnabledA = (mixer & 0x01) == 0
        let toneEnabledB = (mixer & 0x02) == 0
        let toneEnabledC = (mixer & 0x04) == 0

        let periodA = Double(max(1, psg.tonePeriod(0)))
        let periodB = Double(max(1, psg.tonePeriod(1)))
        let periodC = Double(max(1, psg.tonePeriod(2)))

        let freqA = cpuClock / (16.0 * periodA)
        let freqB = cpuClock / (16.0 * periodB)
        let freqC = cpuClock / (16.0 * periodC)

        let volA = Double(psg.volume(0) & 0x0F) / 15.0
        let volB = Double(psg.volume(1) & 0x0F) / 15.0
        let volC = Double(psg.volume(2) & 0x0F) / 15.0

        for i in 0..<frameCount {
            var sample: Double = 0

            if toneEnabledA && volA > 0 {
                phaseA += freqA / sampleRate
                if phaseA >= 1.0 { phaseA -= 1.0 }
                sample += (phaseA < 0.5 ? 1.0 : -1.0) * volA
            }
            if toneEnabledB && volB > 0 {
                phaseB += freqB / sampleRate
                if phaseB >= 1.0 { phaseB -= 1.0 }
                sample += (phaseB < 0.5 ? 1.0 : -1.0) * volB
            }
            if toneEnabledC && volC > 0 {
                phaseC += freqC / sampleRate
                if phaseC >= 1.0 { phaseC -= 1.0 }
                sample += (phaseC < 0.5 ? 1.0 : -1.0) * volC
            }

            buffer[i] = Float(sample / 3.0 * 0.5)
        }
    }

    func stop() {
        audioEngine?.stop()
    }
}
