//
//  EBSDMapAcquisition.swift
//  Moved from Electron Microscopy Studio's Sources/TEMSEM/Export/CrystalMapAcquisition.swift (at 7b09bf5) by FormatoKit#147.
//  Role: what the caller knows about how an orientation map was acquired and made, for the .ang and .ctf headers: the pattern centre,
//        working distance, magnification, beam energy and sample tilt where it has them, and the software that wrote the file. A
//        field the caller does not know stays nil and the writer puts the format's own "unknown" (0).
//

import Foundation

public nonisolated struct EBSDMapAcquisition: Sendable, Equatable {
    /// The pattern centre in EDAX TSL's convention (x*, y*, z*), as the .ang header states it.
    public var patternCentreTSL: SIMD3<Double>?
    public var workingDistanceMM: Double?
    public var magnification: Double?
    public var beamEnergyKeV: Double?
    public var sampleTiltDegrees: Double?
    /// The build that wrote the file ("Electron Microscopy Studio 2.1.0 (42) with FormatoKit 0.15.0, ...").
    public var software: String?

    public init(patternCentreTSL: SIMD3<Double>? = nil, workingDistanceMM: Double? = nil, magnification: Double? = nil,
                beamEnergyKeV: Double? = nil, sampleTiltDegrees: Double? = nil, software: String? = nil) {
        self.patternCentreTSL = patternCentreTSL; self.workingDistanceMM = workingDistanceMM; self.magnification = magnification
        self.beamEnergyKeV = beamEnergyKeV; self.sampleTiltDegrees = sampleTiltDegrees; self.software = software
    }

    /// From a dataset and the pattern centre a run used (Bruker convention): the header the file carries and the detector's tilt.
    public init(dataset: EBSDDataset, projectionCenterBruker pc: SIMD3<Double>?, software: String?) {
        let finite = { (v: Double?) -> Double? in v.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } }
        let tsl = pc.flatMap { p -> SIMD3<Double>? in
            let c = dataset.detector.center(p, in: .tsl)
            return c.x.isFinite && c.y.isFinite && c.z.isFinite ? c : nil
        }
        self.init(patternCentreTSL: tsl, workingDistanceMM: finite(dataset.sem.workingDistanceMM),
                  magnification: finite(dataset.sem.magnification), beamEnergyKeV: finite(dataset.sem.beamEnergyKeV),
                  sampleTiltDegrees: dataset.detector.sampleTilt.isFinite ? dataset.detector.sampleTilt : nil, software: software)
    }

    /// A number for a header: an integer without decimals, else up to 6 significant digits; 0 for none.
    public static func headerNumber(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "0" }
        if v == v.rounded(), abs(v) < 1e15 { return String(Int(v)) }
        return String(format: "%.6g", v)
    }
}
