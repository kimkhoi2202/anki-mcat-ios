import SwiftUI
import UIKit
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Picked media model

/// A piece of media the user picked or recorded, ready to be stored in the
/// collection: the raw bytes plus a desired filename (with an extension) that
/// the engine sanitizes and deduplicates before returning the final stored name.
///
/// `Sendable` so it can cross the photo picker's background loading callback back
/// to the main actor without tripping strict concurrency.
struct PickedMedia: Sendable {
    let data: Data
    /// A filename *with extension* — the engine derives the stored name from it,
    /// so the extension must be right for the bytes (drives `<img>`/playback).
    let desiredName: String
}

// MARK: - Photo library (PHPicker)

/// Photo-library image picker built on `PHPickerViewController`. Runs
/// out-of-process, so it needs no photo-library permission. Loads the original
/// image bytes (and matching extension) rather than re-encoding, preserving the
/// file as Anki would store it. Mirrors AnkiDroid's gallery pick.
struct PhotoLibraryPicker: UIViewControllerRepresentable {
    let onPicked: (PickedMedia?) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    /// `@unchecked Sendable`: the picker's image bytes load on a background queue,
    /// so the completion (which the SDK treats as crossing isolation) captures the
    /// coordinator. The stored `onPicked` is only ever *invoked* back on the main
    /// queue (via `DispatchQueue.main.async`), so this is safe by construction.
    final class Coordinator: NSObject, PHPickerViewControllerDelegate, @unchecked Sendable {
        private let onPicked: (PickedMedia?) -> Void
        init(onPicked: @escaping (PickedMedia?) -> Void) { self.onPicked = onPicked }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let provider = results.first?.itemProvider else { onPicked(nil); return }
            // Prefer a concrete image UTI so the stored file keeps its real
            // extension (png/jpeg/heic/…); fall back to generic image/jpeg.
            let typeID = provider.registeredTypeIdentifiers.first {
                UTType($0)?.conforms(to: .image) == true
            } ?? UTType.jpeg.identifier
            let ext = UTType(typeID)?.preferredFilenameExtension ?? "jpg"
            provider.loadDataRepresentation(forTypeIdentifier: typeID) { [weak self] data, _ in
                let payload = data.map { PickedMedia(data: $0, desiredName: "image.\(ext)") }
                DispatchQueue.main.async { self?.onPicked(payload) }
            }
        }
    }
}

// MARK: - Camera capture

/// Camera capture built on `UIImagePickerController` (`.camera`). Returns the
/// shot as JPEG. Only usable where a camera exists (`isAvailable`), so the
/// editor hides the option on the Simulator, matching AnkiDroid gating the
/// camera action on hardware availability.
struct CameraPicker: UIViewControllerRepresentable {
    let onPicked: (PickedMedia?) -> Void

    /// Whether this device actually has a camera (false on the Simulator).
    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private let onPicked: (PickedMedia?) -> Void
        init(onPicked: @escaping (PickedMedia?) -> Void) { self.onPicked = onPicked }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage,
               let data = image.jpegData(compressionQuality: 0.9) {
                onPicked(PickedMedia(data: data, desiredName: "image.jpg"))
            } else {
                onPicked(nil)
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onPicked(nil)
        }
    }
}

// MARK: - Audio file (document picker)

/// Existing-audio-file picker built on `UIDocumentPickerViewController`. Opens
/// audio types as a local copy (`asCopy: true`) so the bytes are readable
/// without security-scoped bookmarks, keeping the original filename/extension.
/// Mirrors AnkiDroid attaching an audio clip from storage.
struct AudioDocumentPicker: UIViewControllerRepresentable {
    let onPicked: (PickedMedia?) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.audio], asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPicked: (PickedMedia?) -> Void
        init(onPicked: @escaping (PickedMedia?) -> Void) { self.onPicked = onPicked }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { onPicked(nil); return }
            // `asCopy: true` hands back a temporary copy in our container, so a
            // direct read works (no startAccessingSecurityScopedResource needed).
            if let data = try? Data(contentsOf: url) {
                onPicked(PickedMedia(data: data, desiredName: url.lastPathComponent))
            } else {
                onPicked(nil)
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onPicked(nil)
        }
    }
}

