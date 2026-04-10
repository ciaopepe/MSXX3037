// Z80.swift - Z80 CPU Emulator
// Reference: Z80 CPU User Manual, fMSX by Marat Fayzullin

import Foundation

final class Z80 {
    // MARK: - Registers
    var A: UInt8 = 0xFF;  var F: UInt8 = 0xFF
    var B: UInt8 = 0xFF;  var C: UInt8 = 0xFF
    var D: UInt8 = 0xFF;  var E: UInt8 = 0xFF
    var H: UInt8 = 0xFF;  var L: UInt8 = 0xFF

    // Alternate registers
    var A2: UInt8 = 0xFF; var F2: UInt8 = 0xFF
    var B2: UInt8 = 0xFF; var C2: UInt8 = 0xFF
    var D2: UInt8 = 0xFF; var E2: UInt8 = 0xFF
    var H2: UInt8 = 0xFF; var L2: UInt8 = 0xFF

    var IXH: UInt8 = 0xFF; var IXL: UInt8 = 0xFF
    var IYH: UInt8 = 0xFF; var IYL: UInt8 = 0xFF
    var SP: UInt16 = 0xFFFF
    var PC: UInt16 = 0x0000
    var I: UInt8 = 0x00
    var R: UInt8 = 0x00
    var IFF1: Bool = false
    var IFF2: Bool = false
    var IM: UInt8 = 0
    var halted: Bool = false
    var pendingEI: Bool = false

    // MARK: - Register pairs
    var AF: UInt16 { get { UInt16(A)<<8|UInt16(F) } set { A=UInt8(newValue>>8); F=UInt8(newValue&0xFF) } }
    var BC: UInt16 { get { UInt16(B)<<8|UInt16(C) } set { B=UInt8(newValue>>8); C=UInt8(newValue&0xFF) } }
    var DE: UInt16 { get { UInt16(D)<<8|UInt16(E) } set { D=UInt8(newValue>>8); E=UInt8(newValue&0xFF) } }
    var HL: UInt16 { get { UInt16(H)<<8|UInt16(L) } set { H=UInt8(newValue>>8); L=UInt8(newValue&0xFF) } }
    var IX: UInt16 { get { UInt16(IXH)<<8|UInt16(IXL) } set { IXH=UInt8(newValue>>8); IXL=UInt8(newValue&0xFF) } }
    var IY: UInt16 { get { UInt16(IYH)<<8|UInt16(IYL) } set { IYH=UInt8(newValue>>8); IYL=UInt8(newValue&0xFF) } }

    // MARK: - Flags (bit positions)
    static let FC: UInt8 = 0x01
    static let FN: UInt8 = 0x02
    static let FPV: UInt8 = 0x04
    static let FX: UInt8 = 0x08
    static let FH: UInt8 = 0x10
    static let FY: UInt8 = 0x20
    static let FZ: UInt8 = 0x40
    static let FS: UInt8 = 0x80

    var flagC: Bool  { get { F & Z80.FC != 0 }  set { if newValue { F|=Z80.FC  } else { F &= ~Z80.FC  } } }
    var flagN: Bool  { get { F & Z80.FN != 0 }  set { if newValue { F|=Z80.FN  } else { F &= ~Z80.FN  } } }
    var flagPV: Bool { get { F & Z80.FPV != 0 } set { if newValue { F|=Z80.FPV } else { F &= ~Z80.FPV } } }
    var flagH: Bool  { get { F & Z80.FH != 0 }  set { if newValue { F|=Z80.FH  } else { F &= ~Z80.FH  } } }
    var flagZ: Bool  { get { F & Z80.FZ != 0 }  set { if newValue { F|=Z80.FZ  } else { F &= ~Z80.FZ  } } }
    var flagS: Bool  { get { F & Z80.FS != 0 }  set { if newValue { F|=Z80.FS  } else { F &= ~Z80.FS  } } }

    // MARK: - Memory/IO callbacks
    var memRead:  (UInt16) -> UInt8                = { _ in 0xFF }
    var memWrite: (UInt16, UInt8) -> Void          = { _,_ in }
    var ioRead:   (UInt8) -> UInt8                 = { _ in 0xFF }
    var ioWrite:  (UInt8, UInt8) -> Void           = { _,_ in }
    var requestNMI: Bool = false

    // MARK: - Reset
    func reset() {
        A=0xFF; F=0xFF; B=0xFF; C=0xFF; D=0xFF; E=0xFF; H=0xFF; L=0xFF
        A2=0xFF; F2=0xFF; B2=0xFF; C2=0xFF; D2=0xFF; E2=0xFF; H2=0xFF; L2=0xFF
        IXH=0xFF; IXL=0xFF; IYH=0xFF; IYL=0xFF
        SP=0xFFFF; PC=0x0000; I=0; R=0
        IFF1=false; IFF2=false; IM=0; halted=false; pendingEI=false
    }

