import Foundation

public enum PeekHue {
    /// FNV-1a over UTF8 → stable hue 0...1.
    public static func hue(_ s: String) -> Double {
        var h: UInt32 = 2166136261
        for b in s.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return Double(h % 360) / 360
    }
}
