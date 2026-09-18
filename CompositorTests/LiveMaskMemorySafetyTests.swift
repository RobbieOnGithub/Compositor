import AppKit
import Testing
@testable import Compositor

struct LiveMaskMemorySafetyTests {
    @Test func recursiveDependenciesStopBeforeExceedingBudget() throws {
        let a = UUID(), b = UUID(), c = UUID()
        var draws = 0
        let renderer = LiveMaskRenderer(bounds: CGRect(x: 0, y: 0, width: 10, height: 10), source: { $0 == a ? b : ($0 == b ? c : nil) }, maximumWorkingBytes: 600) { _, _ in draws += 1 }
        let context = try BrushRaster.context(width: 10, height: 10, mask: false)
        renderer.draw(a, in: context)
        #expect(renderer.failed)
        #expect(draws == 0)
        renderer.draw(c, in: context)
        #expect(draws == 0) // A failure never falls back to unmasked drawing.
    }
    @Test func ordinaryDependencyReusesItsBoundedCache() throws {
        let source = UUID(), target = UUID()
        var sourceDraws = 0
        let renderer = LiveMaskRenderer(bounds: CGRect(x: 0, y: 0, width: 10, height: 10), source: { $0 == target ? source : nil }, maximumWorkingBytes: 600) { id, ctx in
            if id == source { sourceDraws += 1 }
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }
        let context = try BrushRaster.context(width: 10, height: 10, mask: false)
        renderer.draw(target, in: context)
        renderer.draw(target, in: context)
        #expect(!renderer.failed)
        #expect(sourceDraws == 1)
    }
    @MainActor @Test func exportRejectsInsteadOfPublishingPartialComposite() async throws {
        let context = try BrushRaster.context(width: 10, height: 10, mask: false)
        let image = try #require(context.makeImage())
        let session = EditorSession()
        session.createDocument(width: 10, height: 10)
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Base"))
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Clipped"))
        let base = try #require(session.document?.layers.first?.id)
        session.document?.layers[1].maskSourceID = base
        let snapshot = try #require(session.projectSnapshot())
        await #expect(throws: ExportError.self) {
            try await ImageExporter.shared.render(snapshot, maximumLiveMaskBytes: 1)
        }
    }

    @Test func sequentialAdjustmentsReleaseTemporaryCharges() throws {
        let renderer = LiveMaskRenderer(bounds: CGRect(x: 0, y: 0, width: 10, height: 10), source: { _ in nil }, maximumWorkingBytes: 3200) { _, _ in }
        renderer.adjustment = { _ in LayerAdjustment(kind: .levels) }
        let context = try BrushRaster.context(width: 10, height: 10, mask: false)
        for _ in 0..<10 { renderer.drawComposite(UUID(), in: context) }
        #expect(!renderer.failed)
    }
    @Test func allocationFailureIsReportedInsteadOfDroppingAMaskedLayer() throws {
        let source = UUID(), target = UUID()
        var draws = 0
        let renderer = LiveMaskRenderer(bounds: CGRect(x: 0, y: 0, width: 10, height: 10), source: { $0 == target ? source : nil }) { _, _ in draws += 1 }
        renderer.makeContext = { _, _, _ in throw ExportError.render }
        let context = try BrushRaster.context(width: 10, height: 10, mask: false)
        renderer.draw(target, in: context)
        #expect(renderer.failed && draws == 0)
    }

}
