import XCTest
@testable import PlaylistConvert

final class NormalizerTests: XCTestCase {
    func testLowercases() {
        XCTAssertEqual(Normalizer.normalize("Hello"), "hello")
    }

    func testStripsDiacritics() {
        XCTAssertEqual(Normalizer.normalize("Béyoncé"), "beyonce")
    }

    func testStripsFeatParenthetical() {
        XCTAssertEqual(
            Normalizer.normalize("Stay (feat. Justin Bieber)"),
            "stay"
        )
    }

    func testStripsFtParenthetical() {
        XCTAssertEqual(
            Normalizer.normalize("Old Town Road (ft. Billy Ray Cyrus)"),
            "old town road"
        )
    }

    func testStripsRemasterParenthetical() {
        XCTAssertEqual(
            Normalizer.normalize("Hey Jude (Remastered 2009)"),
            "hey jude"
        )
    }

    func testStripsDashRemastered() {
        XCTAssertEqual(
            Normalizer.normalize("Bohemian Rhapsody - Remastered 2011"),
            "bohemian rhapsody"
        )
    }

    func testStripsDashSingleVersion() {
        XCTAssertEqual(
            Normalizer.normalize("Tear Drop - Single Version"),
            "tear drop"
        )
    }

    func testStripsLiveParenthetical() {
        XCTAssertEqual(
            Normalizer.normalize("Wonderwall (Live at Wembley)"),
            "wonderwall"
        )
    }

    func testStripsBracketed() {
        XCTAssertEqual(
            Normalizer.normalize("Song [Remix]"),
            "song"
        )
    }

    func testCollapsesWhitespace() {
        XCTAssertEqual(
            Normalizer.normalize("  Hello   World  "),
            "hello world"
        )
    }

    func testReplacesAmpersand() {
        let n = Normalizer.normalize("Salt & Pepa")
        XCTAssertEqual(n, "salt and pepa")
    }

    func testNormalizesSmartQuotes() {
        XCTAssertEqual(
            Normalizer.normalize("Don\u{2019}t Stop"),
            "don't stop"
        )
    }

    func testKeepsNonDropParenthetical() {
        // "(Reprise)" doesn't match a drop keyword — should be kept (without parens).
        let result = Normalizer.normalize("Song (Reprise)")
        XCTAssertTrue(result.contains("reprise"), "got: \(result)")
    }

    func testStripsBareFeat() {
        XCTAssertEqual(
            Normalizer.normalize("Drop It Like It's Hot feat. Pharrell"),
            "drop it like it's hot"
        )
    }

    func testStripsBareFt() {
        XCTAssertEqual(
            Normalizer.normalize("Lean On ft. MØ"),
            "lean on"
        )
    }

    func testHandlesMultipleParentheticals() {
        XCTAssertEqual(
            Normalizer.normalize("Roar (feat. Cat) (Remastered 2020)"),
            "roar"
        )
    }

    func testStripsAcoustic() {
        XCTAssertEqual(
            Normalizer.normalize("Song - Acoustic"),
            "song"
        )
    }

    func testEmptyString() {
        XCTAssertEqual(Normalizer.normalize(""), "")
    }
}

final class LevenshteinTests: XCTestCase {
    func testIdentical() {
        XCTAssertEqual(StringSimilarity.levenshtein("abc", "abc"), 0)
    }

    func testEmpty() {
        XCTAssertEqual(StringSimilarity.levenshtein("", "abc"), 3)
        XCTAssertEqual(StringSimilarity.levenshtein("abc", ""), 3)
    }

    func testSingleDiff() {
        XCTAssertEqual(StringSimilarity.levenshtein("kitten", "sitten"), 1)
    }

    func testKnownCase() {
        XCTAssertEqual(StringSimilarity.levenshtein("kitten", "sitting"), 3)
    }

    func testRatioIdentical() {
        XCTAssertEqual(StringSimilarity.ratio("abc", "abc"), 1.0, accuracy: 0.0001)
    }

    func testRatioCompletelyDifferent() {
        XCTAssertEqual(StringSimilarity.ratio("abc", "xyz"), 0.0, accuracy: 0.0001)
    }

    func testRatioBothEmpty() {
        XCTAssertEqual(StringSimilarity.ratio("", ""), 1.0, accuracy: 0.0001)
    }
}
