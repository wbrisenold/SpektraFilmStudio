import Foundation
import Metal
import simd

// MARK: - Sigmoid derivation (ported from Lightamer/LightamerIOP/Sources/Sigmoid/SigmoidDerivation.swift)
// Darktable reference: src/iop/sigmoid.c — log-logistic tone mapping
// This is the CPU half: derives the 7 scalars the GPU kernel consumes.

enum SigmoidDerivation {

    /// dt `MIDDLE_GREY` (sigmoid.c:37) — 18.45% scene grey.
    public static let middleGrey: Double = 0.1845

    /// The derivation delta (sigmoid.c:339).
    public static let delta: Double = 1e-6

    /// The kernel-facing scalars (dt `dt_iop_sigmoid_data_t` numeric half).
    public struct Scalars: Equatable, Sendable {
        public var whiteTarget: Float
        public var blackTarget: Float
        public var paperExposure: Float
        public var filmFog: Float
        public var filmPower: Float
        public var paperPower: Float
        public var huePreservation: Float
    }

    /// dt `_generalized_loglogistic_sigmoid` (sigmoid.c:300-316).
    public static func generalizedLoglogisticSigmoid(
        value: Double,
        magnitude: Double,
        paperExposure: Double,
        filmFog: Double,
        filmPower: Double,
        paperPower: Double
    ) -> Double {
        let clampedValue = max(value, 0.0)
        let filmResponse = pow(filmFog + clampedValue, filmPower)
        let paperResponse = magnitude * pow(filmResponse / (paperExposure + filmResponse), paperPower)
        return paperResponse.isNaN ? magnitude : paperResponse
    }

    /// dt `commit_params` (sigmoid.c:318-392) verbatim in Double.
    public static func derive(
        middleGreyContrast: Double,
        contrastSkewness: Double,
        displayWhiteTarget: Double,
        displayBlackTarget: Double,
        huePreservationPercent: Double
    ) -> Scalars {
        let refFilmPower = middleGreyContrast
        let refPaperPower = 1.0
        let refMagnitude = 1.0
        let refFilmFog = 0.0
        let refPaperExposure = pow(refFilmFog + middleGrey, refFilmPower) * ((refMagnitude / middleGrey) - 1.0)

        let paperPower = pow(5.0, -contrastSkewness)

        let tempFilmPower = 1.0
        let tempWhiteTarget = 0.01 * displayWhiteTarget
        let tempWhiteGreyRelation = pow(tempWhiteTarget / middleGrey, 1.0 / paperPower) - 1.0
        let tempPaperExposure = pow(middleGrey, tempFilmPower) * tempWhiteGreyRelation

        let tempSlope = slopeAtGrey(
            magnitude: tempWhiteTarget, paperExposure: tempPaperExposure,
            filmFog: refFilmFog, filmPower: tempFilmPower, paperPower: paperPower)

        let refSlope = slopeAtGrey(
            magnitude: refMagnitude, paperExposure: refPaperExposure,
            filmFog: refFilmFog, filmPower: refFilmPower, paperPower: refPaperPower)

        let filmPower = refSlope / tempSlope

        let whiteTarget = 0.01 * displayWhiteTarget
        let blackTarget = 0.01 * displayBlackTarget
        let whiteGreyRelation = pow(whiteTarget / middleGrey, 1.0 / paperPower) - 1.0
        let whiteBlackRelation = pow(blackTarget / whiteTarget, -1.0 / paperPower) - 1.0

        let filmFog = middleGrey * pow(whiteGreyRelation, 1.0 / filmPower)
            / (pow(whiteBlackRelation, 1.0 / filmPower) - pow(whiteGreyRelation, 1.0 / filmPower))
        let paperExposure = pow(filmFog + middleGrey, filmPower) * whiteGreyRelation

        let huePreservation = min(max(0.01 * huePreservationPercent, 0.0), 1.0)

        return Scalars(
            whiteTarget: Float(whiteTarget),
            blackTarget: Float(blackTarget),
            paperExposure: Float(paperExposure),
            filmFog: Float(filmFog),
            filmPower: Float(filmPower),
            paperPower: Float(paperPower),
            huePreservation: Float(huePreservation)
        )
    }

    static func slopeAtGrey(
        magnitude: Double, paperExposure: Double, filmFog: Double,
        filmPower: Double, paperPower: Double
    ) -> Double {
        let high = generalizedLoglogisticSigmoid(
            value: middleGrey + delta, magnitude: magnitude, paperExposure: paperExposure,
            filmFog: filmFog, filmPower: filmPower, paperPower: paperPower)
        let low = generalizedLoglogisticSigmoid(
            value: middleGrey - delta, magnitude: magnitude, paperExposure: paperExposure,
            filmFog: filmFog, filmPower: filmPower, paperPower: paperPower)
        return (high - low) / 2.0 / delta
    }
}