// MARK: - Audio recorder

/// Records a short audio clip with `AVAudioRecorder` (AAC/`.m4a`) and hands the
/// bytes back for storage. Mirrors AnkiDroid's in-editor "record audio" action:
/// request mic permission, record, then attach the clip. Presented as a sheet.
struct AudioRecorderView: View {
    let onFinish: (PickedMedia?) -> Void

    @StateObject private var recorder = AudioRecorderModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: DS.Spacing.l) {
                Spacer()

                Image(systemName: recorder.isRecording ? "waveform.circle.fill" : "mic.circle")
                    .font(.system(size: 96))
                    .foregroundStyle(recorder.isRecording ? DS.again : DS.accent)

                Text(recorder.statusText)
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                if recorder.permissionDenied {
                    Text("Enable microphone access in Settings to record audio.")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Spacer()

                HStack(spacing: DS.Spacing.l) {
                    if recorder.isRecording {
                        Button(role: .destructive) {
                            recorder.stop()
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button {
                            recorder.start()
                        } label: {
                            Label(recorder.hasRecording ? "Re-record" : "Record",
                                  systemImage: "record.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(recorder.permissionDenied)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, DS.Spacing.l)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DS.background.ignoresSafeArea())
            .navigationTitle("Record Audio")
            .navigationBarTitleDisplayMode(.inline)
            .tint(DS.accent)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        recorder.cancel()
                        onFinish(nil)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use") {
                        if let media = recorder.finishedMedia() {
                            onFinish(media)
                        } else {
                            onFinish(nil)
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(!recorder.hasRecording || recorder.isRecording)
                }
            }
            .task { await recorder.prepare() }
            .onDisappear { recorder.cancel() }
        }
    }
}

/// Drives `AudioRecorderView`: microphone permission, an `AVAudioRecorder`
/// writing AAC into a temp `.m4a`, and reading the result back as bytes.
@MainActor
final class AudioRecorderModel: ObservableObject {
    @Published var isRecording = false
    @Published var hasRecording = false
    @Published var permissionDenied = false
    @Published var statusText = "Tap record to start."

    private var recorder: AVAudioRecorder?
    private var fileURL: URL?

    /// Requests mic permission up front so the record button reflects it.
    func prepare() async {
        let granted = await Self.requestMicPermission()
        permissionDenied = !granted
        if !granted { statusText = "Microphone access is needed to record." }
    }

    func start() {
        guard !permissionDenied else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default)
            try session.setActive(true)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            guard recorder.record() else {
                statusText = "Couldn’t start recording."
                return
            }
            self.recorder = recorder
            self.fileURL = url
            isRecording = true
            hasRecording = false
            statusText = "Recording… tap stop when done."
        } catch {
            statusText = "Couldn’t start recording."
        }
    }

    func stop() {
        recorder?.stop()
        isRecording = false
        hasRecording = (fileURL != nil)
        statusText = hasRecording ? "Recorded. Tap Use to attach." : "Nothing recorded."
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Reads the recorded clip back as bytes for storage, or nil if none.
    func finishedMedia() -> PickedMedia? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return PickedMedia(data: data, desiredName: "recording.m4a")
    }

    /// Stops and discards any in-progress/finished recording (Cancel / dismiss).
    func cancel() {
        if isRecording { recorder?.stop() }
        isRecording = false
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
        fileURL = nil
        hasRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Requests record permission, bridging the iOS 17 `AVAudioApplication` API
    /// and the pre-17 `AVAudioSession` one so we stay warning-free on iOS 16.
    private static func requestMicPermission() async -> Bool {
        if #available(iOS 17.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        } else {
            return await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }
}
