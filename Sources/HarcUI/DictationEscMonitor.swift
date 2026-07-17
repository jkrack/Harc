import AppKit
import ApplicationServices

/// Handle for an installed Esc tap. Invalidating stops event delivery.
@MainActor
public protocol DictationEscTapHandle {
    func invalidate()
}

/// Consuming Esc-key monitor for dictation. While a dictation is listening,
/// pressing Esc cancels it — and the event is swallowed so it never reaches
/// the frontmost app (a plain global monitor can't consume, which would also
/// dismiss the user's dialogs/sheets).
///
/// Built on a `CGEventTap`, which needs the Accessibility permission the
/// insert path already requires. When AX isn't granted the monitor skips
/// silently — dictation still works, Esc just isn't intercepted.
@MainActor
public final class DictationEscMonitor {
    /// Seam so tests can substitute a fake tap. The closure receives the
    /// cancel action and returns a handle, or nil when a tap can't be made.
    public typealias TapFactory = @MainActor (@escaping @MainActor () -> Void) -> DictationEscTapHandle?

    private let isTrusted: () -> Bool
    private let makeTap: TapFactory
    private let onCancel: @MainActor () -> Void
    private var handle: DictationEscTapHandle?

    public init(
        isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
        makeTap: TapFactory? = nil,
        onCancel: @escaping @MainActor () -> Void
    ) {
        self.isTrusted = isTrusted
        self.makeTap = makeTap ?? Self.systemTap
        self.onCancel = onCancel
    }

    /// True while the tap is installed (test observability).
    public var isMonitoring: Bool { handle != nil }

    /// Install the tap when listening starts; tear it down the moment
    /// listening ends. Idempotent in both directions.
    public func setListening(_ listening: Bool) {
        if listening {
            guard handle == nil, isTrusted() else { return }
            handle = makeTap(onCancel)
        } else {
            handle?.invalidate()
            handle = nil
        }
    }

    // MARK: - Live CGEventTap

    /// Mutable tap state shared with the C callback via `userInfo`. The tap's
    /// run-loop source lives on the main run loop, so the callback and
    /// `invalidate` both execute on the main thread — the unchecked
    /// sendability is thread-confined in practice.
    private final class TapBox: @unchecked Sendable {
        var machPort: CFMachPort?
        var runLoopSource: CFRunLoopSource?
        let cancel: @MainActor () -> Void
        init(cancel: @escaping @MainActor () -> Void) { self.cancel = cancel }
    }

    private struct LiveTap: DictationEscTapHandle {
        let box: TapBox

        func invalidate() {
            if let port = box.machPort {
                CGEvent.tapEnable(tap: port, enable: false)
                CFMachPortInvalidate(port)
            }
            if let source = box.runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            box.machPort = nil
            box.runLoopSource = nil
        }
    }

    private static let escKeyCode: Int64 = 53

    private static let systemTap: TapFactory = { cancel in
        let box = TapBox(cancel: cancel)

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let box = Unmanaged<TapBox>.fromOpaque(userInfo).takeUnretainedValue()

            // macOS disables taps that stall or on user-input protection —
            // re-enable so Esc keeps working for the rest of the session.
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let port = box.machPort {
                    CGEvent.tapEnable(tap: port, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            guard type == .keyDown,
                  event.getIntegerValueField(.keyboardEventKeycode) == DictationEscMonitor.escKeyCode
            else { return Unmanaged.passUnretained(event) }

            // Consume the event; cancel on the main actor (we're already on
            // the main run loop — the async hop is defensive).
            DispatchQueue.main.async {
                MainActor.assumeIsolated { box.cancel() }
            }
            return nil
        }

        guard let port = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: callback,
            userInfo: Unmanaged.passUnretained(box).toOpaque()
        ) else { return nil }

        box.machPort = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        box.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        // `userInfo` holds the box unretained; LiveTap (held by the monitor)
        // is the owning reference for the tap's lifetime.
        return LiveTap(box: box)
    }
}
