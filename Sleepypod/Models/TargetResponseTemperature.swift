import Foundation

enum TargetResponseTemperature {
    /// A temperature difference changes scale, while an absolute reading also changes origin.
    static func converted(_ value: Double, celsius: Bool, difference: Bool = false) -> Double {
        celsius ? (difference ? value : value - 32) * 5 / 9 : value
    }
    static func text(_ value: Double, celsius: Bool, difference: Bool = false) -> String {
        let number = converted(value, celsius: celsius, difference: difference).formatted(.number.precision(.fractionLength(1)))
        return "\(number)°\(celsius ? "C" : "F")"
    }
}