    // MARK: - Execute one instruction, return T-states
    func step() -> Int {
        if halted { return 4 }

        if pendingEI {
            pendingEI = false
            IFF1 = true; IFF2 = true
        }

        let opcode = fetchByte()
        R = (R &+ 1) & 0x7F

        switch opcode {
        case 0x00: return 4  // NOP
        case 0x01: BC = fetchWord(); return 10
        case 0x02: memWrite(BC, A); return 7
        case 0x03: BC = BC &+ 1; return 6
        case 0x04: B = incR(B); return 4
        case 0x05: B = decR(B); return 4
        case 0x06: B = fetchByte(); return 7
        case 0x07: rlca(); return 4
        case 0x08: let t=A; A=A2; A2=t; let f=F; F=F2; F2=f; return 4  // EX AF,AF'
        case 0x09: addHL(BC); return 11
        case 0x0A: A = memRead(BC); return 7
        case 0x0B: BC = BC &- 1; return 6
        case 0x0C: C = incR(C); return 4
        case 0x0D: C = decR(C); return 4
        case 0x0E: C = fetchByte(); return 7
        case 0x0F: rrca(); return 4
        case 0x10: let e=Int8(bitPattern:fetchByte()); B=B &- 1; if B != 0 { PC=UInt16(bitPattern:Int16(bitPattern:PC) &+ Int16(e)); return 13 }; return 8  // DJNZ
        case 0x11: DE = fetchWord(); return 10
        case 0x12: memWrite(DE, A); return 7
        case 0x13: DE = DE &+ 1; return 6
        case 0x14: D = incR(D); return 4
        case 0x15: D = decR(D); return 4
        case 0x16: D = fetchByte(); return 7
        case 0x17: rla(); return 4
        case 0x18: let e=Int8(bitPattern:fetchByte()); PC=UInt16(bitPattern:Int16(bitPattern:PC) &+ Int16(e)); return 12  // JR
        case 0x19: addHL(DE); return 11
        case 0x1A: A = memRead(DE); return 7
        case 0x1B: DE = DE &- 1; return 6
        case 0x1C: E = incR(E); return 4
        case 0x1D: E = decR(E); return 4
        case 0x1E: E = fetchByte(); return 7
        case 0x1F: rra(); return 4
        case 0x20: return jr(!flagZ)  // JR NZ
        case 0x21: HL = fetchWord(); return 10
        case 0x22: let nn=fetchWord(); memWrite(nn,L); memWrite(nn &+ 1,H); return 16
        case 0x23: HL = HL &+ 1; return 6
        case 0x24: H = incR(H); return 4
        case 0x25: H = decR(H); return 4
        case 0x26: H = fetchByte(); return 7
        case 0x27: daa(); return 4
        case 0x28: return jr(flagZ)   // JR Z
        case 0x29: addHL(HL); return 11
        case 0x2A: let nn=fetchWord(); L=memRead(nn); H=memRead(nn &+ 1); return 16
        case 0x2B: HL = HL &- 1; return 6
        case 0x2C: L = incR(L); return 4
        case 0x2D: L = decR(L); return 4
        case 0x2E: L = fetchByte(); return 7
        case 0x2F: A = ~A; flagH=true; flagN=true; return 4  // CPL
        case 0x30: return jr(!flagC)  // JR NC
        case 0x31: SP = fetchWord(); return 10
        case 0x32: let nn=fetchWord(); memWrite(nn,A); return 13
        case 0x33: SP = SP &+ 1; return 6
        case 0x34: memWrite(HL, incR(memRead(HL))); return 11
        case 0x35: memWrite(HL, decR(memRead(HL))); return 11
        case 0x36: memWrite(HL, fetchByte()); return 10
        case 0x37: flagC=true; flagN=false; flagH=false; return 4  // SCF
        case 0x38: return jr(flagC)   // JR C
        case 0x39: addHL(SP); return 11
        case 0x3A: let nn=fetchWord(); A=memRead(nn); return 13
        case 0x3B: SP = SP &- 1; return 6
        case 0x3C: A = incR(A); return 4
        case 0x3D: A = decR(A); return 4
        case 0x3E: A = fetchByte(); return 7
        case 0x3F: let old=flagC; flagH=old; flagC = !old; flagN=false; return 4  // CCF
        // LD r,r'  0x40-0x7F
        case 0x40...0x7F:
            if opcode == 0x76 { halted=true; return 4 }  // HALT
            let dst = (opcode >> 3) & 7
            let src = opcode & 7
            setReg(dst, getReg(src))
            return (src == 6 || dst == 6) ? 7 : 4
        // ALU operations 0x80-0xBF
        case 0x80...0xBF:
            let r = getReg(opcode & 7)
            switch (opcode >> 3) & 7 {
            case 0: addA(r)
            case 1: adcA(r)
            case 2: subA(r)
            case 3: sbcA(r)
            case 4: andA(r)
            case 5: xorA(r)
            case 6: orA(r)
            default: cpA(r)
            }
            return (opcode & 7 == 6) ? 7 : 4
        case 0xC0: return retCond(!flagZ)   // RET NZ
        case 0xC1: BC = pop(); return 10
        case 0xC2: return jpCond(!flagZ)    // JP NZ,nn
        case 0xC3: PC = fetchWord(); return 10  // JP nn
        case 0xC4: return callCond(!flagZ)  // CALL NZ,nn
        case 0xC5: push(BC); return 11
        case 0xC6: addA(fetchByte()); return 7
        case 0xC7: push(PC); PC=0x00; return 11  // RST 0
        case 0xC8: return retCond(flagZ)    // RET Z
        case 0xC9: PC = pop(); return 10    // RET
        case 0xCA: return jpCond(flagZ)     // JP Z,nn
        case 0xCB: return executeCB()
        case 0xCC: return callCond(flagZ)   // CALL Z,nn
        case 0xCD: let nn=fetchWord(); push(PC); PC=nn; return 17  // CALL nn
        case 0xCE: adcA(fetchByte()); return 7
        case 0xCF: push(PC); PC=0x08; return 11  // RST 8
        case 0xD0: return retCond(!flagC)   // RET NC
        case 0xD1: DE = pop(); return 10
        case 0xD2: return jpCond(!flagC)    // JP NC,nn
        case 0xD3: let n=fetchByte(); ioWrite(n, A); return 11  // OUT (n),A
        case 0xD4: return callCond(!flagC)  // CALL NC,nn
        case 0xD5: push(DE); return 11
        case 0xD6: subA(fetchByte()); return 7
        case 0xD7: push(PC); PC=0x10; return 11  // RST 10
        case 0xD8: return retCond(flagC)    // RET C
        case 0xD9: let tb=B;B=B2;B2=tb; let tc=C;C=C2;C2=tc; let td=D;D=D2;D2=td; let te=E;E=E2;E2=te; let th=H;H=H2;H2=th; let tl=L;L=L2;L2=tl; return 4  // EXX
        case 0xDA: return jpCond(flagC)     // JP C,nn
        case 0xDB: let n=fetchByte(); A=ioRead(n); return 11  // IN A,(n)
        case 0xDC: return callCond(flagC)   // CALL C,nn
        case 0xDD: return executeDD()
        case 0xDE: sbcA(fetchByte()); return 7
        case 0xDF: push(PC); PC=0x18; return 11  // RST 18
        case 0xE0: return retCond(!flagPV)  // RET PO
        case 0xE1: HL = pop(); return 10
        case 0xE2: return jpCond(!flagPV)   // JP PO,nn
        case 0xE3: let t=memRead(SP); memWrite(SP,L); L=t; let t2=memRead(SP &+ 1); memWrite(SP &+ 1,H); H=t2; return 19  // EX (SP),HL
        case 0xE4: return callCond(!flagPV) // CALL PO,nn
        case 0xE5: push(HL); return 11
        case 0xE6: andA(fetchByte()); return 7
        case 0xE7: push(PC); PC=0x20; return 11  // RST 20
        case 0xE8: return retCond(flagPV)   // RET PE
        case 0xE9: PC = HL; return 4        // JP (HL)
        case 0xEA: return jpCond(flagPV)    // JP PE,nn
        case 0xEB: let th=H;H=D;D=th; let tl=L;L=E;E=tl; return 4  // EX DE,HL
        case 0xEC: return callCond(flagPV)  // CALL PE,nn
        case 0xED: return executeED()
        case 0xEE: xorA(fetchByte()); return 7
        case 0xEF: push(PC); PC=0x28; return 11  // RST 28
        case 0xF0: return retCond(!flagS)   // RET P
        case 0xF1: AF = pop(); return 10
        case 0xF2: return jpCond(!flagS)    // JP P,nn
        case 0xF3: IFF1=false; IFF2=false; return 4  // DI
        case 0xF4: return callCond(!flagS)  // CALL P,nn
        case 0xF5: push(AF); return 11
        case 0xF6: orA(fetchByte()); return 7
        case 0xF7: push(PC); PC=0x30; return 11  // RST 30
        case 0xF8: return retCond(flagS)    // RET M
        case 0xF9: SP = HL; return 6        // LD SP,HL
        case 0xFA: return jpCond(flagS)     // JP M,nn
        case 0xFB: pendingEI = true; return 4  // EI
        case 0xFC: return callCond(flagS)   // CALL M,nn
        case 0xFD: return executeFD()
        case 0xFE: cpA(fetchByte()); return 7
        case 0xFF: push(PC); PC=0x38; return 11  // RST 38
        default: return 4
        }
    }

