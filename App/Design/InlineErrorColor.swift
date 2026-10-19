import SwiftUI
import UIKit

extension ShapeStyle where Self == Color {
    /// Inline error text under a form ("That email and password don't match.", "Taken", "Passwords
    /// don't match."). Use it instead of `.red`: system red is only about 3.3:1 on Ground, below the
    /// 4.5:1 that footnote-sized text needs.
    ///
    /// Light #C4271C is 5.4:1 on Ground and 5.8:1 on Surface; dark #FF6B60 is 7.0:1 on Ground and
    /// 6.5:1 on Surface. Increase Contrast goes further in both.
    static var inlineError: Color { InlineErrorPalette.color }
}

/// The colors behind `.inlineError`, resolved per appearance and contrast setting.
private enum InlineErrorPalette {
    static let color = Color(uiColor: UIColor { traits in
        let isDark = traits.userInterfaceStyle == .dark
        let isHighContrast = traits.accessibilityContrast == .high
        switch (isDark, isHighContrast) {
        case (false, false): return UIColor(red: 0xC4 / 255, green: 0x27 / 255, blue: 0x1C / 255, alpha: 1)
        case (false, true): return UIColor(red: 0xA3 / 255, green: 0x1D / 255, blue: 0x14 / 255, alpha: 1)
        case (true, false): return UIColor(red: 0xFF / 255, green: 0x6B / 255, blue: 0x60 / 255, alpha: 1)
        case (true, true): return UIColor(red: 0xFF / 255, green: 0x8E / 255, blue: 0x85 / 255, alpha: 1)
        }
    })
}
