import AppKit
import CoreImage
import Vision

nonisolated struct ObjectSelectionSettings: Equatable, Sendable {
    /// Read the visible composite rather than just the active layer.
    var sampleAllLayers = true
}

/// Selects the foreground object under a clicked point using Vision's instance mask,
/// then traces that mask into the document's normal path-based selection.
nonisolated enum ObjectSelection {
    enum Failure: LocalizedError {
        case unsupported
        case render

        var errorDescription: String? {
            switch self {
            case .unsupported: "Object Selection requires macOS 14 or later."
            case .render: "The object mask could not be rendered."
            }
        }
    }

    /// The outline, in the image's top-left pixel coordinates, of the foreground object
    /// at `point`. Nil when the point is outside the image, on background, or no object is found.
    static func select(in image: CGImage, at point: CGPoint) throws -> CGPath? {
        let width = image.width, height = image.height
        let x = Int(point.x.rounded(.down)), y = Int(point.y.rounded(.down))
        guard point.x.isFinite, point.y.isFinite, (0..<width).contains(x), (0..<height).contains(y) else { return nil }
        guard #available(macOS 14.0, *) else { throw Failure.unsupported }
        return try selectAvailable(in: image, at: point)
    }

    @available(macOS 14.0, *)
    private static func selectAvailable(in image: CGImage, at point: CGPoint) throws -> CGPath? {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        guard let observation = request.results?.first else { return nil }
        guard let instance = try instanceIndex(in: observation.instanceMask, at: point,
                                               imageSize: CGSize(width: image.width, height: image.height)),
              observation.allInstances.contains(instance) else { return nil }
        let scaled = try observation.generateScaledMaskForImage(forInstances: IndexSet(integer: instance), from: handler)
        let mask = try binaryMask(from: scaled, width: image.width, height: image.height)
        return try MagicWand.outline(of: mask, width: image.width, height: image.height)
    }

    /// Vision's low-resolution instance mask stores 0 for background and instance indices for objects.
    @available(macOS 14.0, *)
    private static func instanceIndex(in pixelBuffer: CVPixelBuffer, at point: CGPoint, imageSize: CGSize) throws -> Int? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0, imageSize.width > 0, imageSize.height > 0 else { return nil }
        let bytes = try grayscaleBytes(from: pixelBuffer, width: width, height: height, interpolation: .none)
        let x = min(width - 1, max(0, Int((point.x / imageSize.width) * CGFloat(width))))
        let y = min(height - 1, max(0, Int((point.y / imageSize.height) * CGFloat(height))))
        let value = Int(bytes[y * width + x])
        return value == 0 ? nil : value
    }

    @available(macOS 14.0, *)
    private static func binaryMask(from pixelBuffer: CVPixelBuffer, width: Int, height: Int) throws -> [UInt8] {
        let grayscale = try grayscaleBytes(from: pixelBuffer, width: width, height: height, interpolation: .high)
        return grayscale.map { $0 >= 128 ? 255 : 0 }
    }

    @available(macOS 14.0, *)
    private static func grayscaleBytes(from pixelBuffer: CVPixelBuffer, width: Int, height: Int,
                                       interpolation: CGInterpolationQuality) throws -> [UInt8] {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let renderer = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        guard let cgImage = renderer.createCGImage(image, from: image.extent) else { throw Failure.render }
        let context = try BrushRaster.context(width: width, height: height, mask: true)
        context.saveGState()
        context.interpolationQuality = interpolation
        context.setBlendMode(.copy)
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.restoreGState()
        guard let data = context.data else { throw Failure.render }
        let source = data.assumingMemoryBound(to: UInt8.self)
        var bytes = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                bytes[y * width + x] = source[y * context.bytesPerRow + x]
            }
        }
        return bytes
    }
}

private nonisolated struct ObjectSelectionJob: @unchecked Sendable {
    let image: CGImage
    let point: CGPoint
}

private nonisolated struct ObjectSelectionResult: @unchecked Sendable {
    let path: CGPath?
    let error: Error?
}

extension EditorSession {
    /// Object Selection: selects the Vision foreground instance under `point`, read from
    /// the active layer or every visible layer, combined with the current selection by `mode`.
    func selectObject(at point: CGPoint, mode: SelectionMode) async {
        guard canEditSelection, !isProjectBusy, selectionMoveOrigin == nil, let document,
              point.x >= 0, point.y >= 0, point.x < document.size.width, point.y < document.size.height,
              let sample = selectionSample(document, sampleAllLayers: objectSelectionSettings.sampleAllLayers) else { return }
        let job = ObjectSelectionJob(image: sample, point: point)
        isProjectBusy = true
        let result = await Task.detached(priority: .userInitiated) { () -> ObjectSelectionResult in
            do { return ObjectSelectionResult(path: try ObjectSelection.select(in: job.image, at: job.point), error: nil) }
            catch { return ObjectSelectionResult(path: nil, error: error) }
        }.value
        isProjectBusy = false
        if let error = result.error { brushError = error.localizedDescription; return }
        guard self.document?.id == document.id else { return }
        guard let path = result.path else {
            if mode == .replace { deselect() }
            return
        }
        if mode == .replace {
            setSelection(DocumentSelection(path: path, antialiased: selectionAntialiased), name: "Object Selection")
        } else {
            applySelection(path, mode: mode, name: "Object Selection")
        }
    }
}