    // MARK: - Interrupt
    func interrupt() -> Int {
        guard IFF1 else { return 0 }
        IFF1=false; IFF2=false; halted=false
        switch IM {
        case 1:
            push(PC); PC=0x0038; return 13
        case 2:
            let vec = UInt16(I)<<8 | 0xFF
            let lo = memRead(vec); let hi = memRead(vec &+ 1)
            push(PC); PC = UInt16(hi)<<8|UInt16(lo); return 19
        default:
            push(PC); PC=0x0038; return 13
        }
    }

    // MARK: - CB prefix (bit ops)
    private func executeCB() -> Int {
        R = (R &+ 1) & 0x7F
        let op = fetchByte()
        let r = op & 7
        let v = getRegCB(r)
        let result: UInt8
        let base: Int
        switch op >> 3 {
        case 0: result = rlc(v); setRegCB(r, result); base = (r==6) ? 15 : 8
        case 1: result = rrc(v); setRegCB(r, result); base = (r==6) ? 15 : 8
        case 2: result = rl(v);  setRegCB(r, result); base = (r==6) ? 15 : 8
        case 3: result = rr(v);  setRegCB(r, result); base = (r==6) ? 15 : 8
        case 4: result = sla(v); setRegCB(r, result); base = (r==6) ? 15 : 8
        case 5: result = sra(v); setRegCB(r, result); base = (r==6) ? 15 : 8
        case 6: result = sll(v); setRegCB(r, result); base = (r==6) ? 15 : 8
        case 7: result = srl(v); setRegCB(r, result); base = (r==6) ? 15 : 8
        case 8...15: // BIT
            let bit = UInt8((op >> 3) & 7)
            let masked = v & (1 << bit)
            flagZ = masked == 0; flagN = false; flagH = true
            flagS = (bit == 7) && (masked != 0)
            flagPV = masked == 0
            return (r==6) ? 12 : 8
        case 16...23: // RES
            let bit = UInt8((op >> 3) & 7)
            result = v & ~(1 << bit); setRegCB(r, result); base = (r==6) ? 15 : 8
        default: // SET
            let bit = UInt8((op >> 3) & 7)
            result = v | (1 << bit); setRegCB(r, result); base = (r==6) ? 15 : 8
        }
        return base
    }

