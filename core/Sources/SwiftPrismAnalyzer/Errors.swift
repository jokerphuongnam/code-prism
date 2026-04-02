import Foundation

enum PrismError: Error, CustomStringConvertible {
    case noInputPaths
    case fileUnreadable(String)
    case encodingFailed(detail: String)
    case invalidWorkspaceRoot(String)
    case directoryInaccessible(String)
    case noSwiftFilesFound(String)
    case outputWriteFailed(String)
    case parsingFailed(file: String, detail: String)

    var description: String {
        switch self {
        case .noInputPaths:
            return "No input provided. Usage: swift-prism-analyzer <project_path> <output_json_path> or swift-prism-analyzer --workspace <root> [file ...]"
        case .fileUnreadable(let path):
            return "Cannot read file at: \(path)"
        case .encodingFailed(let detail):
            return "JSON encoding failed: \(detail)"
        case .invalidWorkspaceRoot(let path):
            return "Invalid workspace root: \(path)"
        case .directoryInaccessible(let path):
            return "Directory is inaccessible or does not exist: \(path)"
        case .noSwiftFilesFound(let path):
            return "No .swift files found in directory: \(path)"
        case .outputWriteFailed(let path):
            return "Failed to write output to: \(path)"
        case .parsingFailed(let file, let detail):
            return "Parsing failed for \(file): \(detail)"
        }
    }
}
