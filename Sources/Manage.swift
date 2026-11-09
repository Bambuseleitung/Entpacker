import SwiftUI

struct MoveJob: Identifiable {
    let id = UUID()
    let urls: [URL]
}

/// Ordnerliste zum Verschieben; schließt die verschobenen Ordner und deren Unterordner aus.
struct MoveSheet: View {
    let job: MoveJob
    let done: (String?) -> Void
    @Environment(\.dismiss) private var dismiss

    private var folders: [URL] {
        var all = [docs]
        if let walker = FileManager.default.enumerator(at: docs, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) {
            for case let u as URL in walker where (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { all.append(u) }
        }
        return all.filter { f in !job.urls.contains { f.path == $0.path || f.path.hasPrefix($0.path + "/") } }
    }

    var body: some View {
        NavigationStack {
            List(folders, id: \.path) { f in
                Button { move(to: f) } label: {
                    Label(f == docs ? "Hauptordner" : String(f.path.dropFirst(docs.path.count + 1)), systemImage: "folder")
                }
            }
            .navigationTitle("Verschieben nach")
            .toolbar { Button("Abbrechen") { dismiss() } }
        }
    }

    private func move(to folder: URL) {
        var errors: [String] = []
        for u in job.urls {
            do { try FileManager.default.moveItem(at: u, to: unique(folder.appendingPathComponent(u.lastPathComponent))) }
            catch { errors.append("\(u.lastPathComponent): \(describe(error))") }
        }
        dismiss()
        done(errors.isEmpty ? nil : errors.joined(separator: "\n"))
    }
}
