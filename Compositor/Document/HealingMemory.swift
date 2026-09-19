import Foundation

nonisolated enum HealingMemory {
    // Includes RGBA/gray contexts, native 18-byte scratch pixels, output image and row overhead.
    static let maximumBytes = 512 * 1024 * 1024
    static func check(width: Int, height: Int, maximumBytes: Int = maximumBytes) throws {
        guard width > 0, height > 0, maximumBytes >= 0,
              width <= maximumBytes / 32 / height else { throw ProjectError.tooLarge }
    }
}
