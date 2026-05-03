import AppKit
import SwiftUI

/// SwiftUI menu-bar icon. Static SF Symbol, tinted red while recording or
/// in flash colors briefly after auto-paste. NO Canvas, NO per-frame
/// redraw — the always-visible menu-bar icon must NOT do live drawing
/// work (an earlier version with Canvas at 10 Hz pinned the main thread
/// and broke ⌥V / Stop / Quit). The richer fluid waveform still lives in
/// the panel and the recording pill, both bounded surfaces.
public struct MenuBarBarsView: View {
    let history: [Float]
    let isRecording: Bool
    let pasteFlash: PasteFlash?

    public init(history: [Float], isRecording: Bool, pasteFlash: PasteFlash? = nil) {
        // history is accepted for API compatibility but intentionally unused —
        // see type doc comment.
        _ = history
        self.history = []
        self.isRecording = isRecording
        self.pasteFlash = pasteFlash
    }

    public var body: some View {
        Image(systemName: "waveform")
            .foregroundStyle(tint)
    }

    private var tint: Color {
        if let pasteFlash {
            switch pasteFlash {
            case .success: return .green
            case .skipped: return .yellow
            case .failure: return HarcBrand.live
            }
        }
        return isRecording ? HarcBrand.live : .primary
    }
}

/// Renders a 5-bar spectrum tile as an `NSImage` suitable for an
/// `NSStatusItem`. Drawn as a template image so macOS's menu bar tints it
/// correctly in light, dark, and Reduce Transparency modes.
///
/// Bar heights are driven directly by the normalized FFT bins coming from
/// `SpectrumAnalyzer` via `AutoStopController.fftBins` — no independent
/// animation. When all bins are near zero the bars flatten, which is the
/// point: that flatline is what triggers auto-stop.
public enum MenuBarBarsIcon {

    /// Width of each bar in points. Keeping bars narrow lets the 14 pt
    /// template fit cleanly inside the menu bar's visual weight budget.
    public static let barWidth: CGFloat = 2
    public static let barSpacing: CGFloat = 1.4
    public static let barCount: Int = 5

    /// Render a template image sized for the menu bar. Uses an explicit
    /// `NSBitmapImageRep` (vs `lockFocus` or the lazy drawingHandler variant)
    /// because those can silently produce an empty representation when called
    /// without an active graphics context — the symptom is the status item
    /// going invisible the moment a dynamic icon is assigned.
    ///
    /// - Parameter bins: 5 normalized magnitudes in `[0, 1]`; missing values
    ///   are treated as 0. Extra values beyond 5 are ignored.
    /// - Returns: a template `NSImage`, or a safe SF-Symbol fallback if
    ///   bitmap allocation fails (so the status item can never go missing).
    public static func image(for bins: [Float]) -> NSImage {
        let widthPts = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing + 4
        let heightPts: CGFloat = 14
        let scale: CGFloat = 2

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(widthPts * scale),
            pixelsHigh: Int(heightPts * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            // Rep creation can't really fail on supported macOS — but if it
            // somehow does, returning the SF Symbol keeps the status item
            // clickable.
            let fallback = NSImage(systemSymbolName: "waveform",
                                   accessibilityDescription: "Harc") ?? NSImage()
            fallback.isTemplate = true
            return fallback
        }
        rep.size = NSSize(width: widthPts, height: heightPts)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        let totalW = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing
        let startX = (widthPts - totalW) / 2
        let minHeight: CGFloat = 2
        let maxHeight = heightPts - 2

        NSColor.black.setFill()
        for i in 0..<barCount {
            let raw = i < bins.count ? CGFloat(bins[i]) : 0
            let clamped = max(0, min(1, raw))
            let h = max(minHeight, clamped * maxHeight)
            let x = startX + CGFloat(i) * (barWidth + barSpacing)
            let y = (heightPts - h) / 2
            let r = CGRect(x: x, y: y, width: barWidth, height: h)
            NSBezierPath(roundedRect: r, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }

        let image = NSImage(size: NSSize(width: widthPts, height: heightPts))
        image.addRepresentation(rep)
        image.isTemplate = true
        return image
    }
}
