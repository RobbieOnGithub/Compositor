import AppKit
import Testing
@testable import Compositor

struct SelectionComplexitySafetyTests {
    @Test func boundaryBudgetRejectsBeforeBuildingAnUnboundedGraph() throws {
        let context = try BrushRaster.context(width: 3, height: 3, mask: false)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 3, height: 3))
        let image = try #require(context.makeImage())
        #expect(throws: MagicWand.Failure.self) { try MaskTracing.opaquePixels(in: image, maximumEdges: 11) }
        let path = try #require(try MaskTracing.opaquePixels(in: image, maximumEdges: 12))
        #expect(path.contains(CGPoint(x: 1.5, y: 1.5)))
        #expect(!path.contains(CGPoint(x: 4, y: 4)))
        #expect(try MaskTracing.darkPixels(in: image, maximumEdges: 0) == nil)
    }
    @Test func holesSurviveTracing() throws {
        let context = try BrushRaster.context(width: 3, height: 3, mask: false)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 3, height: 3))
        context.clear(CGRect(x: 1, y: 1, width: 1, height: 1))
        let image = try #require(context.makeImage())
        let path = try #require(try MaskTracing.opaquePixels(in: image))
        #expect(path.contains(CGPoint(x: 0.5, y: 0.5)))
        #expect(!path.contains(CGPoint(x: 1.5, y: 1.5)))
    }
    @MainActor @Test func defaultBudgetFailurePreservesSelectionAndHistory() throws {
        let width = 710
        let context = try BrushRaster.context(width: width, height: width, mask: false)
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        for y in 0..<width { for x in 0..<width {
            bytes[y * context.bytesPerRow + x * 4 + 3] = (x + y).isMultiple(of: 2) ? 255 : 0
        } }
        let image = try #require(context.makeImage())
        let session = EditorSession()
        session.createDocument(width: width, height: width)
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Detailed"))
        session.applySelection(CGPath(rect: CGRect(x: 1, y: 1, width: 2, height: 2), transform: nil), mode: .replace, name: "Prior selection")
        let selected = session.selection
        let history = session.history.undoCount
        session.loadLayerSelection(layerID: try #require(session.activeLayerID))
        #expect(session.brushError != nil)
        #expect(session.selection == selected && session.history.undoCount == history)
        #expect(throws: MagicWand.Failure.self) { try MaskTracing.darkPixels(in: image, maximumEdges: 0) }
    }

}
