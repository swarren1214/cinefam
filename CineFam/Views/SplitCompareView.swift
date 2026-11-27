import AVFoundation
import Combine
import SwiftUI

/// Before/after viewer: the original fills the frame and the restored picture is revealed to the
/// right of a line you drag (click anywhere to jump the line there).
///
/// The two sides can be two players kept in step, or one player whose video already holds both
/// pictures side by side (the restoration preview), with each side's rect choosing which part shows.
struct SplitCompareView: View {
    let original: AVPlayer
    let restored: AVPlayer
    /// Width ÷ height of the restored picture; the view keeps this shape.
    var aspect: CGFloat
    var leftLabel = "Original"
    var rightLabel = "Restored"
    var originalRect: @Sendable (CGSize) -> CGRect = SplitCompareView.full
    var restoredRect: @Sendable (CGSize) -> CGRect = SplitCompareView.full
    var showsPlayButton = true

    @State private var playing = false

    var body: some View {
        ComparePlayerView(original: original, restored: restored,
                          originalRect: originalRect, restoredRect: restoredRect)
            .aspectRatio(aspect, contentMode: .fit)
            .overlay(alignment: .bottomLeading) { tag(leftLabel) }
            .overlay(alignment: .bottomTrailing) { tag(rightLabel) }
            .overlay(alignment: .bottom) {
                if showsPlayButton {
                    Button {
                        if original.rate == 0 { original.play() } else { original.pause() }
                    } label: {
                        Image(systemName: playing ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .frame(width: 44, height: 32)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(.black.opacity(0.55), in: .capsule)
                    .padding(12)
                    .help(playing ? "Pause" : "Play")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
            .onReceive(original.publisher(for: \.rate)) { playing = $0 != 0 }
    }

    private func tag(_ text: String) -> some View {
        // Plain background, not glass: glass would sample the AppKit video layer behind it.
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.black.opacity(0.55), in: .capsule)
            .padding(12)
            .allowsHitTesting(false)
    }

    // MARK: Where each side's video sits (AppKit coordinates: origin bottom-left)

    static let full: @Sendable (CGSize) -> CGRect = { CGRect(origin: .zero, size: $0) }
    /// Left half of a double-wide side-by-side video.
    static let leftHalf: @Sendable (CGSize) -> CGRect = { CGRect(x: 0, y: 0, width: $0.width * 2, height: $0.height) }
    /// Right half of a double-wide side-by-side video.
    static let rightHalf: @Sendable (CGSize) -> CGRect = { CGRect(x: -$0.width, y: 0, width: $0.width * 2, height: $0.height) }

    /// Shows the original enlarged so it lines up with a restored picture that had its ragged
    /// edges trimmed (see `Restorer.edgeCrop`).
    static func trimmed(_ c: Restorer.EdgeCrop) -> @Sendable (CGSize) -> CGRect {
        { s in
            let w = s.width / c.width, h = s.height / c.height
            return CGRect(x: -c.left * w, y: s.height - h * (1 - c.top), width: w, height: h)
        }
    }
}

/// The AppKit side: two AVPlayerLayers, the restored one clipped to the right of the split, plus
/// the line and handle. Done in layers so clipping and dragging are exact and cheap.
struct ComparePlayerView: NSViewRepresentable {
    let original: AVPlayer
    let restored: AVPlayer
    var originalRect: @Sendable (CGSize) -> CGRect
    var restoredRect: @Sendable (CGSize) -> CGRect

    func makeNSView(context: Context) -> CompareNSView {
        let v = CompareNSView()
        update(v)
        return v
    }

    func updateNSView(_ v: CompareNSView, context: Context) { update(v) }

    private func update(_ v: CompareNSView) {
        if v.originalLayer.player !== original { v.originalLayer.player = original }
        if v.restoredLayer.player !== restored { v.restoredLayer.player = restored }
        v.originalRect = originalRect
        v.restoredRect = restoredRect
        v.needsLayout = true
    }
}

final class CompareNSView: NSView {
    let originalLayer = AVPlayerLayer()
    let restoredLayer = AVPlayerLayer()
    var originalRect: (CGSize) -> CGRect = { CGRect(origin: .zero, size: $0) }
    var restoredRect: (CGSize) -> CGRect = { CGRect(origin: .zero, size: $0) }
    private(set) var split: CGFloat = 0.5

    private let clip = CALayer()
    private let line = CALayer()
    private let knob = CALayer()
    private let arrows = CATextLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        guard let root = layer else { return }
        root.backgroundColor = NSColor.black.cgColor
        root.masksToBounds = true
        for l in [originalLayer, restoredLayer] { l.videoGravity = .resize }
        clip.masksToBounds = true
        clip.addSublayer(restoredLayer)

        line.backgroundColor = NSColor.white.cgColor
        line.shadowOpacity = 0.5
        line.shadowRadius = 3
        line.shadowOffset = .zero

        knob.backgroundColor = NSColor.white.cgColor
        knob.cornerRadius = 16
        knob.shadowOpacity = 0.4
        knob.shadowRadius = 4
        knob.shadowOffset = .zero
        arrows.string = "◀ ▶"
        arrows.fontSize = 10
        arrows.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        arrows.foregroundColor = NSColor.black.cgColor
        arrows.alignmentMode = .center
        knob.addSublayer(arrows)

        for l in [originalLayer, clip, line, knob] { root.addSublayer(l) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        arrows.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let s = bounds.size
        let x = (s.width * split).rounded()
        originalLayer.frame = originalRect(s)
        clip.frame = CGRect(x: x, y: 0, width: max(0, s.width - x), height: s.height)
        restoredLayer.frame = restoredRect(s).offsetBy(dx: -x, dy: 0)
        line.frame = CGRect(x: x - 1, y: 0, width: 2, height: s.height)
        knob.frame = CGRect(x: x - 16, y: s.height / 2 - 16, width: 32, height: 32)
        arrows.frame = CGRect(x: 0, y: 9, width: 32, height: 14)
        CATransaction.commit()
    }

    // MARK: Dragging the split

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { moveSplit(event) }
    override func mouseDragged(with event: NSEvent) { moveSplit(event) }

    private func moveSplit(_ event: NSEvent) {
        guard bounds.width > 0 else { return }
        let p = convert(event.locationInWindow, from: nil)
        split = min(max(p.x / bounds.width, 0), 1)
        needsLayout = true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }
}
