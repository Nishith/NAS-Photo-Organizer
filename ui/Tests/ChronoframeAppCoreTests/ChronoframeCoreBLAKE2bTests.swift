import Foundation
import XCTest
@testable import ChronoframeCore

final class ChronoframeCoreBLAKE2bTests: XCTestCase {
    func testMatchesKnownVectors() {
        XCTAssertEqual(
            BLAKE2bHasher.hashHex(of: Data()),
            "786a02f742015903c6c6fd852552d272912f4740e15847618a86e217f71f5419d25e1031afee585313896444934eb04b903a685b1448b755d56f701afe9be2ce"
        )
        XCTAssertEqual(
            BLAKE2bHasher.hashHex(of: Data("abc".utf8)),
            "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923"
        )
        XCTAssertEqual(
            BLAKE2bHasher.hashHex(of: Data("The quick brown fox jumps over the lazy dog".utf8)),
            "a8add4bdddfd93e4877d2746e62817b116364a1fa7bc148d95090bc7333b3673f82401cf7aa2e4cb1ecd90296e3f14cb5413f8ed77be73045b13914cdcd6a918"
        )
    }

    func testChunkedUpdatesMatchSinglePassHash() {
        let payload = Data(repeating: 0x61, count: 360)

        var chunked = BLAKE2bHasher()
        chunked.update(Data(payload.prefix(31)))
        chunked.update(Data(payload.dropFirst(31).prefix(211)))
        chunked.update(Data(payload.dropFirst(242)))

        XCTAssertEqual(
            chunked.finalizeHexDigest(),
            "9c9f9ca409046f87d3a4b813e2c752676504d7ddde8e64cba4fecfc5346cb039b990fe84cd26a3aae28fab6579a3e3cf83b08a786961f24514a72bcc0ee0b5a2"
        )
    }
}
