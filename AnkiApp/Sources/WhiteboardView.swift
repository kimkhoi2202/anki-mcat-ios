import SwiftUI
import UIKit
import PencilKit

/// Drives the reviewer's whiteboard: the current pen color / stroke width, the
/// pen-vs-eraser tool, and undo/clear of the shared `PKCanvasView`.
///
/// Cloning AnkiDroid's reviewer whiteboard, the toolbar is deliberately minimal
/// (pen, eraser, a few colors, stroke width, undo, clear) and drives PencilKit
/// directly rather than showing the full `PKToolPicker`. Undo snapshots the
/// drawing at the start of each stroke, so "undo" removes exactly the last stroke
/// (or erase) and "clear" wipes the canvas — both without relying on PencilKit's
/// own undo manager. Kept on the main thread (SwiftUI + UIKit callbacks only).
final class WhiteboardController: ObservableObject {
    /// Pen colors offered in the toolbar. A small set of vivid tones chosen to
    /// read on both light and dark cards (AnkiDroid's whiteboard is likewise a
    /// few colors, not a full picker).
    static let palette: [Color] = [
        Color(red: 0.90, green: 0.16, blue: 0.16),   // red
        Color(red: 0.98, green: 0.55, blue: 0.02),   // orange
        Color(red: 0.13, green: 0.70, blue: 0.33),   // green
        Color(red: 0.11, green: 0.51, blue: 0.95),   // blue
    ]
    /// Stroke widths (points) with their toolbar labels.
    static let widths: [CGFloat] = [3, 6, 12]
    static let widthNames = ["Thin", "Medium", "Thick"]

    /// Index of the selected pen color in `palette`.
    @Published var colorIndex = 0
    /// Index of the selected stroke width in `widths`.
    @Published var widthIndex = 1
    /// Whether the eraser (rather than the pen) is selected.
    @Published var isEraser = false
    /// Whether there's a stroke to undo (drives the toolbar Undo button).
    @Published private(set) var canUndo = false

    /// The live canvas, set by the representable so undo/clear/reset act on it.
    private weak var canvas: PKCanvasView?
    /// Drawing snapshots captured at the start of each stroke (and before a
    /// clear), most-recent last; `undo` restores the top of the stack.
    private var undoStack: [PKDrawing] = []
    /// Cap so a long session's undo history can't grow without bound.
    private let maxUndo = 40

    /// The selected pen color.
    var color: Color { Self.palette[colorIndex] }
    /// The selected stroke width.
    var width: CGFloat { Self.widths[widthIndex] }

    /// The PencilKit tool for the current pen/eraser + color + width selection.
    var tool: PKTool {
        if isEraser { return PKEraserTool(.bitmap) }
        return PKInkingTool(.pen, color: UIColor(color), width: width)
    }

    func usePen() { isEraser = false }
    func useEraser() { isEraser = true }
    func selectColor(_ index: Int) {
        colorIndex = index
        // Picking a color implies drawing, not erasing.
        isEraser = false
    }
    func selectWidth(_ index: Int) { widthIndex = index }

    /// Binds the live canvas (called by the representable). Weak, so the canvas
    /// isn't retained past its view.
    func attach(_ canvas: PKCanvasView) { self.canvas = canvas }

    /// Snapshots the canvas before a new stroke/erase begins, so it can be undone.
    func snapshotBeforeStroke() {
        guard let canvas else { return }
        undoStack.append(canvas.drawing)
        if undoStack.count > maxUndo { undoStack.removeFirst() }
        if !canUndo { canUndo = true }
    }

    /// Undoes the last stroke/erase (or clear) by restoring the previous snapshot.
    func undo() {
        guard let canvas, let previous = undoStack.popLast() else { return }
        canvas.drawing = previous
        canUndo = !undoStack.isEmpty
    }

    /// Erases everything on the canvas (undoable — the pre-clear drawing is kept).
    func clear() {
        guard let canvas, !canvas.drawing.strokes.isEmpty else { return }
        undoStack.append(canvas.drawing)
        if undoStack.count > maxUndo { undoStack.removeFirst() }
        canvas.drawing = PKDrawing()
        canUndo = true
    }

    /// Starts a fresh canvas for a new card (default: strokes don't carry over).
    func resetForNewCard() {
        canvas?.drawing = PKDrawing()
        undoStack.removeAll()
        if canUndo { canUndo = false }
    }

    #if DEBUG
    /// Seeds a small sample drawing (check mark + underline) for the
    /// `-demoWhiteboard` screenshot hook, so a captured reviewer shows the
    /// whiteboard actually rendering ink over the card. DEBUG-only.
    func seedDemoStrokes() {
        guard let canvas else { return }
        let ink = PKInk(.pen, color: UIColor(color))
        func stroke(_ polyline: [CGPoint]) -> PKStroke {
            var points: [PKStrokePoint] = []
            var offset: TimeInterval = 0
            for i in 0..<(polyline.count - 1) {
                let a = polyline[i], b = polyline[i + 1]
                let steps = 14
                for s in 0...steps {
                    let t = CGFloat(s) / CGFloat(steps)
                    let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
                    points.append(PKStrokePoint(
                        location: p, timeOffset: offset,
                        size: CGSize(width: width, height: width),
                        opacity: 1, force: 1, azimuth: 0, altitude: 0
                    ))
                    offset += 0.01
                }
            }
            return PKStroke(ink: ink, path: PKStrokePath(controlPoints: points, creationDate: Date()))
        }
        var drawing = PKDrawing()
        drawing.strokes = [
            stroke([CGPoint(x: 70, y: 250), CGPoint(x: 120, y: 300), CGPoint(x: 235, y: 165)]),
            stroke([CGPoint(x: 60, y: 355), CGPoint(x: 300, y: 355)]),
        ]
        canvas.drawing = drawing
    }
    #endif
}