    // MARK: - DD prefix (IX)
    private func executeDD() -> Int {
        R = (R &+ 1) & 0x7F
        let op = fetchByte()
        switch op {
        case 0x09: addIX(BC); return 15
        case 0x19: addIX(DE); return 15
        case 0x21: IX = fetchWord(); return 14
        case 0x22: let nn=fetchWord(); memWrite(nn,IXL); memWrite(nn &+ 1,IXH); return 20
        case 0x23: IX = IX &+ 1; return 10
        case 0x24: IXH = incR(IXH); return 8
        case 0x25: IXH = decR(IXH); return 8
        case 0x26: IXH = fetchByte(); return 11
        case 0x29: addIX(IX); return 15
        case 0x2A: let nn=fetchWord(); IXL=memRead(nn); IXH=memRead(nn &+ 1); return 20
        case 0x2B: IX = IX &- 1; return 10
        case 0x2C: IXL = incR(IXL); return 8
        case 0x2D: IXL = decR(IXL); return 8
        case 0x2E: IXL = fetchByte(); return 11
        case 0x34: let d=fetchDisp(); let addr=IX &+ UInt16(bitPattern:Int16(d)); memWrite(addr, incR(memRead(addr))); return 23
        case 0x35: let d=fetchDisp(); let addr=IX &+ UInt16(bitPattern:Int16(d)); memWrite(addr, decR(memRead(addr))); return 23
        case 0x36: let d=fetchDisp(); let addr=IX &+ UInt16(bitPattern:Int16(d)); memWrite(addr,fetchByte()); return 19
        case 0x39: addIX(SP); return 15
        case 0x44: B=IXH; return 8
        case 0x45: B=IXL; return 8
        case 0x46: let d=fetchDisp(); B=memRead(IX &+ UInt16(bitPattern:Int16(d))); return 19
        case 0x4C: C=IXH; return 8
        case 0x4D: C=IXL; return 8
        case 0x4E: let d=fetchDisp(); C=memRead(IX &+ UInt16(bitPattern:Int16(d))); return 19
        case 0x54: D=IXH; return 8
        case 0x55: D=IXL; return 8
        case 0x56: let d=fetchDisp(); D=memRead(IX &+ UInt16(bitPattern:Int16(d))); return 19
        case 0x5C: E=IXH; return 8
        case 0x5D: E=IXL; return 8
        case 0x5E: let d=fetchDisp(); E=memRead(IX &+ UInt16(bitPattern:Int16(d))); return 19
        case 0x60: IXH=B; return 8; case 0x61: IXH=C; return 8
        case 0x62: IXH=D; return 8; case 0x63: IXH=E; return 8
        case 0x64: return 8; case 0x65: IXH=IXL; return 8
        case 0x66: let d=fetchDisp(); H=memRead(IX &+ UInt16(bitPattern:Int16(d))); return 19
        case 0x67: IXH=A; return 8
        case 0x68: IXL=B; return 8; case 0x69: IXL=C; return 8
        case 0x6A: IXL=D; return 8; case 0x6B: IXL=E; return 8
        case 0x6C: IXL=IXH; return 8; case 0x6D: return 8
        case 0x6E: let d=fetchDisp(); L=memRead(IX &+ UInt16(bitPattern:Int16(d))); return 19
        case 0x6F: IXL=A; return 8
        case 0x70: let d=fetchDisp(); memWrite(IX &+ UInt16(bitPattern:Int16(d)),B); return 19
        case 0x71: let d=fetchDisp(); memWrite(IX &+ UInt16(bitPattern:Int16(d)),C); return 19
        case 0x72: let d=fetchDisp(); memWrite(IX &+ UInt16(bitPattern:Int16(d)),D); return 19
        case 0x73: let d=fetchDisp(); memWrite(IX &+ UInt16(bitPattern:Int16(d)),E); return 19
        case 0x74: let d=fetchDisp(); memWrite(IX &+ UInt16(bitPattern:Int16(d)),H); return 19
        case 0x75: let d=fetchDisp(); memWrite(IX &+ UInt16(bitPattern:Int16(d)),L); return 19
        case 0x77: let d=fetchDisp(); memWrite(IX &+ UInt16(bitPattern:Int16(d)),A); return 19
        case 0x7C: A=IXH; return 8
        case 0x7D: A=IXL; return 8
        case 0x7E: let d=fetchDisp(); A=memRead(IX &+ UInt16(bitPattern:Int16(d))); return 19
        case 0x84: addA(IXH); return 8; case 0x85: addA(IXL); return 8
        case 0x86: let d=fetchDisp(); addA(memRead(IX &+ UInt16(bitPattern:Int16(d)))); return 19
        case 0x8C: adcA(IXH); return 8; case 0x8D: adcA(IXL); return 8
        case 0x8E: let d=fetchDisp(); adcA(memRead(IX &+ UInt16(bitPattern:Int16(d)))); return 19
        case 0x94: subA(IXH); return 8; case 0x95: subA(IXL); return 8
        case 0x96: let d=fetchDisp(); subA(memRead(IX &+ UInt16(bitPattern:Int16(d)))); return 19
        case 0x9C: sbcA(IXH); return 8; case 0x9D: sbcA(IXL); return 8
        case 0x9E: let d=fetchDisp(); sbcA(memRead(IX &+ UInt16(bitPattern:Int16(d)))); return 19
        case 0xA4: andA(IXH); return 8; case 0xA5: andA(IXL); return 8
        case 0xA6: let d=fetchDisp(); andA(memRead(IX &+ UInt16(bitPattern:Int16(d)))); return 19
        case 0xAC: xorA(IXH); return 8; case 0xAD: xorA(IXL); return 8
        case 0xAE: let d=fetchDisp(); xorA(memRead(IX &+ UInt16(bitPattern:Int16(d)))); return 19
        case 0xB4: orA(IXH); return 8; case 0xB5: orA(IXL); return 8
        case 0xB6: let d=fetchDisp(); orA(memRead(IX &+ UInt16(bitPattern:Int16(d)))); return 19
        case 0xBC: cpA(IXH); return 8; case 0xBD: cpA(IXL); return 8
        case 0xBE: let d=fetchDisp(); cpA(memRead(IX &+ UInt16(bitPattern:Int16(d)))); return 19
        case 0xCB: return executeDDCB()
        case 0xE1: IX = pop(); return 14
        case 0xE3: let t=memRead(SP); memWrite(SP,IXL); IXL=t; let t2=memRead(SP &+ 1); memWrite(SP &+ 1,IXH); IXH=t2; return 23
        case 0xE5: push(IX); return 15
        case 0xE9: PC=IX; return 8
        case 0xF9: SP=IX; return 10
        default: return 8
        }
    }

