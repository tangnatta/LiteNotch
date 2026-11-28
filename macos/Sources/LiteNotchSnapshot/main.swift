import Foundation
import LiteNotchUI

var args = CommandLine.arguments
// `-AppleLocale en_GB` and the like are read by Foundation itself (the
// argument domain); scripts/previews.sh uses it so the README shows one
// locale whatever the Mac's. Leave such pairs out of the positional ones.
while let i = args.firstIndex(where: { $0.hasPrefix("-Apple") }) {
    args.removeSubrange(i..<min(i + 2, args.count))
}
// `--previews` writes the README's frame sequences instead (scripts/previews.sh).
let previews = args.count > 1 && args[1] == "--previews"
if previews { args.remove(at: 1) }
guard args.count == 3 else {
    FileHandle.standardError.write(Data("usage: LiteNotchSnapshot [--previews] <fixtures-dir> <out-dir>\n".utf8))
    exit(2)
}
do {
    let written = try MainActor.assumeIsolated {
        let fixtures = URL(fileURLWithPath: args[1])
        let out = URL(fileURLWithPath: args[2])
        return previews
            ? try PreviewRenderer.renderAll(fixturesDir: fixtures, outDir: out)
            : try SnapshotRenderer.renderAll(fixturesDir: fixtures, outDir: out)
    }
    for u in written { print(u.path) }
    print("rendered \(written.count) images")
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
