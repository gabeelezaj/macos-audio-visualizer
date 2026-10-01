import Foundation

/// Finds Shaders.metal at runtime. Metal compiles it in-process, so the app needs
/// no Xcode toolchain — the source ships as a plain resource inside the bundle.
enum ShaderLoader {
    static func source() throws -> String {
        for url in candidateURLs() {
            if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
                return text
            }
        }
        throw RendererError.missingShaderSource
    }

    private static func candidateURLs() -> [URL] {
        var urls: [URL] = []
        if let bundled = Bundle.main.url(forResource: "Shaders", withExtension: "metal") {
            urls.append(bundled)
        }
        urls.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Shaders.metal"))
        // Running straight from `swift run` during development.
        let sourceRelative = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Shaders.metal")
        urls.append(sourceRelative)
        return urls
    }
}
