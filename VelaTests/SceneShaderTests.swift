import Metal
import XCTest
@testable import Vela

/// The scene shader is compiled from source at runtime, so a mistake in it does not fail the
/// build: `SceneRenderer` quietly returns nil and the app falls back to its SwiftUI canvas.
/// These tests are the build-time check the shader otherwise never gets.
final class SceneShaderTests: XCTestCase {
    func testSceneShaderCompilesWithEveryEntryPoint() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device.") }
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: SceneShaderSource.source, options: nil)
        } catch {
            return XCTFail("Scene shader failed to compile: \(error)")
        }
        for name in ["sceneVertex", "sceneFragment", "particleVertex", "particleFragment"] {
            XCTAssertNotNil(library.makeFunction(name: name), "Missing shader function \(name).")
        }
    }

    func testRendererBuildsItsPipelines() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device.") }
        XCTAssertNotNil(SceneRenderer(director: VisualDirector(), features: FeatureStore()),
                        "A nil renderer means the app would silently drop to the fallback canvas.")
    }

    /// The Swift mirror must match the Metal struct member for member, or every uniform after the
    /// first mismatch is read from the wrong place.
    func testUniformLayoutMatchesTheShader() {
        let source = SceneShaderSource.source
        guard let start = source.range(of: "struct SceneUniforms {"),
              let end = source.range(of: "};", range: start.upperBound..<source.endIndex) else {
            return XCTFail("SceneUniforms not found in the shader source.")
        }
        var float4s = 0
        for line in source[start.upperBound..<end.lowerBound].split(separator: "\n") {
            let code = line.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            guard code.contains("float4") else { continue }
            if let open = code.firstIndex(of: "["), let close = code.firstIndex(of: "]"),
               let count = Int(code[code.index(after: open)..<close]) {
                float4s += count
            } else {
                float4s += 1
            }
        }
        XCTAssertEqual(MemoryLayout<SceneUniforms>.stride, float4s * MemoryLayout<SIMD4<Float>>.stride)
    }
}
