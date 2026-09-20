import Foundation
import SwiftUI

@MainActor
final class GraphAppModel: ObservableObject {
    @Published var projectRoot: URL?
    @Published var document: GraphDocument = .empty
    @Published var selectedId: String?
    @Published var status: String = "Open a Swift project (or LiteTrace demo)."
    @Published var isBusy = false
    @Published var backendInstalled = false
    @Published var searchQuery: String = ""

    var selectedNode: GraphNode? {
        guard let selectedId else { return nil }
        return document.nodes.first { $0.id == selectedId }
    }

    var filteredNodes: [GraphNode] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return document.nodes }
        return document.nodes.filter {
            $0.id.lowercased().contains(q) || $0.name.lowercased().contains(q) || $0.signature.lowercased().contains(q)
        }
    }

    init() {
        refreshBackendState()
    }

    func refreshBackendState() {
        backendInstalled = BackendRegistry.swiftPlugin().isInstalled
    }

    func openProject() {
        if let url = BackendRunner.pickProjectFolder(start: DemoPaths.liteTrace) {
            projectRoot = url
            status = "Opened \(url.lastPathComponent). Analyze to refresh SoT, or Load if SoT exists."
            tryLoadSoT()
        }
    }

    func openLiteTraceDemo() {
        let url = DemoPaths.liteTrace
        guard FileManager.default.fileExists(atPath: url.path) else {
            status = "LiteTrace not found at \(url.path)"
            return
        }
        projectRoot = url
        status = "Demo: LiteTrace"
        tryLoadSoT()
    }

    func installBackend() {
        isBusy = true
        status = "Installing Swift backend plugin…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let dest = try BackendRegistry.installSwiftBackend()
                DispatchQueue.main.async {
                    self.backendInstalled = true
                    self.isBusy = false
                    self.status = "Backend installed → \(dest.path)"
                }
            } catch {
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.status = error.localizedDescription
                }
            }
        }
    }

    func analyze() {
        guard let root = projectRoot else {
            status = "Open a project first."
            return
        }
        isBusy = true
        status = "Running Swift backend (writes .swiftprism SoT)…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let json = try BackendRunner.analyzeSwiftProject(root)
                let doc = try GraphLoader.load(projectRoot: root)
                DispatchQueue.main.async {
                    self.document = doc
                    self.selectedId = doc.nodes.first?.id
                    self.isBusy = false
                    self.backendInstalled = true
                    self.status = "SoT ready: \(doc.nodes.count) nodes, \(doc.links.count) links · \(json.lastPathComponent)"
                }
            } catch {
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.status = error.localizedDescription
                }
            }
        }
    }

    func tryLoadSoT() {
        guard let root = projectRoot else { return }
        do {
            let doc = try GraphLoader.load(projectRoot: root)
            document = doc
            if selectedId == nil { selectedId = doc.nodes.first?.id }
            status = "Loaded SoT: \(doc.nodes.count) nodes, \(doc.links.count) links"
        } catch {
            document = .empty
            status = error.localizedDescription
        }
    }
}