    // MARK: - FD prefix (IY)
    private func executeFD() -> Int {
        R = (R &+ 1) & 0x7F
        let op = fetchByte()
        switch op {
        case 0x09: addIY(BC); return 15
        case 0x19: addIY(DE); return 15
        case 0x21: IY = fetchWord(); return 14
        case 0x22: let nn=fetchWord(); memWrite(nn,IYL); memWrite(nn &+ 1,IYH); return 20
        case 0x23: IY = IY &+ 1; return 10
        case 0x24: IYH = incR(IYH); return 8
        case 0x25: IYH = decR(IYH); return 8
        case 0x26: IYH = fetchByte(); return 11
        case 0x29: addIY(IY); return 15
        case 0x2A: let nn=fetchWord(); IYL=memRead(nn); IYH=memRead(nn &+ 1); return 20
        case 0x2B: IY = IY &- 1; return 10
        case 0x2C: IYL = incR(IYL); return 8
        case 0x2D: IYL = decR(IYL); return 8
        case 0x2E: IYL = fetchByte(); return 11
        case 0x34: let d=fetchDisp(); let addr=IY &+ UInt16(bitPattern:Int16(d)); memWrite(addr, incR(memRead(addr))); return 23
        case 0x35: let d=fetchDisp(); let addr=IY &+ UInt16(bitPattern:Int16(d)); memWrite(addr, decR(memRead(addr))); return 23
        case 0x36: let d=fetchDisp(); let addr=IY &+ UInt16(bitPattern:Int16(d)); memWrite(addr,fetchByte()); return 19
        case 0x39: addIY(SP); return 15
        case 0x44: B=IYH; return 8; case 0x45: B=IYL; return 8
        case 0x46: let d=fetchDisp(); B=memRead(IY &+ UInt16(bitPattern:Int16(d))); return 19
        case 0x4C: C=IYH; return 8; case 0x4D: C=IYL; return 8
        case 0x4E: let d=fetchDisp(); C=memRead(IY &+ UInt16(bitPattern:Int16(d))); return 19
        case 0x54: D=IYH; return 8; case 0x55: D=IYL; return 8
        case 0x56: let d=fetchDisp(); D=memRead(IY &+ UInt16(bitPattern:Int16(d))); return 19
        case 0x5C: E=IYH; return 8; case 0x5D: E=IYL; return 8
        case 0x5E: let d=fetchDisp(); E=memRead(IY &+ UInt16(bitPattern:Int16(d))); return 19
        case 0x60: IYH=B; return 8; case 0x61: IYH=C; return 8
        case 0x62: IYH=D; return 8; case 0x63: IYH=E; return 8
        case 0x64: return 8; case 0x65: IYH=IYL; return 8
        case 0x66: let d=fetchDisp(); H=memRead(IY &+ UInt16(bitPattern:Int16(d))); return 19
        case 0x67: IYH=A; return 8
        case 0x68: IYL=B; return 8; case 0x69: IYL=C; return 8
        case 0x6A: IYL=D; return 8; case 0x6B: IYL=E; return 8
        case 0x6C: IYL=IYH; return 8; case 0x6D: return 8
        case 0x6E: let d=fetchDisp(); L=memRead(IY &+ UInt16(bitPattern:Int16(d))); return 19
        case 0x6F: IYL=A; return 8
        case 0x70: let d=fetchDisp(); memWrite(IY &+ UInt16(bitPattern:Int16(d)),B); return 19
        case 0x71: let d=fetchDisp(); memWrite(IY &+ UInt16(bitPattern:Int16(d)),C); return 19
        case 0x72: let d=fetchDisp(); memWrite(IY &+ UInt16(bitPattern:Int16(d)),D); return 19
        case 0x73: let d=fetchDisp(); memWrite(IY &+ UInt16(bitPattern:Int16(d)),E); return 19
        case 0x74: let d=fetchDisp(); memWrite(IY &+ UInt16(bitPattern:Int16(d)),H); return 19
        case 0x75: let d=fetchDisp(); memWrite(IY &+ UInt16(bitPattern:Int16(d)),L); return 19
        case 0x77: let d=fetchDisp(); memWrite(IY &+ UInt16(bitPattern:Int16(d)),A); return 19
        case 0x7C: A=IYH; return 8
        case 0x7D: A=IYL; return 8
        case 0x7E: let d=fetchDisp(); A=memRead(IY &+ UInt16(bitPattern:Int16(d))); return 19
        case 0x84: addA(IYH); return 8; case 0x85: addA(IYL); return 8
        case 0x86: let d=fetchDisp(); addA(memRead(IY &+ UInt16(bitPattern:Int16(d)))); return 19
        case 0x8C: adcA(IYH); return 8; case 0x8D: adcA(IYL); return 8
        case 0x8E: let d=fetchDisp(); adcA(memRead(IY &+ UInt16(bitPattern:Int16(d)))); return 19
        case 0x94: subA(IYH); return 8; case 0x95: subA(IYL); return 8
        case 0x96: let d=fetchDisp(); subA(memRead(IY &+ UInt16(bitPattern:Int16(d)))); return 19
        case 0x9C: sbcA(IYH); return 8; case 0x9D: sbcA(IYL); return 8
        case 0x9E: let d=fetchDisp(); sbcA(memRead(IY &+ UInt16(bitPattern:Int16(d)))); return 19
        case 0xA4: andA(IYH); return 8; case 0xA5: andA(IYL); return 8
        case 0xA6: let d=fetchDisp(); andA(memRead(IY &+ UInt16(bitPattern:Int16(d)))); return 19
        case 0xAC: xorA(IYH); return 8; case 0xAD: xorA(IYL); return 8
        case 0xAE: let d=fetchDisp(); xorA(memRead(IY &+ UInt16(bitPattern:Int16(d)))); return 19
        case 0xB4: orA(IYH); return 8; case 0xB5: orA(IYL); return 8
        case 0xB6: let d=fetchDisp(); orA(memRead(IY &+ UInt16(bitPattern:Int16(d)))); return 19
        case 0xBC: cpA(IYH); return 8; case 0xBD: cpA(IYL); return 8
        case 0xBE: let d=fetchDisp(); cpA(memRead(IY &+ UInt16(bitPattern:Int16(d)))); return 19
        case 0xCB: return executeFDCB()
        case 0xE1: IY = pop(); return 14
        case 0xE3: let t=memRead(SP); memWrite(SP,IYL); IYL=t; let t2=memRead(SP &+ 1); memWrite(SP &+ 1,IYH); IYH=t2; return 23
        case 0xE5: push(IY); return 15
        case 0xE9: PC=IY; return 8
        case 0xF9: SP=IY; return 10
        default: return 8
        }
    }

