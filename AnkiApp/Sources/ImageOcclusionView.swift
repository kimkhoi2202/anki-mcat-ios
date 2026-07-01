import SwiftUI
import AnkiKit

/// What the image-occlusion editor is doing. Maps 1:1 onto the web route's
/// catch-all parameter (`ts/routes/image-occlusion/[...imagePathOrNoteId]`),
/// whose loader (`+page.ts`) decides the mode from the value: a leading digit →
/// "edit" with that note id, otherwise "add" with that image *path*. This is the
/// exact contract AnkiDroid/desktop use.
enum ImageOcclusionMode: Equatable {
    /// Add a new IO note from a just-picked image at `imagePath` — an absolute
    /// filesystem path the engine reads via `get_image_for_occlusion` to display,
    /// and reads again + copies into `collection.media` when
    /// `add_image_occlusion_note` saves. Matches AnkiDroid's `ImageOcclusionArgs.Add`.
    case add(imagePath: String)
    /// Edit an existing IO note; its image, masks, header/back-extra and tags load
    /// via `get_image_occlusion_note` and save via `update_image_occlusion_note`.
    case edit(noteID: Int64)
}

/// Image Occlusion editor — Anki's real `image-occlusion` web page in a WebView,
/// exactly as AnkiDroid/desktop render it (the fabric.js mask canvas, the
/// shape/zoom toolbar, the Masks/Notes tabs, tags). Backed by our engine through
/// ``AnkiWebPage``; presented as a sheet from the Note Editor (add) or the note
/// editors (edit).
///
/// Host↔web contract (identical to AnkiDroid's `ImageOcclusion` fragment):
/// - The route value is the image path (add) or note id (edit); the page's
///   `+page.ts` loader turns it into the right `IOMode` and exposes
///   `globalThis.anki.imageOcclusion.{mode, save}`.
/// - Saving is host-driven: the native **Add/Save** button calls
///   `anki.imageOcclusion.save()` (via ``AnkiWebPageController``), which fires
///   `add_image_occlusion_note` / `update_image_occlusion_note`.
/// - Those RPCs run only on success, so ``AnkiWebPage`` closes the screen off
///   them (refresh + dismiss), mirroring AnkiDroid's `handlePostRequest` hook.
@MainActor
struct ImageOcclusionView: View {
    @ObservedObject var store: AnkiStore
    let mode: ImageOcclusionMode
    /// For the add flow: the temporary image file this editor was pointed at,
    /// deleted when the editor closes (the engine has already copied it into
    /// `collection.media` by then, on save).
    var temporaryImageURL: URL? = nil
    /// Invoked after the page saves so the presenting screen can refresh.
    var onSaved: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    /// Imperative handle so the native Save button can call the page's own
    /// `anki.imageOcclusion.save()` (AnkiDroid drives save the same way).
    @StateObject private var controller = AnkiWebPageController()

    var body: some View {
        NavigationStack {
            Group {
                if let backend = store.sharedBackend {
                    AnkiWebPage(
                        pagePath: pagePath,
                        backend: backend,
                        nightMode: colorScheme == .dark,
                        controller: controller,
                        onClose: {
                            onSaved()
                            dismiss()
                        }
                    )
                    .ignoresSafeArea(edges: .bottom)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(DS.background)
                }
            }
            .navigationTitle(Loc.tr("notetypes-image-occlusion-name"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Loc.tr("actions-close")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? Loc.tr("actions-save") : Loc.tr("actions-add")) {
                        // Optional-chained so a tap before the page finishes
                        // loading is a harmless no-op instead of a JS error.
                        controller.evaluateJavaScript("globalThis.anki?.imageOcclusion?.save?.()")
                    }
                    .fontWeight(.semibold)
                }
            }
            .onDisappear { cleanUpTemporaryImage() }
            #if DEBUG
            .task { await autoAddIfRequested() }
            #endif
        }
    }

    #if DEBUG
    /// Verification hook (`-demoImageOcclusionAutoAdd`): once the page is up, draw
    /// two occlusion masks via the page's own `maskEditor` API and trigger
    /// `anki.imageOcclusion.save()` — exercising the full add round-trip
    /// (getImageForOcclusion → draw → addImageOcclusionNote → close). Debug-only.
    private func autoAddIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("-demoImageOcclusionAutoAdd") else { return }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        controller.evaluateJavaScript(Self.autoAddMaskAndSaveJS)
    }

    /// In-page script that waits for the fabric canvas + bounding box to exist,
    /// adds two rectangle masks (normalized coordinates), then saves.
    private static let autoAddMaskAndSaveJS = """
    (function () {
      var tries = 0;
      var timer = setInterval(function () {
        tries++;
        var api = globalThis.maskEditor;
        var canvas = globalThis.canvas;
        var bounding = (canvas && canvas.getObjects)
          ? canvas.getObjects().find(function (o) { return o.id === "boundingBox"; })
          : null;
        if (api && canvas && bounding) {
          clearInterval(timer);
          api.addShape(bounding, new api.Rectangle({ left: 0.12, top: 0.28, width: 0.32, height: 0.24 }));
          api.addShape(bounding, new api.Rectangle({ left: 0.56, top: 0.28, width: 0.32, height: 0.24 }));
          canvas.renderAll();
          setTimeout(function () {
            if (globalThis.anki && globalThis.anki.imageOcclusion) {
              globalThis.anki.imageOcclusion.save();
            }
          }, 500);
        } else if (tries > 40) {
          clearInterval(timer);
        }
      }, 250);
    })();
    """
    #endif

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    /// The SvelteKit route for the editor. The add-mode image path is
    /// percent-encoded (including its slashes) so the whole absolute path arrives
    /// as a single catch-all segment the loader can read back verbatim — exactly
    /// what AnkiDroid does with `Uri.encode(imagePath)`.
    private var pagePath: String {
        switch mode {
        case .add(let imagePath):
            let encoded = imagePath.addingPercentEncoding(
                withAllowedCharacters: Self.pathSegmentAllowed
            ) ?? imagePath
            return "image-occlusion/\(encoded)"
        case .edit(let noteID):
            return "image-occlusion/\(noteID)"
        }
    }

    /// RFC 3986 unreserved characters only — everything else (notably `/`) is
    /// percent-encoded so the path stays one route segment.
    private static let pathSegmentAllowed: CharacterSet = {
        CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    }()

    /// Removes the temporary add-image file (and its unique folder). Best-effort:
    /// the engine copied the bytes into media on save, so losing the temp is fine.
    private func cleanUpTemporaryImage() {
        guard let url = temporaryImageURL else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

// MARK: - Add-flow helper

extension ImageOcclusionView {
    /// Writes just-picked image bytes to a unique temporary folder and returns the
    /// file URL to open the editor with (add mode). Each pick gets its own folder
    /// so the file keeps a clean basename (which becomes the stored media name via
    /// `add_image_occlusion_note`) without colliding across picks. Returns nil if
    /// the write fails.
    static func writeTemporaryImage(_ media: PickedMedia) -> URL? {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("image-occlusion-\(UUID().uuidString)", isDirectory: true)
        let name = media.desiredName.isEmpty ? "image.png" : media.desiredName
        let fileURL = folder.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try media.data.write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            return nil
        }
    }
}

/// Identifiable add-flow target so a `.sheet(item:)` can present the editor for a
/// just-written temporary image (carrying the file URL for both the route and
/// its later cleanup).
struct ImageOcclusionAddTarget: Identifiable {
    let id = UUID()
    let imageURL: URL
}
