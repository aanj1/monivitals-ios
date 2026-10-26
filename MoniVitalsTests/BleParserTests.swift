//
//  BleParserTests.swift
//  MoniVitalsTests
//
//  Synthetic-byte coverage for the MoniVitals device BLE decoders. Everything here
//  builds plain `[UInt8]` buffers (no CoreBluetooth, no radio) so the parsing math
//  is fully deterministic and runs in the Simulator, which has no BLE radio:
//    • Heart Rate Measurement 0x2A37 (uint8 / uint16 HR, contact flags, finger-off),
//    • PLX Continuous 0x2A5F SpO₂ via IEEE-11073 SFLOAT decode,
//    • the raw int16 PPG little-endian sample array,
//    • the custom Quality [perfusion, contact] bytes,
//    • the SFLOAT primitive itself (incl. reserved specials).
//

import XCTest
@testable import MoniVitals

final class BleParserTests: XCTestCase {

    // MARK: - Heart Rate 0x2A37

    func testHeartRateUInt8() {
        // flags 0x00 = uint8 HR, no contact info. HR = 72.
        let hr = BleParsers.heartRate([0x00, 72])
        XCTAssertEqual(hr.bpm ?? 0, 72, accuracy: 0.0001)
        XCTAssertNil(hr.contact) // contact not supported → nil
    }

    func testHeartRateUInt16() {
        // flags 0x01 = uint16 HR. HR = 0x012C = 300... use a plausible 200 = 0x00C8.
        let hr = BleParsers.heartRate([0x01, 0xC8, 0x00])
        XCTAssertEqual(hr.bpm ?? 0, 200, accuracy: 0.0001)
    }

    func testHeartRateUInt16HighByte() {
        // HR = 258 = 0x0102 → lo 0x02, hi 0x01.
        let hr = BleParsers.heartRate([0x01, 0x02, 0x01])
        XCTAssertEqual(hr.bpm ?? 0, 258, accuracy: 0.0001)
    }

    func testHeartRateContactDetected() {
        // flags 0x06 = contact detected (bit1 0x02) + contact supported (bit2 0x04),
        // uint8 HR. Spec 0x2A37: bit1 = status/detected, bit2 = support.
        let hr = BleParsers.heartRate([0x06, 66])
        XCTAssertEqual(hr.bpm ?? 0, 66, accuracy: 0.0001)
        XCTAssertEqual(hr.contact, true)
    }

    func testHeartRateContactSupportedButClear() {
        // flags 0x05 = uint16 HR (bit0 0x01) + contact supported (bit2 0x04), with
        // the detected bit (0x02) clear — this is exactly the firmware's finger-off
        // frame (buf[0] = 0x05, no 0x02). Supported-but-not-detected → contact false.
        let hr = BleParsers.heartRate([0x05, 0x00, 0x00])
        XCTAssertEqual(hr.contact, false)
        // bpm 0 → finger removed → no HR.
        XCTAssertNil(hr.bpm)
    }

    func testHeartRateContactUnsupportedIsNil() {
        // No support bit (0x04) set → contact status is unknown (nil), even if the
        // detected bit happens to be set. flags 0x02 alone must NOT report contact.
        let hr = BleParsers.heartRate([0x02, 66])
        XCTAssertEqual(hr.bpm ?? 0, 66, accuracy: 0.0001)
        XCTAssertNil(hr.contact)
    }

    func testHeartRateFingerRemovedZeroBpm() {
        let hr = BleParsers.heartRate([0x00, 0])
        XCTAssertNil(hr.bpm)
    }

    func testHeartRateTooShort() {
        XCTAssertNil(BleParsers.heartRate([0x00]).bpm)
        XCTAssertNil(BleParsers.heartRate([]).bpm)
        // Declares uint16 but only 2 bytes → not enough data.
        XCTAssertNil(BleParsers.heartRate([0x01, 0x50]).bpm)
    }

    // MARK: - SpO₂ 0x2A5F (SFLOAT)

    func testSpo2Decode98() {
        // SpO₂ 98.0 %: SFLOAT mantissa 980, exponent -1 → 980 * 10^-1 = 98.0.
        // exponent -1 = 0xF in the top nibble; mantissa 980 = 0x3D4.
        let raw: UInt16 = (0xF << 12) | 0x3D4
        let bytes: [UInt8] = [0x00, UInt8(raw & 0xFF), UInt8(raw >> 8), 0x00, 0x00]
        let spo2 = BleParsers.spo2Percent(bytes)
        XCTAssertNotNil(spo2)
        XCTAssertEqual(spo2 ?? 0, 98.0, accuracy: 0.01)
    }

    func testSpo2Decode955() {
        // 95.5 %: mantissa 955, exponent -1.
        let raw: UInt16 = (0xF << 12) | 955
        let bytes: [UInt8] = [0x00, UInt8(raw & 0xFF), UInt8(raw >> 8)]
        XCTAssertEqual(BleParsers.spo2Percent(bytes) ?? 0, 95.5, accuracy: 0.01)
    }

