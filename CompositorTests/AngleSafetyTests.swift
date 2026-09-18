import Foundation
import Testing
@testable import Compositor

struct AngleSafetyTests {
    @Test(arguments: [1e20, -1e20, Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude, Double(Int.max)])
    func decodedAnglesHaveSafeLabels(_ angle: Double) throws {
        let data = try JSONEncoder().encode(angle)
        let decoded = try JSONDecoder().decode(Double.self, from: data)
        #expect((0...360).contains(HueBand.displayDegrees(decoded)))
        #expect((HueBand.displayDegrees(decoded) / 360 * 412).isFinite)
        #expect(!NumericLabel.whole(decoded).isEmpty)
        #expect(!NumericLabel.transform(decoded).isEmpty)
        #expect(HueBand.forward(-decoded, decoded).isFinite)
        #expect((0..<360).contains(HueBand.forward(-decoded, decoded)))
    }
    @Test func normalFormattingAndWrappedBandsRemainUnchanged() {
        #expect(NumericLabel.transform(720) == "720")
        #expect(NumericLabel.transform(-42.25) == "-42.25")
        #expect(NumericLabel.whole(359.6) == "360")
        #expect(NumericLabel.whole(.infinity) == "—")
        #expect(NumericLabel.transform(.nan) == "—")
        #expect(HueBand.displayDegrees(-15) == 345)
        #expect(HueBand.displayDegrees(375) == 15)
        #expect(HueBand.displayDegrees(360) == 360)
        #expect(HueBand.forward(345, 15) == 30)
        #expect(HueBand.forward(0, 360) == 0)
        #expect(ColorRange.reds.defaultBand.weight(of: 0) == 1)
    }
}
