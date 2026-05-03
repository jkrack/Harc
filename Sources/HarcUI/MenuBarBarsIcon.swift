import AppKit
import SwiftUI

/// SwiftUI rendition of the legacy 5-bar spectrum tile, sized for the
/// macOS menu-bar icon. Driven by `amplitudeHistory` (the 96-sample time
/// series from `AutoStopController` forwarded through `HarcAppBridge`).
///
/// **Performance note:** rendering uses a plain `Canvas` and re-renders
/// only when the parent re-renders (i.e., when `amplitudeHistory`
/// `@Published`s a new value at ~10 Hz). NO `TimelineView` — an earlier
/// implementation tried it at 24 Hz and saturated the main-thread render
/// chain to the point where the Stop button stopped registering. Idle
/// (`isRecording == false`) collapses to a static SF Symbol so the icon
/// has zero per-frame cost when no recording is happening.
public struct MenuBarBarsView: View {
    let history: [Float]
    let isRecording: Bool

    public init(history: [Float], isRecording: Bool) {
        self.history = history
        self.isRecording = isRecording
    }

    public var body: some View {
        if isRecording {
            bars
        } else {
            Image(systemName: "waveform")
                .foregroundStyle(.primary)
        }
    }

    private var bars: some View {
        Canvas { ctx, size in
            let samples = lastFive
            let barWidth: CGFloat = 2
            let spacing: CGFloat = 1.4
            let totalW = CGFloat(samples.count) * barWidth + CGFloat(samples.count - 1) * spacing
            let startX = (size.width - totalW) / 2
            let h = size.height
            let minH: CGFloat = 2
            let maxH = h - 2
            for i in 0..<samples.count {
                let clamped = max(0, min(1, CGFloat(samples[i])))
                let bh = max(minH, clamped * maxH)
                let x = startX + CGFloat(i) * (barWidth + spacing)
                let y = (h - bh) / 2
                let rect = CGRect(x: x, y: y, width: barWidth, height: bh)
                ctx.fill(
                    Path(roundedRect: rect, cornerRadius: barWidth / 2),
                    with: .color(HarcBrand.live)
                )
            }
        }
        .frame(width: 16, height: 14)
    }

    /// The 5 most-recent amplitude samples (left = older, right = newer).
    /// Pads with leading zeros if history is shorter than 5.
    private var lastFive: [Float] {
        let n = 5
        if history.count >= n { return Array(history.suffix(n)) }
        return Array(repeating: 0, count: n - history.count) + history
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
