import AppKit
import ImageIO

/// Pixels copied from the canvas, with where they came from so Paste can put them back in place.
struct PixelClipboard {
    let image: CGImage
    let origin: CGPoint
    /// The system pasteboard's change count right after writing; a mismatch means another app copied since.
    let changeCount: Int
}

extension EditorSession {
    /// Whole-pixel bounds of what Copy takes: the selection, or the whole canvas without one.
    /// Path boolean operations leave tiny float noise (59.9999999), so round with a tolerance
    /// rather than letting it add a whole pixel.
    func selectionCopyRegion() -> CGRect? {
        guard let document else { return nil }
        let canvas = CGRect(origin: .zero, size: document.size)
        let bounds = selection?.path.boundingBoxOfPath ?? canvas
        let tolerance: CGFloat = 0.001
        let minX = floor(bounds.minX + tolerance), minY = floor(bounds.minY + tolerance)
        let region = CGRect(x: minX, y: minY, width: ceil(bounds.maxX - tolerance) - minX,
                            height: ceil(bounds.maxY - tolerance) - minY).intersection(canvas)
        guard !region.isNull, region.width >= 1, region.height >= 1 else { return nil }
        return region
    }

    var canCopyPixels: Bool {
        guard canEditLayers, let layer = activeLayer, !layer.isGroup || isMaskSelected, selection?.isEmpty != true else { return false }
        return isMaskSelected ? layer.mask != nil : layer.asset != nil
    }

    /// The active layer's pixels (or mask as opaque gray) exactly as they sit on the canvas,
    /// clipped to the selection (soft edges kept), or the whole canvas without one.
    func renderSelectedPixels(from layer: ImageLayer, mask: Bool) throws -> (image: CGImage, region: CGRect)? {
        guard let document else { return nil }
        let clip = try selection?.clip(canvas: document.size)
        if clip != nil, clip?.coverage == nil { return nil }
        guard let region = selectionCopyRegion() else { return nil }
        let context = try BrushRaster.context(width: Int(region.width), height: Int(region.height), mask: false)
        context.translateBy(x: -region.minX, y: -region.minY)
        clip?.apply(to: context)
        let transform = displayedTransform(for: layer)
        if mask, let owned = layer.mask {
            let placement = displayedMaskPlacement(for: layer)
            context.setFillColor(gray: placement == nil ? 0 : LayerMask.background(of: owned.asset.thumbnail), alpha: 1)
            context.fill(region)
            LayerRenderer.drawCoverage(owned.asset.image, transform: placement ?? transform, in: context)
        } else if !mask, let image = layer.asset?.image {
            LayerRenderer.draw(image, transform: transform, center: transform.center, in: context)
        } else { return nil }
        guard let image = context.makeImage() else { throw ExportError.render }
        return (image, region)
    }

    var canCopyMerged: Bool {
        canEditLayers && selection?.isEmpty != true && document?.renderLayers.contains { $0.asset != nil } == true
    }

    /// Shift-Cmd-C (Copy Merged): the selection across every visible layer, composited as
    /// the canvas shows it, including opacity, blend modes, and masks.
    func renderMergedPixels() throws -> (image: CGImage, region: CGRect)? {
        guard let document else { return nil }
        let clip = try selection?.clip(canvas: document.size)
        if clip != nil, clip?.coverage == nil { return nil }
        guard let region = selectionCopyRegion() else { return nil }
        // Composited on its own first, then drawn through the selection: a transparency layer would do the same,
        // but Color Burn and Color Dodge need to read what they are blending with, which a group hides.
        let composite = try BrushRaster.context(width: Int(region.width), height: Int(region.height), mask: false)
        composite.translateBy(x: -region.minX, y: -region.minY)
        drawLiveComposite(document, in: composite)
        guard let merged = composite.makeImage() else { throw ExportError.render }
        let context = try BrushRaster.context(width: Int(region.width), height: Int(region.height), mask: false)
        context.translateBy(x: -region.minX, y: -region.minY)
        clip?.apply(to: context)
        BrushRaster.draw(merged, in: region, mask: false, context: context)
        guard let image = context.makeImage() else { throw ExportError.render }
        return (image, region)
    }

