import AppKit

/// Clone Stamp's options-bar settings.
nonisolated struct CloneSettings: Equatable, Sendable {
    /// The source moves with the brush and keeps its offset between strokes; off, every stroke
    /// starts again at the source point.
    var aligned = true
    /// Copy from every visible layer as shown rather than the active layer alone.
    var sampleAllLayers = false
}

extension EditorSession {
    /// Option-click: where Clone Stamp copies from. A new source starts a new alignment.
    func setCloneSource(_ point: CGPoint) {
        guard point.x.isFinite, point.y.isFinite else { return }
        cloneSource = point
        cloneOffset = nil
    }

    /// The whole-pixel offset a stroke starting at `point` would copy with: aligned strokes keep
    /// the first stroke's; otherwise it runs from the brush to the source. Nil without a source.
    /// Shared by the stroke and the hover preview, so the preview is exactly what a click stamps.
    func cloneStrokeOffset(at point: CGPoint) -> CGSize? {
        guard let cloneSource else { return nil }
        return (cloneSettings.aligned ? cloneOffset : nil)
            ?? CGSize(width: (cloneSource.x - point.x).rounded(), height: (cloneSource.y - point.y).rounded())
    }

    /// Where the source sits for a brush at `point` (document pixels), for the canvas's
    /// crosshair: the source itself until a stroke fixes the offset.
    func cloneSamplePoint(for point: CGPoint) -> CGPoint? {
        guard let cloneSource else { return nil }
        guard let cloneOffset, cloneSettings.aligned || brushStroke != nil else { return cloneSource }
        return CGPoint(x: point.x + cloneOffset.width, y: point.y + cloneOffset.height)
    }

    /// What a stroke copies from, at document size, taken when it starts: the active layer's own
    /// pixels, or every visible layer as the canvas shows them.
    func cloneSample(_ document: CanvasDocument) -> CGImage? {
        guard let context = try? BrushRaster.context(width: document.width, height: document.height, mask: false) else { return nil }
        if cloneSettings.sampleAllLayers {
            guard drawLiveComposite(document, in: context) else { return nil }
        } else if let layer = activeLayer, let image = layer.asset?.image {
            let transform = displayedTransform(for: layer)
            LayerRenderer.draw(image, transform: transform, center: transform.center, in: context)
        }
        return context.makeImage()
    }
}
