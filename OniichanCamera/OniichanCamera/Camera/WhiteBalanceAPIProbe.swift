import AVFoundation
import Foundation

/// TEMPORARY API PROBE — will be removed after verification.
/// Each `let _: Int = ...` forces an error that reveals whether the member exists
/// ("cannot convert ... to Int") or not ("has no member ...").
enum WhiteBalanceAPIProbe {
    static func probe(
        device: AVCaptureDevice,
        chrom: AVCaptureDevice.WhiteBalanceChromaticityValues,
        tt: AVCaptureDevice.WhiteBalanceTemperatureAndTintValues,
        gains: AVCaptureDevice.WhiteBalanceGains
    ) {
        let _: Int = device.deviceWhiteBalanceGains(forChromaticityValues: chrom)          // P1
        let _: Int = device.deviceWhiteBalanceGains(forTemperatureAndTintValues: tt)       // P2
        let _: Int = device.deviceWhiteBalanceGains(for: chrom)                            // P3
        let _: Int = device.whiteBalanceGains(forChromaticityValues: chrom)                // P4
        let _: Int = device.whiteBalanceGains(forTemperatureAndTintValues: tt)             // P5
        let _: Int = device.deviceWhiteBalanceGains                                        // P6
        let _: Int = device.setWhiteBalanceModeLocked(withTemperatureAndTintValues: tt, completionHandler: nil) // P7
        let _: Int = device.temperatureAndTintValues(forDeviceWhiteBalanceGains: gains)    // P8
        let _: Int = device.chromaticityValues(forDeviceWhiteBalanceGains: gains)          // P9
    }
}
