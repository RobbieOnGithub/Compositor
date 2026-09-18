import Testing
@testable import Compositor

struct ContentFillSafetyTests {
    @Test func nativeBoundaryRejectsInvalidGeometryBeforeReadingTinyBuffers() {
        var pixel: UInt8 = 255
        var mask: UInt8 = 0
        for (w, h, stride, maskStride) in [(Int32.max, Int32.max, 4, 1), (0, 1, 4, 1), (-1, 1, 4, 1), (30_000, 30_000, 120_000, 30_000), (2, 2, 7, 2), (2, 2, 8, 1), (2, 3, Int.max, 2)] {
            #expect(content_fill(&pixel, stride, &mask, maskStride, w, h) == -1)
        }
        #expect(pixel == 255)
    }
    @Test func unselectedOpaquePixelIsPreserved() {
        var pixels: [UInt8] = [12, 34, 56, 255]
        var mask: UInt8 = 0
        let result = pixels.withUnsafeMutableBufferPointer { content_fill($0.baseAddress, 4, &mask, 1, 1, 1) }
        #expect(result == 1)
        #expect(pixels == [12, 34, 56, 255])
    }
    @Test func selectedPixelIsFilledFromOpaqueNeighbors() {
        var pixels = Array(repeating: [UInt8](arrayLiteral: 12, 34, 56, 255), count: 100).flatMap { $0 }
        var mask = [UInt8](repeating: 0, count: 100)
        mask[55] = 255
        pixels[55 * 4] = 240
        let result = pixels.withUnsafeMutableBufferPointer { p in
            mask.withUnsafeBufferPointer { m in content_fill(p.baseAddress, 40, m.baseAddress, 10, 10, 10) }
        }
        #expect(result == 1)
        #expect(Array(pixels[220..<224]) == [12, 34, 56, 255])
        #expect(Array(pixels[0..<4]) == [12, 34, 56, 255])
    }

}
