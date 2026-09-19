import AppKit
import Testing
@testable import Compositor

struct HealingMemorySafetyTests {
    @Test func aggregateBudgetIncludesNativeScratchSpace() throws {
        try HealingMemory.check(width: 120, height: 80)
        try HealingMemory.check(width: 40_000, height: 10)
        try HealingMemory.check(width: 10, height: 10, maximumBytes: 3200)
        #expect(throws: ProjectError.self) { try HealingMemory.check(width: 10, height: 10, maximumBytes: 3199) }
        for (w,h) in [(10_000,10_000), (30_000,30_000), (Int.max,2), (1,0), (-1,2)] {
            #expect(throws: ProjectError.self) { try HealingMemory.check(width: w, height: h) }
        }
    }
    @MainActor @Test func strokeRejectsWorkingBuffersBeforeHealing() throws {
        let context = try BrushRaster.context(width: 32, height: 32, mask: false)
        let image = try #require(context.makeImage())
        let layer = ImageLayer(asset: ImportedImage(image: image, thumbnail: image, name: "Healing"), origin: .zero)
        let stroke = try BrushStroke(layer: layer, mask: false, settings: BrushSettings(diameter: 4, healing: true), canvas: CGSize(width: 32, height: 32), useGPU: false)
        try stroke.append(CGPoint(x: 16, y: 16))
        #expect(throws: ProjectError.self) { try stroke.heal(maximumWorkingBytes: 1) }
    }

}
