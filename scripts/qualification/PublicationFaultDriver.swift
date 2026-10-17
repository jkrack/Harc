import Foundation
import Darwin

/// Compiled with the production Core sources by qualify-publication-faults.py.
/// It stops only its own disposable process at a named publication boundary.
@main
struct PublicationFaultDriver {
    static func main() {
        do { try run() }
        catch {
            let error = error as NSError
            print("ERROR \(error.domain) \(error.code): \(error.localizedDescription)")
            exit(2)
        }
    }

    static func run() throws {
        let args = CommandLine.arguments
        guard args.count == 4 else { throw CocoaError(.fileReadInvalidFileName) }
        let operation = args[1]
        let source = URL(fileURLWithPath: args[2])
        let destination = URL(fileURLWithPath: args[3])
        if operation == "freeze" {
            try CaptureDestinationBinding(source: source, baseDirectory: destination.deletingLastPathComponent(),
                volumeIdentity: RecordingPublication.volumeIdentity(containing: destination)).save()
            print("FROZEN")
            return
        }
        let expected = try CaptureDestinationBinding.load(for: source)?.volumeIdentity
        let intent = try RecordingPublication.prepare(source: source, destination: destination,
                                                     expectedVolumeIdentity: expected)
        func checkpoint() {
            FileHandle.standardOutput.write(Data("CHECKPOINT\n".utf8))
            raise(SIGSTOP)
        }
        switch operation {
        case "prepare-only":
            print("PREPARED")
        case "attempt":
            do {
                try intent.publish()
                print("PUBLISHED")
            } catch {
                var current: NSError? = error as NSError
                while let value = current {
                    print("ERROR \(value.domain) \(value.code)")
                    current = value.userInfo[NSUnderlyingErrorKey] as? NSError
                }
                exit(2)
            }
        case "prepared":
            checkpoint()
        case "renamed":
            try intent.publish(removingSource: true, synchronizeDestination: { _ in checkpoint() })
        case "published":
            try intent.publish()
            checkpoint()
        case "resume":
            try intent.publish()
            guard try intent.matches(destination),
                  !FileManager.default.fileExists(atPath: source.path),
                  try RecordingPublication.load(for: source) == intent else {
                throw RecordingPublication.PublicationError.contentConflict
            }
            // No Library row is created by this driver. Keep the intent, as
            // production does until the separate Library commit succeeds.
            print("RESUMED")
        default:
            throw CocoaError(.fileReadInvalidFileName)
        }
    }
}
