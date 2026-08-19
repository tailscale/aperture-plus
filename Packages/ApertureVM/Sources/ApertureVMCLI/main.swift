import ApertureVM
import Foundation

@main
struct ApertureVMCLI {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            let workspace = try value(for: "--workspace", in: arguments)
                .map(URL.init(fileURLWithPath:))
                ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            let artifacts = try value(for: "--artifacts", in: arguments)
                .map(URL.init(fileURLWithPath:))
                ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appending(path: "MacApp/Thunderboot", directoryHint: .isDirectory)
            let id = UUID(uuidString: try value(for: "--workspace-id", in: arguments) ?? "") ?? UUID()
            let storageOnly = arguments.contains("--storage-only")
            let timeout = TimeInterval(try value(for: "--timeout", in: arguments) ?? "120") ?? 120
            let controller = VMController(configuration: VMConfiguration(
                workspaceID: id,
                workspaceDirectory: workspace,
                artifactRoots: [artifacts],
                storageOnly: storageOnly
            ))
            print("workspace: \(workspace.path)")
            print("artifacts: \(artifacts.path)")
            print("starting VM")
            controller.start()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                fputs("aperture-vm: timed out after \(timeout)s\n", stderr)
                controller.stop()
                exit(124)
            }
            var serial = ""
            for await event in controller.events {
                switch event {
                case .log(let line):
                    serial.append(line)
                    if serial.count > 128_000 { serial.removeFirst(serial.count - 128_000) }
                    print("guest: \(line)")
                    if storageOnly && serial.contains("THUNDERBOOT STORAGE OK:") {
                        print("storage check passed")
                        controller.stop()
                        exit(0)
                    }
                case .phase(let phase):
                    print("phase: \(phase.description)")
                    if case .failed(let stage, let message) = phase {
                        fputs("VM failed at \(stage): \(message)\n", stderr)
                        controller.stop()
                        return
                    }
                }
            }
        } catch {
            fputs("aperture-vm: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func value(for name: String, in arguments: [String]) throws -> String? {
        guard let index = arguments.firstIndex(of: name) else { return nil }
        guard arguments.index(after: index) != arguments.endIndex else {
            throw CLIError.missingValue(name)
        }
        return arguments[arguments.index(after: index)]
    }
}

private enum CLIError: LocalizedError {
    case missingValue(String)
    var errorDescription: String? {
        switch self { case .missingValue(let name): return "missing value for \(name)" }
    }
}
