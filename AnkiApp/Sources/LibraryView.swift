import SwiftUI
import AnkiKit

/// MCAT Speedrun Library: browse curated decks and import them in one tap.
///
/// Lists decks from the public Supabase "Library" (a read-only catalog table plus
/// a public storage bucket of `.apkg` files) and imports the chosen deck straight
/// into the collection **with scheduling** — so the readiness score and
/// weak-topics have data immediately. Read-only against the backend: the app only
/// GETs the catalog and downloads files; uploads are admin-only.
struct LibraryView: View {
    @ObservedObject var store: AnkiStore

    @State private var decks: [LibraryDeck] = []
    @State private var phase: Phase = .loading
    /// Non-nil while a download+import runs (drives the blocking overlay).
    @State private var busy: String?
    @State private var resultMessage: String?
    @State private var errorMessage: String?

    private enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    var body: some View {
        ZStack {
            DS.background.ignoresSafeArea()
            content
        }
        .navigationTitle("MCAT Library")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(busy != nil)
        .overlay { busyOverlay }
        .alert("Imported", isPresented: resultPresented) {
            Button("OK", role: .cancel) { resultMessage = nil }
        } message: {
            Text(resultMessage ?? "")
        }
        .alert("Something went wrong", isPresented: errorPresented) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView("Loading Library…")
                .tint(DS.accent)
                .foregroundStyle(DS.textSecondary)
        case .failed(let message):
            failedState(message)
        case .loaded:
            if decks.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: DS.Spacing.l) {
                        Text("Curated MCAT decks. Import one — scheduling is included, so your readiness score and weak-topics show right away.")
                            .font(DS.Typography.caption)
                            .foregroundStyle(DS.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(decks) { deck in
                            deckCard(deck)
                        }
                    }
                    .padding(DS.Spacing.l)
                }
            }
        }
    }

    private func deckCard(_ deck: LibraryDeck) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Text(deck.title)
                .font(DS.Typography.headline)
                .foregroundStyle(DS.textPrimary)
            if let description = deck.description, !description.isEmpty {
                Text(description)
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.textSecondary)
            }
            Text("\(deck.cardCount) cards · \(deck.sections.isEmpty ? "—" : deck.sections.joined(separator: ", "))")
                .font(DS.Typography.caption)
                .foregroundStyle(DS.textSecondary)

            Button {
                importDeck(deck)
            } label: {
                Label("Download & Import", systemImage: "square.and.arrow.down")
                    .font(DS.Typography.body.weight(.semibold))
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: DS.minTapTarget)
                    .background(
                        DS.accent,
                        in: RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            .padding(.top, DS.Spacing.xs)
            .accessibilityLabel("Download and import \(deck.title)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
    }

    private var emptyState: some View {
        VStack(spacing: DS.Spacing.m) {
            Image(systemName: "books.vertical")
                .font(.system(size: 44))
                .foregroundStyle(DS.textSecondary)
            Text("The Library is empty.")
                .font(DS.Typography.headline)
                .foregroundStyle(DS.textPrimary)
        }
        .padding(DS.Spacing.xl)
    }

    private func failedState(_ message: String) -> some View {
        VStack(spacing: DS.Spacing.m) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 44))
                .foregroundStyle(DS.textSecondary)
            Text("Couldn't reach the Library")
                .font(DS.Typography.headline)
                .foregroundStyle(DS.textPrimary)
            Text(message)
                .font(DS.Typography.caption)
                .foregroundStyle(DS.textSecondary)
                .multilineTextAlignment(.center)
            Button("Retry") { Task { await load() } }
                .buttonStyle(.borderedProminent)
                .tint(DS.accent)
        }
        .padding(DS.Spacing.xl)
    }

    @ViewBuilder
    private var busyOverlay: some View {
        if let busy {
            ZStack {
                Color.black.opacity(0.3).ignoresSafeArea()
                VStack(spacing: DS.Spacing.m) {
                    ProgressView()
                    Text(busy)
                        .font(DS.Typography.body)
                        .foregroundStyle(DS.textPrimary)
                }
                .dsCard()
                .fixedSize()
            }
            .transition(.opacity)
        }
    }

    // MARK: - Actions

    private func load() async {
        phase = .loading
        do {
            decks = try await MCATLibrary.fetchDecks()
            phase = .loaded
        } catch {
            phase = .failed(describe(error))
        }
    }

    private func importDeck(_ deck: LibraryDeck) {
        busy = "Downloading \(deck.title)…"
        Task { @MainActor in
            defer { busy = nil }
            do {
                let localURL = try await MCATLibrary.download(storagePath: deck.storagePath)
                defer { try? FileManager.default.removeItem(at: localURL) }
                busy = "Importing \(deck.title)…"
                let result = try await store.importLibraryDeck(fromLocalPath: localURL.path)
                var parts = ["\(result.imported) new"]
                if result.updated > 0 { parts.append("\(result.updated) updated") }
                if result.duplicate > 0 { parts.append("\(result.duplicate) duplicate") }
                resultMessage = "“\(deck.title)” imported (\(parts.joined(separator: ", "))). Open MCAT Readiness to see your score."
            } catch {
                errorMessage = describe(error)
            }
        }
    }

    private func describe(_ error: Error) -> String {
        if case let AnkiError.backendError(data) = error,
           let backendError = try? Anki_Backend_BackendError(serializedBytes: data),
           !backendError.message.isEmpty {
            return backendError.message
        }
        return error.localizedDescription
    }

    private var resultPresented: Binding<Bool> {
        Binding(get: { resultMessage != nil }, set: { if !$0 { resultMessage = nil } })
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }
}

