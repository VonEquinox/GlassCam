import Foundation
import Darwin

enum FixtureGenerationError: Error, CustomStringConvertible {
    case usage, existingDestination, repositoryDestination

    var description: String {
        switch self {
        case .usage: return "Usage: generate_journal_fixtures --output /absolute/path/to/new/external-directory"
        case .existingDestination: return "The output directory must not already exist."
        case .repositoryDestination: return "The output directory must be outside the GlassCam repository."
        }
    }
}

func resolvedDestination(_ url: URL) -> URL {
    var ancestor = url.standardizedFileURL
    var missingComponents: [String] = []
    while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
        missingComponents.insert(ancestor.lastPathComponent, at: 0)
        ancestor.deleteLastPathComponent()
    }
    return missingComponents.reduce(ancestor.resolvingSymlinksInPath()) { parent, component in
        parent.appendingPathComponent(component, isDirectory: true)
    }
}

func generateCandidate() throws {
    let arguments = CommandLine.arguments
    guard arguments.count == 3, arguments[1] == "--output", arguments[2].hasPrefix("/") else {
        throw FixtureGenerationError.usage
    }
    let manager = FileManager.default
    let destination = resolvedDestination(URL(fileURLWithPath: arguments[2], isDirectory: true))
    var repository = URL(fileURLWithPath: #filePath)
    for _ in 0..<4 { repository.deleteLastPathComponent() }
    repository = repository.standardizedFileURL.resolvingSymlinksInPath()
    guard destination.path != repository.path, !destination.path.hasPrefix(repository.path + "/") else {
        throw FixtureGenerationError.repositoryDestination
    }
    guard !manager.fileExists(atPath: destination.path) else { throw FixtureGenerationError.existingDestination }

    // An exclusive mkdir also protects against replacing a directory created after validation.
    guard mkdir(destination.path, S_IRWXU) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    let work = destination.appendingPathComponent(".work", isDirectory: true)
    try manager.createDirectory(at: work, withIntermediateDirectories: false)
    defer { try? manager.removeItem(at: work) }
    try JournalFixtures.generate(at: destination, work: work)
    print("Generated journal fixture candidate: \(destination.path)")
}

do {
    try generateCandidate()
} catch {
    FileHandle.standardError.write(Data("Journal fixture generation failed: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}
