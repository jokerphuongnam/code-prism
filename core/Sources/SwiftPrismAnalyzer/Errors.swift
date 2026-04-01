import Foundation

enum PrismError: Error, CustomStringConvertible {
    case noInputPaths
    case fileUnreadable(String)
    case encodingFailed
    case invalidWorkspaceRoot(String)

    var description: String {
        switch self {
        case .noInputPaths:
            return "No input provided. Usage: swift-prism-analyzer --workspace <root> [file ...] or swift-prism-analyzer <file> [file ...]"
        case .fileUnreadable(let path):
            return "Cannot read file at: \(path)"
        case .encodingFailed:
            return "Failed to encode analysis result to JSON"
        case .invalidWorkspaceRoot(let path):
            return "Invalid workspace root: \(path)"
        }
    }
}
