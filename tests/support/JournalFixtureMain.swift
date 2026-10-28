import Foundation

@main struct JournalFixtureMain {
    static func main() throws {
        let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let work = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try JournalFixtures.generate(at: destination, work: work)
        print("Generated journal fixtures through production Swift persistence.")
    }
}
