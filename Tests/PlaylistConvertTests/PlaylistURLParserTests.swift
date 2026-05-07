import XCTest
@testable import PlaylistConvert

final class PlaylistURLParserTests: XCTestCase {
    private let validID = "37i9dQZF1DXcBWIGoYBM5M"

    func testBareID() {
        XCTAssertEqual(PlaylistURLParser.extractID(from: validID), validID)
    }

    func testBareIDWithWhitespace() {
        XCTAssertEqual(PlaylistURLParser.extractID(from: " \(validID)\n"), validID)
    }

    func testSpotifyURI() {
        XCTAssertEqual(
            PlaylistURLParser.extractID(from: "spotify:playlist:\(validID)"),
            validID
        )
    }

    func testHTTPSURL() {
        XCTAssertEqual(
            PlaylistURLParser.extractID(from: "https://open.spotify.com/playlist/\(validID)"),
            validID
        )
    }

    func testHTTPSURLWithQuery() {
        XCTAssertEqual(
            PlaylistURLParser.extractID(from: "https://open.spotify.com/playlist/\(validID)?si=abc123"),
            validID
        )
    }

    func testHTTPSURLWithLocaleSegment() {
        XCTAssertEqual(
            PlaylistURLParser.extractID(from: "https://open.spotify.com/intl-en/playlist/\(validID)"),
            validID
        )
    }

    func testTrackURIIsRejected() {
        XCTAssertNil(PlaylistURLParser.extractID(from: "spotify:track:\(validID)"))
    }

    func testTooShortIDIsRejected() {
        XCTAssertNil(PlaylistURLParser.extractID(from: "abc123"))
    }

    func testTooLongIDIsRejected() {
        XCTAssertNil(PlaylistURLParser.extractID(from: validID + "X"))
    }

    func testNonAlphanumericIsRejected() {
        let bad = String("a".repeated(21)) + "!"
        XCTAssertNil(PlaylistURLParser.extractID(from: bad))
    }

    func testEmptyStringRejected() {
        XCTAssertNil(PlaylistURLParser.extractID(from: ""))
    }

    func testNonSpotifyHostRejected() {
        XCTAssertNil(PlaylistURLParser.extractID(from: "https://example.com/playlist/\(validID)"))
    }
}

private extension String {
    func repeated(_ n: Int) -> String { String(repeating: self, count: n) }
}
