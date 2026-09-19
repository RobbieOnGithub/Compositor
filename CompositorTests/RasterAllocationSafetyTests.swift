import CoreGraphics
import Testing
@testable import Compositor

struct RasterAllocationSafetyTests {
    @Test func rejectsOversizedAndOverflowingBitmapsBeforeAllocation() {
        for (w, h) in [(30_000, 30_000), (Int.max, 2), (2, Int.max), (0, 1), (-1, 1)] {
            for mask in [true, false] {
                #expect(throws: ProjectError.self) { try BrushRaster.context(width: w, height: h, mask: mask) }
            }
        }
    }
    @Test func legitimateColorAndMaskBitmapsStillWork() throws {
        #expect(try BrushRaster.context(width: 40_000, height: 1, mask: true).width == 40_000)
        for mask in [true, false] {
            let context = try BrushRaster.context(width: 32, height: 16, mask: mask)
            #expect(context.width == 32 && context.height == 16)
            #expect(context.makeImage() != nil)
        }
    }
    @MainActor @Test func sparseCanvasRemainsEditableWithoutFullCanvasMaterialization() throws {
        let session = EditorSession()
        session.createDocument(width: 30_000, height: 30_000)
        let document = try #require(session.document)
        #expect(document.width == 30_000 && document.height == 30_000)
        #expect(session.cloneSample(document) == nil)
        let selection = DocumentSelection(path: CGPath(rect: CGRect(x: 0, y: 0, width: 30_000, height: 30_000), transform: nil))
        #expect(throws: ProjectError.self) { try selection.coverage(width: 30_000, height: 30_000) }
    }

}