    func testSpo2Clamps100() {
        // 101 % (out of clamp high but within plausibility band) → clamps to 100.
        let raw: UInt16 = (0xF << 12) | 1010
        let bytes: [UInt8] = [0x00, UInt8(raw & 0xFF), UInt8(raw >> 8)]
        XCTAssertEqual(BleParsers.spo2Percent(bytes) ?? 0, 100.0, accuracy: 0.0001)
    }

    func testSpo2ZeroNotReported() {
        // Mantissa 0 → value 0 → nil (device says "not measured").
        let raw: UInt16 = (0xF << 12) | 0
        let bytes: [UInt8] = [0x00, UInt8(raw & 0xFF), UInt8(raw >> 8)]
        XCTAssertNil(BleParsers.spo2Percent(bytes))
    }

    func testSpo2ImplausibleRejected() {
        // 30 % is below the plausibility floor → nil.
        let raw: UInt16 = (0xF << 12) | 300
        let bytes: [UInt8] = [0x00, UInt8(raw & 0xFF), UInt8(raw >> 8)]
        XCTAssertNil(BleParsers.spo2Percent(bytes))
    }

    func testSpo2TooShort() {
        XCTAssertNil(BleParsers.spo2Percent([0x00, 0x10]))
        XCTAssertNil(BleParsers.spo2Percent([]))
    }

    // MARK: - PPG 0x42540006 (int16 LE array)

    func testPpgSamplesLittleEndian() {
        // Two samples: 0x0100 = 256, 0xFFFF = -1 (two's complement).
        let bytes: [UInt8] = [0x00, 0x01, 0xFF, 0xFF]
        XCTAssertEqual(BleParsers.ppgSamples(bytes), [256, -1])
    }

    func testPpgSamplesNegativeAndPositive() {
        // 0x8000 = -32768 (min), 0x7FFF = 32767 (max).
        let bytes: [UInt8] = [0x00, 0x80, 0xFF, 0x7F]
        XCTAssertEqual(BleParsers.ppgSamples(bytes), [-32768, 32767])
    }

    func testPpgSamplesTrailingOddByteIgnored() {
        // Odd trailing byte must be dropped, not crash.
        let bytes: [UInt8] = [0x10, 0x00, 0x99]
        XCTAssertEqual(BleParsers.ppgSamples(bytes), [16])
    }

    func testPpgSamplesEmpty() {
        XCTAssertEqual(BleParsers.ppgSamples([]), [])
    }

    func testPpgSamplesLargeNotify() {
        // 50 samples of value i → verify count + a couple of positions.
        var bytes: [UInt8] = []
        for i in 0..<50 {
            let v = Int16(i)
            bytes.append(UInt8(v & 0xFF))
            bytes.append(UInt8((v >> 8) & 0xFF))
        }
        let out = BleParsers.ppgSamples(bytes)
        XCTAssertEqual(out.count, 50)
        XCTAssertEqual(out.first, 0)
        XCTAssertEqual(out.last, 49)
    }

    // MARK: - Quality 0x42540002

    func testQualityContactTrue() {
        // perfusion 25 (×0.1 → 2.5 %), contact 1.
        let q = BleParsers.quality([25, 1])
        XCTAssertEqual(q.perfusionPct, 2.5, accuracy: 0.0001)
        XCTAssertTrue(q.contact)
    }

    func testQualityContactFalse() {
        let q = BleParsers.quality([0, 0])
        XCTAssertEqual(q.perfusionPct, 0, accuracy: 0.0001)
        XCTAssertFalse(q.contact)
    }

    func testQualityTooShort() {
        let q = BleParsers.quality([5])
        XCTAssertFalse(q.contact)
        XCTAssertEqual(q.perfusionPct, 0, accuracy: 0.0001)
    }

    // MARK: - SFLOAT primitive

    func testSfloatPositiveExponent() {
        // mantissa 5, exponent +2 → 5 * 10^2 = 500.
        let raw: UInt16 = (0x2 << 12) | 5
        XCTAssertEqual(BleParsers.sfloat(raw) ?? 0, 500, accuracy: 0.0001)
    }

    func testSfloatNegativeMantissa() {
        // mantissa -1 (0xFFF sign-extended), exponent 0 → -1.
        let raw: UInt16 = (0x0 << 12) | 0x0FFF
        XCTAssertEqual(BleParsers.sfloat(raw) ?? 0, -1, accuracy: 0.0001)
    }

    func testSfloatReservedSpecialsAreNil() {
        XCTAssertNil(BleParsers.sfloat(0x07FF)) // NaN
        XCTAssertNil(BleParsers.sfloat(0x0800)) // NRes
        XCTAssertNil(BleParsers.sfloat(0x07FE)) // +INF
        XCTAssertNil(BleParsers.sfloat(0x0802)) // -INF
    }

    // MARK: - Command payload

    func testStreamCommandOnOff() {
        XCTAssertEqual([UInt8](MoniVitalsBLE.streamCommand(on: true)), [0x02, 0x01])
        XCTAssertEqual([UInt8](MoniVitalsBLE.streamCommand(on: false)), [0x02, 0x00])
    }
}