    // MARK: - ED prefix
    private func executeED() -> Int {
        R = (R &+ 1) & 0x7F
        let op = fetchByte()
        switch op {
        case 0x40: let v=ioRead(C); setFlags_IO(v); B=v; return 12  // IN B,(C)
        case 0x41: ioWrite(C, B); return 12  // OUT (C),B
        case 0x42: sbcHL(BC); return 15
        case 0x43: let nn=fetchWord(); memWrite(nn,C); memWrite(nn &+ 1,B); return 20
        case 0x44: negA(); return 8  // NEG
        case 0x45: IFF1=IFF2; PC=pop(); return 14  // RETN
        case 0x46: IM=0; return 8
        case 0x47: I=A; return 9  // LD I,A
        case 0x48: let v=ioRead(C); setFlags_IO(v); C=v; return 12
        case 0x49: ioWrite(C, C); return 12
        case 0x4A: adcHL(BC); return 15
        case 0x4B: let nn=fetchWord(); C=memRead(nn); B=memRead(nn &+ 1); return 20
        case 0x4D: IFF1=IFF2; PC=pop(); return 14  // RETI
        case 0x4F: R=A; return 9  // LD R,A
        case 0x50: let v=ioRead(C); setFlags_IO(v); D=v; return 12
        case 0x51: ioWrite(C, D); return 12
        case 0x52: sbcHL(DE); return 15
        case 0x53: let nn=fetchWord(); memWrite(nn,E); memWrite(nn &+ 1,D); return 20
        case 0x56: IM=1; return 8
        case 0x57: A=I; flagS=(A&0x80) != 0; flagZ=(A == 0); flagH=false; flagN=false; flagPV=IFF2; return 9  // LD A,I
        case 0x58: let v=ioRead(C); setFlags_IO(v); E=v; return 12
        case 0x59: ioWrite(C, E); return 12
        case 0x5A: adcHL(DE); return 15
        case 0x5B: let nn=fetchWord(); E=memRead(nn); D=memRead(nn &+ 1); return 20
        case 0x5E: IM=2; return 8
        case 0x5F: A=R; flagS=(A&0x80) != 0; flagZ=(A == 0); flagH=false; flagN=false; flagPV=IFF2; return 9  // LD A,R
        case 0x60: let v=ioRead(C); setFlags_IO(v); H=v; return 12
        case 0x61: ioWrite(C, H); return 12
        case 0x62: sbcHL(HL); return 15
        case 0x63: let nn=fetchWord(); memWrite(nn,L); memWrite(nn &+ 1,H); return 20
        case 0x67: rrd(); return 18  // RRD
        case 0x68: let v=ioRead(C); setFlags_IO(v); L=v; return 12
        case 0x69: ioWrite(C, L); return 12
        case 0x6A: adcHL(HL); return 15
        case 0x6B: let nn=fetchWord(); L=memRead(nn); H=memRead(nn &+ 1); return 20
        case 0x6F: rld(); return 18  // RLD
        case 0x72: sbcHL(SP); return 15
        case 0x73: let nn=fetchWord(); memWrite(nn,UInt8(SP&0xFF)); memWrite(nn &+ 1,UInt8(SP>>8)); return 20
        case 0x78: let v=ioRead(C); setFlags_IO(v); A=v; return 12
        case 0x79: ioWrite(C, A); return 12
        case 0x7A: adcHL(SP); return 15
        case 0x7B: let nn=fetchWord(); SP=UInt16(memRead(nn &+ 1))<<8|UInt16(memRead(nn)); return 20
        case 0xA0: ldi(); return 16
        case 0xA1: cpi(); return 16
        case 0xA2: ini(); return 16
        case 0xA3: outi(); return 16
        case 0xA8: ldd(); return 16
        case 0xA9: cpd(); return 16
        case 0xAA: ind(); return 16
        case 0xAB: outd(); return 16
        case 0xB0: ldir(); return flagPV ? 21 : 16
        case 0xB1: cpir(); return flagPV ? 21 : 16
        case 0xB2: inir(); return flagPV ? 21 : 16
        case 0xB3: otir(); return flagPV ? 21 : 16
        case 0xB8: lddr(); return flagPV ? 21 : 16
        case 0xB9: cpdr(); return flagPV ? 21 : 16
        case 0xBA: indr(); return flagPV ? 21 : 16
        case 0xBB: otdr(); return flagPV ? 21 : 16
        default: return 8
        }
    }

    // MARK: - DDCB / FDCB
    private func executeDDCB() -> Int {
        let d = fetchDisp()
        let op = fetchByte()
        let addr = IX &+ UInt16(bitPattern: Int16(d))
        return executeBitOp(op, addr: addr)
    }

    private func executeFDCB() -> Int {
        let d = fetchDisp()
        let op = fetchByte()
        let addr = IY &+ UInt16(bitPattern: Int16(d))
        return executeBitOp(op, addr: addr)
    }

    private func executeBitOp(_ op: UInt8, addr: UInt16) -> Int {
        let v = memRead(addr)
        let r = op & 7
        switch op >> 6 {
        case 0:
            let result: UInt8
            switch (op >> 3) & 7 {
            case 0: result=rlc(v); case 1: result=rrc(v)
            case 2: result=rl(v);  case 3: result=rr(v)
            case 4: result=sla(v); case 5: result=sra(v)
            case 6: result=sll(v)
            default: result=srl(v)
            }
            memWrite(addr, result)
            if r != 6 { setReg(r, result) }
            return 23
        case 1:
            let bit = UInt8((op >> 3) & 7)
            let masked = v & (1 << bit)
            flagZ = masked == 0; flagN = false; flagH = true
            flagS = (bit == 7) && (masked != 0); flagPV = masked == 0
            return 20
        case 2:
            let bit = UInt8((op >> 3) & 7)
            let result = v & ~(1 << bit)
            memWrite(addr, result)
            if r != 6 { setReg(r, result) }
            return 23
        default:
            let bit = UInt8((op >> 3) & 7)
            let result = v | (1 << bit)
            memWrite(addr, result)
            if r != 6 { setReg(r, result) }
            return 23
        }
    }

    // MARK: - Helpers
    @inline(__always)
    private func fetchByte() -> UInt8 {
        let b = memRead(PC); PC = PC &+ 1; return b
    }

    @inline(__always)
    private func fetchWord() -> UInt16 {
        let lo = fetchByte(); let hi = fetchByte()
        return UInt16(hi) << 8 | UInt16(lo)
    }

    @inline(__always)
    private func fetchDisp() -> Int8 {
        return Int8(bitPattern: fetchByte())
    }

    @inline(__always)
    private func push(_ v: UInt16) {
        SP = SP &- 1; memWrite(SP, UInt8(v >> 8))
        SP = SP &- 1; memWrite(SP, UInt8(v & 0xFF))
    }

    @inline(__always)
    private func pop() -> UInt16 {
        let lo = memRead(SP); SP = SP &+ 1
        let hi = memRead(SP); SP = SP &+ 1
        return UInt16(hi) << 8 | UInt16(lo)
    }

    // Register access by index (0=B,1=C,2=D,3=E,4=H,5=L,6=(HL),7=A)
    @inline(__always)
    func getReg(_ n: UInt8) -> UInt8 {
        switch n {
        case 0: return B; case 1: return C; case 2: return D; case 3: return E
        case 4: return H; case 5: return L; case 6: return memRead(HL); default: return A
        }
    }

    @inline(__always)
    func setReg(_ n: UInt8, _ v: UInt8) {
        switch n {
        case 0: B=v; case 1: C=v; case 2: D=v; case 3: E=v
        case 4: H=v; case 5: L=v; case 6: memWrite(HL,v); default: A=v
        }
    }

    @inline(__always)
    private func getRegCB(_ n: UInt8) -> UInt8 { getReg(n) }

    @inline(__always)
    private func setRegCB(_ n: UInt8, _ v: UInt8) { setReg(n, v) }

    // MARK: - ALU
    @inline(__always)
    private func incR(_ v: UInt8) -> UInt8 {
        let r = v &+ 1
        flagS = (r & 0x80) != 0; flagZ = r == 0
        flagH = (v & 0x0F) == 0x0F; flagPV = v == 0x7F; flagN = false
        return r
    }

    @inline(__always)
    private func decR(_ v: UInt8) -> UInt8 {
        let r = v &- 1
        flagS = (r & 0x80) != 0; flagZ = r == 0
        flagH = (v & 0x0F) == 0x00; flagPV = v == 0x80; flagN = true
        return r
    }

