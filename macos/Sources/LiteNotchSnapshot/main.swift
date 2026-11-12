import Foundation
import LiteNotchUI

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(Data("usage: LiteNotchSnapshot <fixtures-dir> <out-dir>\n".utf8))
    exit(2)
}
do {
    let written = try MainActor.assumeIsolated {
        try SnapshotRenderer.renderAll(fixturesDir: URL(fileURLWithPath: args[1]),
                                       outDir: URL(fileURLWithPath: args[2]))
    }
    for u in written { print(u.path) }
    print("rendered \(written.count) images")
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
