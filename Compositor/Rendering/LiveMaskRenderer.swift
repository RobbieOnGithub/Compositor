import Foundation
import CoreGraphics
import CoreImage

/// Per-render dependency cache. Coverage uses source alpha including its own masks,
/// independent of source visibility and color. Only the current clipped region is allocated.
nonisolated final class LiveMaskRenderer {
    let bounds: CGRect
    let source: (UUID) -> UUID?
    let drawOwn: (UUID, CGContext) -> Void
    private let maximumWorkingBytes: Int
    private var workingBytes = 0
    private var cachedBytes = 0
    private(set) var failed = false

    /// Temporary reservations are released; cached masks stay charged until this render ends.
    private func reserve(bytesPerPixel: Int) -> Int? {
        guard !failed, bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0, bounds.width <= 30_000, bounds.height <= 30_000,
              maximumWorkingBytes >= workingBytes + cachedBytes else { failed = true; return nil }
        let width = Int(bounds.width), height = Int(bounds.height)
        let remaining = maximumWorkingBytes - workingBytes - cachedBytes
        guard width <= remaining / bytesPerPixel / height else { failed = true; return nil }
        let charge = width * height * bytesPerPixel
        workingBytes += charge
        return charge
    }

    var makeContext: (Int, Int, Bool) throws -> CGContext = { try BrushRaster.context(width: $0, height: $1, mask: $2) }

    private var cache: [UUID: CGImage] = [:]
    private var visiting = Set<UUID>()
    private var stacks: [UUID: [UUID]] = [:]
    private var stacked = Set<UUID>()
    private var stackModes: [UUID: CGBlendMode] = [:]
    private var blendMode: (UUID) -> LayerBlendMode = { _ in .normal }
    var adjustment: (UUID) -> LayerAdjustment? = { _ in nil }
    var adjustmentOpacity: (UUID) -> Double = { _ in 1 }
    var adjustmentClip: (UUID, CGContext) -> Void = { _, _ in }
    private func adjust(_ id: UUID, in context: CGContext) {
        guard adjustment(id) != nil else { return }
        guard let charge = reserve(bytesPerPixel: 32) else { return }
        defer { workingBytes -= charge }
        guard let settings = adjustment(id), let original = context.makeImage(),
              var adjusted = try? settings.apply(original, region: bounds) else { failed = true; return }
        if blendMode(id) != .normal {
            // Blend colors at full coverage, then restore the original alpha.
            // Source-over of two translucent copies would thicken soft edges.
            let w = original.width, h = original.height
            guard let base = try? makeContext(w, h, false),
                  let top = try? makeContext(w, h, false),
                  let alpha = try? makeContext(w, h, true) else { failed = true; return }
            let rect = CGRect(x: 0, y: 0, width: w, height: h)
            BrushRaster.draw(original, in: rect, mask: false, context: base)
            BrushRaster.draw(adjusted, in: rect, mask: false, context: top)
            let pixels = base.data!.assumingMemoryBound(to: UInt8.self)
            let coverage = alpha.data!.assumingMemoryBound(to: UInt8.self)
            layer_extract_alpha(pixels, base.bytesPerRow, coverage, alpha.bytesPerRow, w, h)
            layer_unpremultiply_opaque(pixels, base.bytesPerRow, w, h)
            layer_unpremultiply_opaque(top.data!.assumingMemoryBound(to: UInt8.self), top.bytesPerRow, w, h)
            guard let foreground = top.makeImage() else { failed = true; return }
            base.setBlendMode(blendMode(id).cgMode)
            base.translateBy(x: 0, y: CGFloat(h)); base.scaleBy(x: 1, y: -1)
            base.draw(foreground, in: rect)
            layer_restore_alpha(pixels, base.bytesPerRow, coverage, alpha.bytesPerRow, w, h)
            guard let result = base.makeImage() else { failed = true; return }
            adjusted = result
        }
        let opacity = adjustmentOpacity(id)
        let image: CGImage
        if opacity < 1 {
            let blend = CIImage(cgImage: adjusted).applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage(cgImage: original),
                kCIInputMaskImageKey: CIImage(color: CIColor(red: opacity, green: opacity, blue: opacity)).cropped(to: CIImage(cgImage: original).extent)])
            guard let result = try? PixelAdjust.render(blend, width: original.width, height: original.height, isMask: false) else { failed = true; return }
            image = result
        } else { image = adjusted }
        context.saveGState()
        adjustmentClip(id, context)
        BrushRaster.draw(image, in: bounds, mask: false, context: context)
        context.restoreGState()
    }
    /// Clipping stacks share the base's alpha instead of painting that
    /// alpha over itself. Other dependency links retain independent-mask behavior.
    func prepareStacks(_ ids: [UUID], parent: (UUID) -> UUID?, blend: (UUID) -> LayerBlendMode) {
        let modes = Dictionary(uniqueKeysWithValues: ids.map { ($0, blend($0)) })
        blendMode = { modes[$0] ?? .normal }
        for (index, base) in ids.enumerated() where source(base) == nil && adjustment(base) == nil {
            var children: [UUID] = []
            for child in ids.dropFirst(index + 1) {
                guard source(child) == base, parent(child) == parent(base) else { break }
                children.append(child)
            }
            guard !children.isEmpty else { continue }
            stacks[base] = children
            stackModes[base] = blend(base).cgMode
            stacked.formUnion(children)
        }
    }
    func drawComposite(_ id: UUID, in context: CGContext) {
        guard !failed else { return }
        guard !stacked.contains(id) else { return }
        if adjustment(id) != nil {
            if source(id) == nil { adjust(id, in: context) }
            return
        }
        guard let children = stacks[id] else { draw(id, in: context); return }
        guard let charge = reserve(bytesPerPixel: 10) else { return }
        defer { workingBytes -= charge }
        guard bounds.width > 0, bounds.height > 0,
              bounds.width * bounds.height <= 100_000_000,
              let group = try? makeContext(Int(bounds.width), Int(bounds.height), false),
              let alpha = try? makeContext(Int(bounds.width), Int(bounds.height), true) else {
            failed = true; return
        }
        group.translateBy(x: -bounds.minX, y: -bounds.minY)
        drawOwn(id, group)
        let pixels = group.data!.assumingMemoryBound(to: UInt8.self)
        let coverage = alpha.data!.assumingMemoryBound(to: UInt8.self)
        let w = Int(bounds.width), h = Int(bounds.height)
        layer_extract_alpha(pixels, group.bytesPerRow, coverage, alpha.bytesPerRow, w, h)
        layer_unpremultiply_opaque(pixels, group.bytesPerRow, w, h)
        for child in children {
            if adjustment(child) != nil { adjust(child, in: group) }
            else { drawOwn(child, group) }
        }
        layer_restore_alpha(pixels, group.bytesPerRow, coverage, alpha.bytesPerRow, w, h)
        guard !failed else { return }
        guard let image = group.makeImage() else { failed = true; return }
        do {
            context.saveGState()
            context.setBlendMode(stackModes[id] ?? .normal)
            context.translateBy(x: bounds.minX, y: bounds.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(origin: .zero, size: bounds.size))
            context.restoreGState()
        }
    }
    init(bounds: CGRect, source: @escaping (UUID) -> UUID?, maximumWorkingBytes: Int = 1024 * 1024 * 1024, drawOwn: @escaping (UUID, CGContext) -> Void) {
        self.bounds = bounds.integral; self.source = source; self.drawOwn = drawOwn
        self.maximumWorkingBytes = maximumWorkingBytes
    }
    func draw(_ id: UUID, in context: CGContext) {
        guard !failed else { return }
        context.saveGState()
        defer { context.restoreGState() }
        if let sourceID = source(id) {
            guard let coverage = coverage(sourceID) else { return }
            // CGImage rows are top-down; CGContext image clipping is bottom-up.
            context.translateBy(x: 0, y: bounds.minY * 2 + bounds.height)
            context.scaleBy(x: 1, y: -1)
            context.clip(to: bounds, mask: coverage)
            context.scaleBy(x: 1, y: -1)
            context.translateBy(x: 0, y: -(bounds.minY * 2 + bounds.height))
        }
        drawOwn(id, context)
    }
    private func coverage(_ id: UUID) -> CGImage? {
        if let image = cache[id] { return image }
        guard !visiting.contains(id), visiting.count < 256, bounds.width > 0, bounds.height > 0,
              bounds.width * bounds.height <= 100_000_000 else { failed = true; return nil }
        guard let charge = reserve(bytesPerPixel: 6) else { return nil }
        defer { workingBytes -= charge }
        visiting.insert(id); defer { visiting.remove(id) }
        let w = Int(bounds.width), h = Int(bounds.height)
        guard let pixels = try? makeContext(w, h, false),
              let gray = try? makeContext(w, h, true) else { failed = true; return nil }
        pixels.translateBy(x: -bounds.minX, y: -bounds.minY)
        draw(id, in: pixels)
        guard !failed else { return nil }
        let rgba = pixels.data!.assumingMemoryBound(to: UInt8.self)
        let alpha = gray.data!.assumingMemoryBound(to: UInt8.self)
        layer_extract_alpha(rgba, pixels.bytesPerRow, alpha, gray.bytesPerRow, w, h)
        guard let image = gray.makeImage() else { failed = true; return nil }
        cache[id] = image
        cachedBytes += w * h
        return image
    }
}
