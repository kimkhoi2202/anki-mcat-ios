import SwiftUI
import PencilKit

/// The note editor's "Draw" attachment — a PencilKit canvas for sketching /
/// handwriting that's exported to a PNG and inserted into the focused field as an
/// `<img>`, mirroring AnkiDroid's NoteEditor drawing attachment (its "Draw"
/// multimedia action → `DrawingActivity`).
///
/// Reuses the reviewer whiteboard's `WhiteboardController` / `WhiteboardCanvas` /
/// `WhiteboardToolbar` (pen / eraser / colors / width / undo / clear) so the
/// drawing surface behaves identically. The canvas sits on a white "paper"
/// background so ink is visible while drawing; the exported PNG keeps a
/// transparent background so it composites over any card. Presented as a sheet.
@MainActor
struct DrawingCanvasView: View {
    /// Called with the exported drawing (PNG bytes) on Insert, or `nil` on Cancel.
    var onFinish: (PickedMedia?) -> Void

    @StateObject private var controller = WhiteboardController()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: DS.Spacing.m) {
                ZStack {
                    RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                        .fill(Color.white)
                    WhiteboardCanvas(controller: controller)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous))
                }
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                        .strokeBorder(DS.separator, lineWidth: 1)
                )
                .padding(.horizontal, DS.Spacing.l)
                .padding(.top, DS.Spacing.l)

                WhiteboardToolbar(controller: controller)
                    .padding(.bottom, DS.Spacing.l)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DS.background.ignoresSafeArea())
            .navigationTitle("Draw")
            .navigationBarTitleDisplayMode(.inline)
            .tint(DS.accent)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Loc.tr("actions-cancel")) {
                        onFinish(nil)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Insert") { insert() }
                        .fontWeight(.semibold)
                        .disabled(!controller.hasContent)
                }
            }
            .task {
                #if DEBUG
                // Screenshot hook: seed a sample sketch so a captured drawing sheet
                // shows real ink (mirrors the reviewer's `-demoWhiteboard`).
                if ProcessInfo.processInfo.arguments.contains("-demoDrawCanvas") {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    controller.seedDemoStrokes()
                    controller.updateHasContent(true)
                }
                #endif
            }
        }
    }

    /// Exports the drawing to PNG and hands it back for storage + insertion.
    private func insert() {
        guard let data = controller.exportPNG() else {
            onFinish(nil)
            dismiss()
            return
        }
        onFinish(PickedMedia(data: data, desiredName: "drawing.png"))
        dismiss()
    }

    #if DEBUG
    /// A real PencilKit drawing (a check mark + underline) rendered to PNG, for the
    /// `-demoDrawingInsert` screenshot hook — proving the drawing-export path
    /// produces a genuine image inserted into a field. DEBUG-only.
    static func demoDrawingPNG() -> Data? {
        let ink = PKInk(.pen, color: UIColor(WhiteboardController.palette[3]))
        func stroke(_ polyline: [CGPoint]) -> PKStroke {
            var points: [PKStrokePoint] = []
            var offset: TimeInterval = 0
            for i in 0..<(polyline.count - 1) {
                let a = polyline[i], b = polyline[i + 1]
                for s in 0...14 {
                    let t = CGFloat(s) / 14
                    let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
                    points.append(PKStrokePoint(
                        location: p, timeOffset: offset,
                        size: CGSize(width: 8, height: 8),
                        opacity: 1, force: 1, azimuth: 0, altitude: 0
                    ))
                    offset += 0.01
                }
            }
            return PKStroke(ink: ink, path: PKStrokePath(controlPoints: points, creationDate: Date()))
        }
        var drawing = PKDrawing()
        drawing.strokes = [
            stroke([CGPoint(x: 20, y: 70), CGPoint(x: 45, y: 100), CGPoint(x: 110, y: 30)]),
            stroke([CGPoint(x: 15, y: 120), CGPoint(x: 150, y: 120)]),
        ]
        return drawing.image(from: CGRect(x: 0, y: 0, width: 170, height: 150), scale: 2).pngData()
    }
    #endif
}
