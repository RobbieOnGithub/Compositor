import AppKit
import Testing
@testable import Compositor

@MainActor struct BrushEnumerationSafetyTests {
    @Test func candidateBoundsAreCheckedBeforeTileBookkeeping() throws {
        let layer = ImageLayer(name: "Sparse", blankSize: CGSize(width: 30_000, height: 30_000))
        let stroke = try BrushStroke(layer: layer, mask: false, settings: BrushSettings(), canvas: layer.size, useGPU: false)
        #expect(throws: ProjectError.self) { try stroke.checkedCandidateBounds(CGRect(x: 0, y: 0, width: 30_000, height: 30_000)) }
        #expect(throws: ProjectError.self) { try stroke.checkedCandidateBounds(CGRect(x: 0, y: 0, width: 1e9, height: 1e9)) }
        #expect(try stroke.checkedCandidateBounds(CGRect(x: 100, y: 100, width: 40, height: 40)).width == 256)
        stroke.pixelLimit = 100
        #expect(try stroke.checkedCandidateBounds(CGRect(x: 100, y: 100, width: 40, height: 40)).width == 256)
    }
    @Test(arguments: [false, true])
    func paintingADownscaledLayerRejectsExcessiveWork(useGPU: Bool) throws {
        let context = try BrushRaster.context(width: 1000, height: 1000, mask: false)
        let image = try #require(context.makeImage())
        var layer = ImageLayer(asset: ImportedImage(image: image, thumbnail: image, name: "Scaled"), origin: .zero)
        layer.transform.size = CGSize(width: 1, height: 1)
        let stroke = try BrushStroke(layer: layer, mask: false, settings: BrushSettings(diameter: 2000), canvas: CGSize(width: 1000, height: 1000), useGPU: useGPU)
        #expect(throws: ProjectError.self) { try stroke.append(CGPoint(x: 500, y: 500)) }
    }

    @Test func softwareTailHaloDoesNotConsumeRasterBudget() throws {
        let layer = ImageLayer(name: "Sparse", blankSize: CGSize(width: 512, height: 512))
        let stroke = try BrushStroke(layer: layer, mask: false, settings: BrushSettings(diameter: 2), canvas: layer.size, useGPU: false)
        stroke.pixelLimit = 65_536
        try stroke.append(CGPoint(x: 254, y: 100))
        try stroke.append(CGPoint(x: 254, y: 101))
        try stroke.flush()
    }
    @Test func softwareSecondSampleRejectsUnboundedTailBookkeeping() throws {
        let layer = ImageLayer(name: "Sparse", blankSize: CGSize(width: 30_000, height: 30_000))
        let stroke = try BrushStroke(layer: layer, mask: false, settings: BrushSettings(diameter: 2), canvas: layer.size, useGPU: false)
        try stroke.append(CGPoint(x: 100, y: 100))
        #expect(throws: ProjectError.self) { try stroke.append(CGPoint(x: 29_000, y: 29_000)) }
    }

}