    @inline(__always)
    private func addA(_ n: UInt8) {
        let r = UInt16(A) + UInt16(n)
        flagC = r > 0xFF; flagH = ((A & 0xF) + (n & 0xF)) > 0xF
        flagPV = (~(A ^ n) & (UInt8(r & 0xFF) ^ A) & 0x80) != 0
        A = UInt8(r & 0xFF)
        flagS = (A & 0x80) != 0; flagZ = A == 0; flagN = false
    }

    @inline(__always)
    private func adcA(_ n: UInt8) {
        let c: UInt8 = flagC ? 1 : 0
        let r = UInt16(A) + UInt16(n) + UInt16(c)
        flagH = ((A & 0xF) + (n & 0xF) + c) > 0xF
        flagPV = (~(A ^ n) & (UInt8(r & 0xFF) ^ A) & 0x80) != 0
        flagC = r > 0xFF; A = UInt8(r & 0xFF)
        flagS = (A & 0x80) != 0; flagZ = A == 0; flagN = false
    }

    @inline(__always)
    private func subA(_ n: UInt8) {
        let r = UInt16(A) &- UInt16(n)
        flagC = A < n; flagH = (A & 0xF) < (n & 0xF)
        flagPV = ((A ^ n) & (A ^ UInt8(r & 0xFF)) & 0x80) != 0
        A = UInt8(r & 0xFF)
        flagS = (A & 0x80) != 0; flagZ = A == 0; flagN = true
    }

    @inline(__always)
    private func sbcA(_ n: UInt8) {
        let c: UInt8 = flagC ? 1 : 0
        let r = UInt16(A) &- UInt16(n) &- UInt16(c)
        flagH = (A & 0xF) < ((n & 0xF) + c)
        flagPV = ((A ^ n) & (A ^ UInt8(r & 0xFF)) & 0x80) != 0
        flagC = A < (UInt16(n) + UInt16(c)); A = UInt8(r & 0xFF)
        flagS = (A & 0x80) != 0; flagZ = A == 0; flagN = true
    }

    @inline(__always)
    private func andA(_ n: UInt8) {
        A &= n; flagS=(A&0x80) != 0; flagZ=(A==0)
        flagH=true; flagN=false; flagC=false; flagPV=parity(A)
    }

    @inline(__always)
    private func orA(_ n: UInt8) {
        A |= n; flagS=(A&0x80) != 0; flagZ=(A==0)
        flagH=false; flagN=false; flagC=false; flagPV=parity(A)
    }

    @inline(__always)
    private func xorA(_ n: UInt8) {
        A ^= n; flagS=(A&0x80) != 0; flagZ=(A==0)
        flagH=false; flagN=false; flagC=false; flagPV=parity(A)
    }

    @inline(__always)
    private func cpA(_ n: UInt8) {
        let r = UInt16(A) &- UInt16(n)
        flagC = A < n; flagH = (A & 0xF) < (n & 0xF)
        flagPV = ((A ^ n) & (A ^ UInt8(r & 0xFF)) & 0x80) != 0
        let res = UInt8(r & 0xFF)
        flagS = (res & 0x80) != 0; flagZ = res == 0; flagN = true
    }

    @inline(__always)
    private func addHL(_ n: UInt16) {
        let r = UInt32(HL) + UInt32(n)
        flagH = ((HL & 0xFFF) + (n & 0xFFF)) > 0xFFF
        flagC = r > 0xFFFF; flagN = false; HL = UInt16(r & 0xFFFF)
    }

    @inline(__always)
    private func addIX(_ n: UInt16) {
        let r = UInt32(IX) + UInt32(n)
        flagH = ((IX & 0xFFF) + (n & 0xFFF)) > 0xFFF
        flagC = r > 0xFFFF; flagN = false; IX = UInt16(r & 0xFFFF)
    }

    @inline(__always)
    private func addIY(_ n: UInt16) {
        let r = UInt32(IY) + UInt32(n)
        flagH = ((IY & 0xFFF) + (n & 0xFFF)) > 0xFFF
        flagC = r > 0xFFFF; flagN = false; IY = UInt16(r & 0xFFFF)
    }

    @inline(__always)
    private func adcHL(_ n: UInt16) {
        let c = UInt32(flagC ? 1 : 0)
        let r = UInt32(HL) + UInt32(n) + c
        flagH = ((UInt32(HL) & 0xFFF) + (UInt32(n) & 0xFFF) + c) > 0xFFF
        flagC = r > 0xFFFF
        flagPV = (~(UInt32(HL) ^ UInt32(n)) & (r ^ UInt32(HL)) & 0x8000) != 0
        HL = UInt16(r & 0xFFFF)
        flagS = (HL & 0x8000) != 0; flagZ = HL == 0; flagN = false
    }

    @inline(__always)
    private func sbcHL(_ n: UInt16) {
        let c = UInt32(flagC ? 1 : 0)
        let r = UInt32(HL) &- UInt32(n) &- c
        flagH = (UInt32(HL) & 0xFFF) < ((UInt32(n) & 0xFFF) + c)
        flagC = UInt32(HL) < (UInt32(n) + c)
        flagPV = ((UInt32(HL) ^ UInt32(n)) & (UInt32(HL) ^ r) & 0x8000) != 0
        HL = UInt16(r & 0xFFFF)
        flagS = (HL & 0x8000) != 0; flagZ = HL == 0; flagN = true
    }

    private func negA() {
        let old = A; A = 0; subA(old)
    }

    private func daa() {
        var correction: UInt8 = 0
        var c = false
        if flagH || (!flagN && (A & 0xF) > 9) { correction |= 0x06 }
        if flagC || (!flagN && A > 0x99) { correction |= 0x60; c = true }
        if flagN { A = A &- correction } else { A = A &+ correction }
        flagC = c; flagH = false
        flagS = (A & 0x80) != 0; flagZ = A == 0; flagPV = parity(A)
    }

    // MARK: - Rotation/Shift
    @inline(__always)
    private func rlca() {
        flagC = (A & 0x80) != 0; A = (A << 1) | (flagC ? 1 : 0); flagN=false; flagH=false
    }
    @inline(__always)
    private func rrca() {
        flagC = (A & 0x01) != 0; A = (A >> 1) | (flagC ? 0x80 : 0); flagN=false; flagH=false
    }
    @inline(__always)
    private func rla() {
        let old=flagC; flagC=(A & 0x80) != 0; A=(A<<1)|(old ? 1:0); flagN=false; flagH=false
    }
    @inline(__always)
    private func rra() {
        let old=flagC; flagC=(A & 0x01) != 0; A=(A>>1)|(old ? 0x80:0); flagN=false; flagH=false
    }

