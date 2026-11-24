import A2UICore
import BasicCatalog
import Foundation
import OrderedJSON

// Reads A2UI messages, one per line, from the files named (or stdin), and hands them to a
// MessageProcessor with dense's catalogs, as a session with an Extension does. Prints every
// error dense would show on a surface, and exits 1 if there was any.

let basic = BasicCatalog.makeCatalog(version: .v10)
let dense = DenseCatalogSchema.catalog(
    basic: basic, components: DenseCatalogSchema.components,
    functions: DenseCatalogSchema.functions.map(SchemaOnlyFunction.init(api:)))

nonisolated(unsafe) var errors: [String] = []
nonisolated(unsafe) var at = ""
let processor = MessageProcessor(catalogs: [basic, dense])
processor.outboundListener = { message in
    if case .error = message, let data = try? JSONEncoder().encode(message) {
        errors.append("\(at): \(String(decoding: data, as: UTF8.self))")
    }
}

let files = CommandLine.arguments.dropFirst()
var count = 0 // messages processed without an error thrown
for file in files.isEmpty ? ["-"] : Array(files) {
    let text = file == "-"
        ? String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        : try String(contentsOfFile: file, encoding: .utf8)
    for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        at = "\(file):\(n + 1)"
        guard !line.allSatisfy(\.isWhitespace) else { continue }
        do {
            let json = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
            if json.objectValue?["dense"] != nil { continue } // dense's own, not A2UI
            try processor.processMessages(json)
            count += 1
        } catch {
            errors.append("\(at): \(error)")
        }
    }
}

for error in errors { print(error) }
print(errors.isEmpty ? "ok: \(count) messages" : "\(errors.count) errors in \(count) messages")
exit(errors.isEmpty ? 0 : 1)
