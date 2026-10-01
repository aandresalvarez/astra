import SwiftUI
import AppKit

// Resize handle for the canvas shelf (Plan / Browser).
//
// The hit area is a 14pt-wide invisible rectangle straddling the panel's leading edge
// (offset -7) so the cursor changes a few pixels before and after the visible boundary —
// this is what makes the divider feel "sticky." The handle draws nothing itself: the
// boundary line belongs to the panel (full height, through the titlebar), and a handle-owned
// accent only spans the area below the titlebar, so it reads as a second, mismatched border.
//
// Cursor management uses AppKit's window-level cursor rect (addCursorRect via
// CursorRectView) instead of NSCursor.push/pop on hover. push/pop is fragile during
// SwiftUI gestures because the hover state ends when the drag begins, popping the
// cursor mid-drag. A registered cursor rect keeps the resize cursor for the entire
// time the pointer is over the area, including throughout drags.
struct ShelfResizeHandle: View {
    let helpText: String
    let onChanged: (CGSize) -> Void
    let onEnded: () -> Void

    var body: some View {
        ZStack(alignment: .leading) {
            // Invisible hit target.
            //
            // coordinateSpace: .global is critical. With the default .local space, translation
            // is measured against the handle's own coord space — but the handle is anchored to
            // the canvas's leading edge, which moves as the panel resizes. That creates a
            // feedback loop: panel grows → handle moves with it → translation collapses back
            // to 0 → panel shrinks → translation reappears → panel grows… visible as a
            // side-to-side shake. Measuring translation against the screen breaks the loop.
            Rectangle()
                .fill(Color.clear)
                .frame(width: 14)
                .contentShape(Rectangle())
                .background(CursorRectView(cursor: .resizeLeftRight))
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .global)
                        .onChanged { value in onChanged(value.translation) }
                        .onEnded { _ in onEnded() }
                )
        }
        .frame(maxHeight: .infinity)
        .offset(x: -7) // straddle the boundary: 7pt outside panel, 7pt inside
        .help(helpText)
    }
}

// AppKit-backed cursor rect — survives SwiftUI drags. Unlike NSCursor.push/pop on
// SwiftUI's onHover (which ends the moment a drag begins), addCursorRect registers
// the cursor at the window level so macOS keeps showing it for as long as the
// pointer is in the rect, regardless of what gesture is active.
private struct CursorRectView: NSViewRepresentable {
    let cursor: NSCursor

    func makeNSView(context: Context) -> NSView {
        CursorRectNSView(cursor: cursor)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? CursorRectNSView else { return }
        if view.cursor !== cursor {
            view.cursor = cursor
            view.window?.invalidateCursorRects(for: view)
        }
    }
}

private final class CursorRectNSView: NSView {
    var cursor: NSCursor

    init(cursor: NSCursor) {
        self.cursor = cursor
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    // Don't intercept mouse events — the SwiftUI DragGesture above handles them.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
