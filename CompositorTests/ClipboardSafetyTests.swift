import AppKit
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import Compositor

@MainActor struct ClipboardSafetyTests {
    @Test func rejectsDimensionsBeforeDecodeAndConversion() throws {
        for (w,h,budget) in [(30_001,1,100_000_000), (10_000,10_001,100_000_000), (Int.max,2,100_000_000), (10,10,99), (1,1,-1)] {
            #expect(throws: ImageImportError.self) { try EditorSession.checkClipboardDimensions(width: w, height: h, remainingPixels: budget) }
        }
        let context = try BrushRaster.context(width: 10, height: 10, mask: false)
        let image = try #require(context.makeImage())
        let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        #expect(throws: ImageImportError.self) { try EditorSession.decodeClipboardImage(data, remainingPixels: 99) }
        #expect(try EditorSession.decodeClipboardImage(data, remainingPixels: 100).width == 10)
    }
    @Test func rejectedInsertionLeavesDocumentAndUndoUntouched() throws {
        let session = EditorSession()
        session.createDocument(width: 10, height: 10)
        let context = try BrushRaster.context(width: 2, height: 2, mask: false)
        let image = try #require(context.makeImage())
        session.document?.layers = (0..<10_000).map { _ in ImageLayer(name: "Blank", blankSize: CGSize(width: 1, height: 1)) }
        let count = session.history.undoCount
        session.addPixelLayer(image, at: .zero, name: "Rejected", editName: "Paste")
        #expect(session.document?.layers.count == 10_000)
        #expect(session.history.undoCount == count)
        #expect(session.brushError != nil)
    }
    @Test func externalOrientationIsAppliedAfterMetadataAdmission() throws {
        let context = try BrushRaster.context(width: 2, height: 3, mask: false)
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let decoded = try EditorSession.decodeClipboardImage(data as Data, remainingPixels: 6)
        #expect(decoded.width == 3 && decoded.height == 2)
    }
    @Test func aggregateRejectionPreservesSelectionAndActiveLayer() throws {
        let session = EditorSession()
        session.createDocument(width: 100, height: 100)
        let context = try BrushRaster.context(width: 10_000, height: 1, mask: false)
        let image = try #require(context.makeImage())
        let asset = ImportedImage(image: image, thumbnail: image, name: "Shared")
        session.document?.layers = (0..<9999).map { _ in ImageLayer(asset: asset, origin: .zero) }
        let active = session.document?.layers.first?.id
        session.activeLayerID = active
        session.document?.selection = DocumentSelection(path: CGPath(rect: CGRect(x: 1, y: 1, width: 2, height: 2), transform: nil))
        let before = session.history.undoCount
        let candidate = try BrushRaster.context(width: 200, height: 100, mask: false)
        session.addPixelLayer(try #require(candidate.makeImage()), at: .zero, name: "Too large", editName: "Paste")
        #expect(session.document?.layers.count == 9999)
        #expect(session.activeLayerID == active && session.selection != nil)
        #expect(session.history.undoCount == before && session.brushError != nil)
        session.document?.selection = nil
        session.duplicateActiveLayer() // Fits exactly 100MP and 10,000 layers.
        #expect(session.document?.layers.count == 10_000)
        let fullHistory = session.history.undoCount
        session.layerViaCopy() // The no-selection shortcut must use the same admission.
        #expect(session.document?.layers.count == 10_000)
        #expect(session.history.undoCount == fullHistory)
    }

}
