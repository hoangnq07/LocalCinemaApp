import Foundation
import XCTest
@testable import LocalCinema

final class EnhancementPolicyTests: XCTestCase {
    func testNominalStatePreservesAllRequestedEnhancements() {
        let decision = EnhancementPolicy.resolve(
            upscaler: .aiCinemaDetail,
            hdrMode: .autoEDR,
            sdrToHDR: .cinema,
            interpolation: .cinema,
            interpolationFPS: .fps120,
            sourceIsHDR: false,
            edrAvailable: true,
            thermalState: .nominal
        )

        XCTAssertEqual(decision.effectiveUpscaler, .aiCinemaDetail)
        XCTAssertEqual(decision.effectiveSDRToHDR, .cinema)
        XCTAssertEqual(decision.effectiveInterpolation, .cinema)
        XCTAssertEqual(decision.effectiveInterpolationFPS, .fps120)
        XCTAssertFalse(decision.nativeHDRActive)
        XCTAssertFalse(decision.sdrToHDRBypassedForNativeHDR)
        XCTAssertFalse(decision.thermalThrottled)
        XCTAssertNil(decision.thermalNotice)
    }

    func testSeriousThermalStateDowngradesAIAndDisablesInterpolation() {
        let decision = EnhancementPolicy.resolve(
            upscaler: .aiFSRCNNX,
            hdrMode: .autoEDR,
            sdrToHDR: .natural,
            interpolation: .smooth,
            interpolationFPS: .auto,
            sourceIsHDR: false,
            edrAvailable: true,
            thermalState: .serious
        )

        XCTAssertEqual(decision.effectiveUpscaler, .lanczos)
        XCTAssertEqual(decision.effectiveSDRToHDR, .natural)
        XCTAssertEqual(decision.effectiveInterpolation, .off)
        XCTAssertTrue(decision.thermalThrottled)
        XCTAssertNotNil(decision.thermalNotice)
    }

    func testCriticalThermalStateDropsToStandardAndDisablesSDRToHDR() {
        let decision = EnhancementPolicy.resolve(
            upscaler: .aiCinemaDetail,
            hdrMode: .autoEDR,
            sdrToHDR: .vivid,
            interpolation: .sport,
            interpolationFPS: .fps120,
            sourceIsHDR: false,
            edrAvailable: true,
            thermalState: .critical
        )

        XCTAssertEqual(decision.effectiveUpscaler, .standard)
        XCTAssertEqual(decision.effectiveSDRToHDR, .off)
        XCTAssertEqual(decision.effectiveInterpolation, .off)
        XCTAssertTrue(decision.thermalThrottled)
        XCTAssertNotNil(decision.thermalNotice)
    }

    func testNativeHDRSourceBypassesSDRToHDRAndEnablesNativeEDR() {
        let decision = EnhancementPolicy.resolve(
            upscaler: .aiFSRCNNX,
            hdrMode: .autoEDR,
            sdrToHDR: .cinema,
            interpolation: .off,
            interpolationFPS: .auto,
            sourceIsHDR: true,
            edrAvailable: true,
            thermalState: .nominal
        )

        XCTAssertEqual(decision.effectiveUpscaler, .aiFSRCNNX)
        XCTAssertEqual(decision.effectiveSDRToHDR, .off)
        XCTAssertTrue(decision.nativeHDRActive)
        XCTAssertTrue(decision.sdrToHDRBypassedForNativeHDR)
        XCTAssertFalse(decision.thermalThrottled)
    }

    func testHDRSourceDetectionHandlesSDRAndHDRMetadata() {
        XCTAssertFalse(EnhancementPolicy.isHDRSource(sigPeak: 1.0, primaries: "bt.709", gamma: "bt.1886"))
        XCTAssertTrue(EnhancementPolicy.isHDRSource(sigPeak: 1.0, primaries: "bt.2020", gamma: "bt.1886"))
        XCTAssertTrue(EnhancementPolicy.isHDRSource(sigPeak: 1.0, primaries: "bt.709", gamma: "pq"))
        XCTAssertTrue(EnhancementPolicy.isHDRSource(sigPeak: 1.0, primaries: "bt.709", gamma: "hlg"))
        XCTAssertTrue(EnhancementPolicy.isHDRSource(sigPeak: 4.0, primaries: "bt.709", gamma: "bt.1886"))
    }
}