/// One curated deck in the Library catalog (decoded from the Supabase REST row;
/// `convertFromSnakeCase` maps `card_count`/`storage_path`).
struct LibraryDeck: Identifiable, Decodable, Equatable {
    let id: String
    let title: String
    let description: String?
    let cardCount: Int
    let sections: [String]
    let storagePath: String
}

/// Read-only client for the public MCAT Speedrun Library on Supabase.
///
/// The anon key is designed to ship in clients: it only grants the public-read
/// access the Library's row-level-security policies allow (read the catalog +
/// download from the public bucket); it cannot write.
enum MCATLibrary {
    static let baseURL = "https://jscreeiypfopowtquriu.supabase.co"
    static let anonKey = """
    eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Impz\
    Y3JlZWl5cGZvcG93dHF1cml1Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODI5MzM2OTAsImV4cC\
    I6MjA5ODUwOTY5MH0.PIhKqznEhNLilhR2-bs60qetVzvWRcx1SrlZHZdZ7yM
    """
    private static let bucket = "decks"

    static func fetchDecks() async throws -> [LibraryDeck] {
        var comps = URLComponents(string: "\(baseURL)/rest/v1/decks")!
        comps.queryItems = [
            URLQueryItem(
                name: "select",
                value: "id,title,description,card_count,sections,storage_path"
            ),
            URLQueryItem(name: "order", value: "created_at.desc"),
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: req)
        try checkOK(response, data)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode([LibraryDeck].self, from: data)
    }

    /// Downloads a deck's `.apkg` from the public bucket to a temp file; the
    /// caller is responsible for removing the returned file.
    static func download(storagePath: String) async throws -> URL {
        let encoded = storagePath.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? storagePath
        guard let url = URL(string: "\(baseURL)/storage/v1/object/public/\(bucket)/\(encoded)")
        else { throw LibraryError.badPath }

        let (tempURL, response) = try await URLSession.shared.download(from: url)
        try checkOK(response, nil)
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("apkg")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tempURL, to: dest)
        return dest
    }

    private static func checkOK(_ response: URLResponse, _ data: Data?) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200 ..< 300).contains(http.statusCode) else {
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            throw LibraryError.http(status: http.statusCode, body: body)
        }
    }
}

enum LibraryError: LocalizedError {
    case badPath
    case http(status: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .badPath:
            return "That deck has an invalid download path."
        case let .http(status, body):
            let detail = body.isEmpty ? "" : " — \(body.prefix(140))"
            return "Server returned \(status)\(detail)"
        }
    }
}