    @inline(__always)
    private func rlc(_ v: UInt8) -> UInt8 {
        flagC=(v & 0x80) != 0; let r=(v<<1)|(flagC ? 1:0)
        setRotFlags(r); return r
    }
    @inline(__always)
    private func rrc(_ v: UInt8) -> UInt8 {
        flagC=(v & 0x01) != 0; let r=(v>>1)|(flagC ? 0x80:0)
        setRotFlags(r); return r
    }
    @inline(__always)
    private func rl(_ v: UInt8) -> UInt8 {
        let old=flagC; flagC=(v & 0x80) != 0; let r=(v<<1)|(old ? 1:0)
        setRotFlags(r); return r
    }
    @inline(__always)
    private func rr(_ v: UInt8) -> UInt8 {
        let old=flagC; flagC=(v & 0x01) != 0; let r=(v>>1)|(old ? 0x80:0)
        setRotFlags(r); return r
    }
    @inline(__always)
    private func sla(_ v: UInt8) -> UInt8 {
        flagC=(v & 0x80) != 0; let r=v<<1; setRotFlags(r); return r
    }
    @inline(__always)
    private func sra(_ v: UInt8) -> UInt8 {
        flagC=(v & 0x01) != 0; let r=(v>>1)|(v & 0x80); setRotFlags(r); return r
    }
    @inline(__always)
    private func sll(_ v: UInt8) -> UInt8 {
        flagC=(v & 0x80) != 0; let r=(v<<1)|0x01; setRotFlags(r); return r
    }
    @inline(__always)
    private func srl(_ v: UInt8) -> UInt8 {
        flagC=(v & 0x01) != 0; let r=v>>1; setRotFlags(r); return r
    }

    @inline(__always)
    private func setRotFlags(_ v: UInt8) {
        flagS=(v & 0x80) != 0; flagZ=(v==0); flagH=false; flagN=false; flagPV=parity(v)
    }

    private func rld() {
        let m = memRead(HL)
        memWrite(HL, (m << 4) | (A & 0x0F))
        A = (A & 0xF0) | (m >> 4)
        flagS=(A & 0x80) != 0; flagZ=(A==0); flagH=false; flagN=false; flagPV=parity(A)
    }

    private func rrd() {
        let m = memRead(HL)
        memWrite(HL, (A << 4) | (m >> 4))
        A = (A & 0xF0) | (m & 0x0F)
        flagS=(A & 0x80) != 0; flagZ=(A==0); flagH=false; flagN=false; flagPV=parity(A)
    }

    // MARK: - Block instructions
    private func ldi() {
        memWrite(DE, memRead(HL)); DE=DE &+ 1; HL=HL &+ 1; BC=BC &- 1
        flagH=false; flagN=false; flagPV=(BC != 0)
    }
    private func ldd() {
        memWrite(DE, memRead(HL)); DE=DE &- 1; HL=HL &- 1; BC=BC &- 1
        flagH=false; flagN=false; flagPV=(BC != 0)
    }
    private func ldir() { ldi(); if flagPV { PC=PC &- 2 } }
    private func lddr() { ldd(); if flagPV { PC=PC &- 2 } }

    private func cpi() {
        let r = A &- memRead(HL); HL=HL &+ 1; BC=BC &- 1
        flagS=(r & 0x80) != 0; flagZ=(r==0); flagH=(A & 0xF) < (memRead(HL &- 1) & 0xF)
        flagN=true; flagPV=(BC != 0)
    }
    private func cpd() {
        let r = A &- memRead(HL); HL=HL &- 1; BC=BC &- 1
        flagS=(r & 0x80) != 0; flagZ=(r==0); flagH=(A & 0xF) < (memRead(HL &+ 1) & 0xF)
        flagN=true; flagPV=(BC != 0)
    }
    private func cpir() { cpi(); if flagPV && !flagZ { PC=PC &- 2 } }
    private func cpdr() { cpd(); if flagPV && !flagZ { PC=PC &- 2 } }

    private func ini() {
        let v = ioRead(C); memWrite(HL, v); HL=HL &+ 1; B=B &- 1; flagN=true; flagZ=(B==0)
    }
    private func ind() {
        let v = ioRead(C); memWrite(HL, v); HL=HL &- 1; B=B &- 1; flagN=true; flagZ=(B==0)
    }
    private func outi() {
        ioWrite(C, memRead(HL)); HL=HL &+ 1; B=B &- 1; flagN=true; flagZ=(B==0)
    }
    private func outd() {
        ioWrite(C, memRead(HL)); HL=HL &- 1; B=B &- 1; flagN=true; flagZ=(B==0)
    }
    private func inir() { ini(); if !flagZ { PC=PC &- 2 }; flagPV = !flagZ }
    private func indr() { ind(); if !flagZ { PC=PC &- 2 }; flagPV = !flagZ }
    private func otir() { outi(); if !flagZ { PC=PC &- 2 }; flagPV = !flagZ }
    private func otdr() { outd(); if !flagZ { PC=PC &- 2 }; flagPV = !flagZ }

    // MARK: - Control flow helpers
    @inline(__always)
    private func jr(_ cond: Bool) -> Int {
        let e = Int8(bitPattern: fetchByte())
        if cond { PC = UInt16(bitPattern: Int16(bitPattern: PC) &+ Int16(e)); return 12 }
        return 7
    }

    @inline(__always)
    private func jpCond(_ cond: Bool) -> Int {
        let nn = fetchWord(); if cond { PC = nn }; return 10
    }

    @inline(__always)
    private func retCond(_ cond: Bool) -> Int {
        if cond { PC = pop(); return 11 }; return 5
    }

    @inline(__always)
    private func callCond(_ cond: Bool) -> Int {
        let nn = fetchWord()
        if cond { push(PC); PC = nn; return 17 }
        return 10
    }

    @inline(__always)
    private func setFlags_IO(_ v: UInt8) {
        flagS=(v & 0x80) != 0; flagZ=(v==0); flagH=false; flagN=false; flagPV=parity(v)
    }

    @inline(__always)
    private func parity(_ v: UInt8) -> Bool {
        var x = v; x ^= x>>4; x ^= x>>2; x ^= x>>1; return (x & 1) == 0
    }
}