/// Hosts a `PKCanvasView` for the reviewer whiteboard, transparent so the card
/// shows through. Accepts finger and Pencil input (`.anyInput`), with its own
/// scrolling/zoom disabled so the canvas is a fixed drawing surface over the
/// card. Only mounted while the whiteboard is on, so when it's off the card's
/// own gestures/scrolling are completely undisturbed.
struct WhiteboardCanvas: UIViewRepresentable {
    @ObservedObject var controller: WhiteboardController

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.drawingPolicy = .anyInput
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false
        canvas.minimumZoomScale = 1
        canvas.maximumZoomScale = 1
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.tool = controller.tool
        canvas.delegate = context.coordinator
        controller.attach(canvas)
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        // Keep the controller's canvas reference and the active tool current when
        // the pen/eraser/color/width selection changes.
        controller.attach(canvas)
        canvas.tool = controller.tool
    }

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    /// Bridges PencilKit's drawing callbacks to the controller. Kept free of
    /// actor isolation (like the reviewer's `CardGestureDelegate`) so it satisfies
    /// the delegate protocol; PencilKit invokes it on the main thread.
    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let controller: WhiteboardController
        init(controller: WhiteboardController) { self.controller = controller }

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            controller.snapshotBeforeStroke()
        }
    }
}

/// The reviewer whiteboard's compact toolbar: pen/eraser, a few color swatches, a
/// stroke-width menu, undo, and clear. Mirrors AnkiDroid's minimal whiteboard
/// controls. Sized to its content and centered; the whiteboard is hidden from the
/// reviewer's on-screen toggle (and the `toggleWhiteboard` gesture), so the bar
/// itself needs no close button. Control sizes are fixed (independent of Dynamic
/// Type), so the row width is constant and fits comfortably across devices.
struct WhiteboardToolbar: View {
    @ObservedObject var controller: WhiteboardController

    private let control: CGFloat = 34
    private let swatch: CGFloat = 26

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            iconButton("pencil.tip", label: "Pen", active: !controller.isEraser) {
                controller.usePen()
            }
            iconButton("eraser", label: "Eraser", active: controller.isEraser) {
                controller.useEraser()
            }
            separator
            ForEach(Array(WhiteboardController.palette.enumerated()), id: \.offset) { index, color in
                colorSwatch(index: index, color: color)
            }
            separator
            widthMenu
            separator
            iconButton("arrow.uturn.backward", label: "Undo whiteboard", active: false) {
                controller.undo()
            }
            .disabled(!controller.canUndo)
            .opacity(controller.canUndo ? 1 : 0.4)
            iconButton("trash", label: "Clear whiteboard", active: false) {
                controller.clear()
            }
        }
        .padding(.horizontal, DS.Spacing.m)
        .padding(.vertical, DS.Spacing.xs)
        .background(
            Capsule(style: .continuous)
                .fill(DS.surface)
                .overlay(Capsule(style: .continuous).strokeBorder(DS.separator, lineWidth: 1))
                .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        )
    }

    /// A compact toolbar icon button; `active` gives it an accent-tinted pill so
    /// the selected tool (pen or eraser) reads as chosen.
    private func iconButton(
        _ systemImage: String,
        label: String,
        active: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(active ? Color.white : DS.textPrimary)
                .frame(width: control, height: control)
                .background(Circle().fill(active ? DS.accent : Color.clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }

    /// A pen-color swatch; the active pen color (when not erasing) gets a ring.
    private func colorSwatch(index: Int, color: Color) -> some View {
        let selected = controller.colorIndex == index && !controller.isEraser
        return Button {
            controller.selectColor(index)
        } label: {
            Circle()
                .fill(color)
                .frame(width: swatch - 4, height: swatch - 4)
                .overlay(Circle().strokeBorder(DS.separator, lineWidth: 1))
                .overlay(
                    Circle()
                        .strokeBorder(DS.accent, lineWidth: selected ? 3 : 0)
                        .padding(-3)
                )
                .frame(width: control, height: control)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Pen color \(index + 1)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// The stroke-width picker (a menu of the width presets, current one checked).
    private var widthMenu: some View {
        Menu {
            ForEach(Array(WhiteboardController.widths.enumerated()), id: \.offset) { index, _ in
                Button {
                    controller.selectWidth(index)
                } label: {
                    if controller.widthIndex == index {
                        Label(WhiteboardController.widthNames[index], systemImage: "checkmark")
                    } else {
                        Text(WhiteboardController.widthNames[index])
                    }
                }
            }
        } label: {
            Image(systemName: "lineweight")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(DS.textPrimary)
                .frame(width: control, height: control)
                .contentShape(Circle())
        }
        .accessibilityLabel("Stroke width")
    }

    private var separator: some View {
        Rectangle()
            .fill(DS.separator)
            .frame(width: 1, height: 22)
    }
}