    func copyMergedSelection() {
        guard canCopyMerged else { return }
        do {
            guard let copied = try renderMergedPixels() else { NSSound.beep(); return }
            store(copied)
        } catch { brushError = error.localizedDescription }
    }

    /// Cmd-C: copies the selected pixels (or the whole layer) for Paste, and to the system
    /// pasteboard as PNG for other apps.
    func copySelection() {
        guard canCopyPixels, let layer = activeLayer else { return }
        do {
            guard let copied = try renderSelectedPixels(from: layer, mask: isMaskSelected) else { NSSound.beep(); return }
            store(copied)
        } catch { brushError = error.localizedDescription }
    }

    /// Keeps pixels for Paste and puts them on the system pasteboard as PNG.
    private func store(_ copied: (image: CGImage, region: CGRect)) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let png = NSBitmapImageRep(cgImage: copied.image).representation(using: .png, properties: [:]) {
            pasteboard.setData(png, forType: .png)
        }
        pixelClipboard = PixelClipboard(image: copied.image, origin: copied.region.origin, changeCount: pasteboard.changeCount)
    }

    /// Cmd-X: copy, then clear the selected pixels.
    func cutSelection() async {
        guard selection != nil, canCopyPixels else { return }
        copySelection()
        await clearSelectedPixels()
    }

    var canPaste: Bool {
        guard document != nil, canEditLayers else { return false }
        if let pixelClipboard, NSPasteboard.general.changeCount == pixelClipboard.changeCount { return true }
        return NSPasteboard.general.availableType(from: [.png, .tiff]) != nil
    }

    /// Cmd-V: pastes as a new layer above the active one. Pixels copied here go back exactly
    /// where they came from; images copied in other apps are centered.
    func paste() {
        guard canPaste, let document else { return }
        guard document.layers.count < 10_000 else { brushError = ProjectError.tooLarge.localizedDescription; return }
        let pasteboard = NSPasteboard.general
        if let clip = pixelClipboard, pasteboard.changeCount == clip.changeCount {
            addPixelLayer(clip.image, at: clip.origin, name: nextLayerName(), editName: "Paste")
        } else {
            do {
                guard let type = pasteboard.availableType(from: [.png, .tiff]), let data = pasteboard.data(forType: type) else { NSSound.beep(); return }
                let image = try Self.decodeClipboardImage(data, remainingPixels: remainingPixelLayerBudget)
                let origin = CGPoint(x: floor((document.size.width - CGFloat(image.width)) / 2),
                                     y: floor((document.size.height - CGFloat(image.height)) / 2))
                addPixelLayer(image, at: origin, name: nextLayerName(), editName: "Paste")
            } catch { brushError = error.localizedDescription }
        }
    }

    /// Cmd-J (Layer via Copy): the selection's pixels become a new layer in place; with no
    /// selection the whole layer is duplicated.
    func layerViaCopy() {
        guard canEditLayers, let layer = activeLayer, !layer.isGroup, selection?.isEmpty != true else { return }
        guard selection != nil else { duplicateActiveLayer(); return }
        do {
            guard let copied = try renderSelectedPixels(from: layer, mask: isMaskSelected) else { NSSound.beep(); return }
            addPixelLayer(copied.image, at: copied.region.origin, name: nextLayerName(), editName: "Layer via Copy")
        } catch { brushError = error.localizedDescription }
    }

    func duplicateActiveLayer() {
        guard canEditLayers, let layer = activeLayer, !layer.isGroup,
              let index = document?.layers.firstIndex(where: { $0.id == layer.id }) else { return }
        do {
            if let image = layer.asset?.image { try admitPixelLayer(width: image.width, height: image.height) }
            else if (document?.layers.count ?? 0) >= 10_000 { throw ProjectError.tooLarge }
        } catch { brushError = error.localizedDescription; return }
        let copy = ImageLayer(id: UUID(), asset: layer.asset, name: "\(layer.name) copy", isVisible: layer.isVisible,
                              transform: layer.transform, parentID: layer.parentID, isGroup: false,
                              opacity: layer.opacity, blendMode: layer.blendMode, mask: layer.mask, maskSourceID: layer.maskSourceID, adjustment: layer.adjustment, shape: layer.shape)
        beginEdit("Duplicate Layer")
        document?.layers.insert(copy, at: index + 1)
        activeLayerID = copy.id
        endEdit()
    }

    /// Option-drag in the Layers panel: a copy of the layer placed where it was dropped (inside `parent`,
    /// above `target`, or at the very bottom), as one undo step. Folders aren't duplicated this way.
    @discardableResult
    func duplicateLayer(_ id: UUID, in parent: UUID?, above target: UUID? = nil, atBottom: Bool = false) -> Bool {
        guard canEditLayers, let layer = document?.layers.first(where: { $0.id == id }), !layer.isGroup,
              canPlaceLayer(id, in: parent) else { return false }
        beginEdit("Duplicate Layer")
        defer { endEdit() }
        selectLayer(id)
        duplicateActiveLayer()
        guard let copy = activeLayerID, copy != id else { return false }
        return placeLayer(copy, in: parent, above: target, atBottom: atBottom)
    }

    /// Inserts pixels as a new layer above the active one (inside its folder), all in one undo
    /// step. Pasting drops the selection, as in Photoshop; a drawn shape keeps it.
    func addPixelLayer(_ image: CGImage, at origin: CGPoint, name: String, editName: String, dropsSelection: Bool = true, shape: LayerShape? = nil) {
        guard let document else { return }
        do { try admitPixelLayer(width: image.width, height: image.height) }
        catch { brushError = error.localizedDescription; return }
        guard let thumbnail = try? PixelInvert.thumbnail(of: image) else { return }
        var layer = ImageLayer(asset: ImportedImage(image: image, thumbnail: thumbnail, name: name), origin: origin)
        layer.name = name
        layer.shape = shape
        layer.parentID = activeLayer?.isGroup == true ? activeLayerID : activeLayer?.parentID
        let index = document.layers.firstIndex { $0.id == activeLayerID }.map { $0 + 1 } ?? document.layers.count
        finishOpacityEdit()
        beginEdit(editName)
        self.document?.layers.insert(layer, at: index)
        if dropsSelection { self.document?.selection = nil }
        activeLayerID = layer.id
        endEdit()
    }

    func nextLayerName() -> String {
        let names = Set(document?.layers.map(\.name) ?? [])
        var number = 1
        while names.contains("Layer \(number)") { number += 1 }
        return "Layer \(number)"
    }

    var remainingPixelLayerBudget: Int {
        max(0, 100_000_000 - (document?.layers.reduce(0) { total, layer in
            total + (layer.asset.map { $0.image.width * $0.image.height } ?? 0)
        } ?? 0))
    }

    func admitPixelLayer(width: Int, height: Int) throws {
        guard let document, document.layers.count < 10_000 else { throw ProjectError.tooLarge }
        try Self.checkClipboardDimensions(width: width, height: height, remainingPixels: remainingPixelLayerBudget)
    }

    static func checkClipboardDimensions(width: Int, height: Int, remainingPixels: Int) throws {
        guard (1...30_000).contains(width), (1...30_000).contains(height),
              remainingPixels >= 0, width <= remainingPixels / height else { throw ImageImportError.tooLarge }
    }

    static func decodeClipboardImage(_ data: Data, remainingPixels: Int) throws -> CGImage {
        guard data.count <= 512 * 1024 * 1024 else { throw ImageImportError.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { throw ImageImportError.unreadable }
        try checkClipboardDimensions(width: width, height: height, remainingPixels: remainingPixels)
        // Decode one representation only, respecting EXIF orientation without an unbounded NSImage fallback.
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) else { throw ImageImportError.unreadable }
        try checkClipboardDimensions(width: image.width, height: image.height, remainingPixels: remainingPixels)
        return try sRGBCopy(of: image)
    }

    /// Normalizes an image from another app to the working sRGB RGBA format.
    private static func sRGBCopy(of image: CGImage) throws -> CGImage {
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        guard let copy = context.makeImage() else { throw ExportError.render }
        return copy
    }
}
