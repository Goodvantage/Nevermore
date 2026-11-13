import Testing
@testable import NevermoreCore

@Suite struct ReleaseVersionTests {

    @Test func followsOfficialSemVerPrecedenceOrdering() {
        let ordered = [
            "1.0.0-alpha",
            "1.0.0-alpha.1",
            "1.0.0-alpha.beta",
            "1.0.0-beta",
            "1.0.0-beta.2",
            "1.0.0-beta.11",
            "1.0.0-rc.1",
            "1.0.0",
        ]
        let versions = ordered.compactMap { ReleaseVersion($0) }
        #expect(versions.count == ordered.count)
        for index in 1..<versions.count {
            #expect(versions[index - 1] < versions[index])
            #expect(!(versions[index] < versions[index - 1]))
        }
        #expect(versions.sorted() == versions)
    }

    @Test func comparesNumericPrereleaseIdentifiersNumerically() throws {
        let beta2 = try #require(ReleaseVersion("1.0.0-beta.2"))
        let beta10 = try #require(ReleaseVersion("1.0.0-beta.10"))
        #expect(beta2 < beta10)
        #expect(!(beta10 < beta2))
        #expect(beta2 != beta10)
    }

    @Test func prereleaseHasLowerPrecedenceThanFinalRelease() throws {
        let beta = try #require(ReleaseVersion("1.0.0-beta"))
        let final = try #require(ReleaseVersion("1.0.0"))
        #expect(beta < final)
        #expect(!(final < beta))
    }

    @Test func comparesNumericIdentifiersBelowAlphanumericOnes() throws {
        let numeric = try #require(ReleaseVersion("1.0.0-1"))
        let alpha = try #require(ReleaseVersion("1.0.0-alpha"))
        let alphaUpper = try #require(ReleaseVersion("1.0.0-Alpha"))
        #expect(numeric < alpha)
        #expect(alphaUpper < alpha)

        let shortPrefix = try #require(ReleaseVersion("1.0.0-alpha"))
        let longPrefix = try #require(ReleaseVersion("1.0.0-alpha.1"))
        #expect(shortPrefix < longPrefix)
    }

    @Test func rejectsInvalidVersionStrings() {
        let invalid = [
            "", "1", "1.2", "1.2.3.4", "01.2.3", "1.02.3", "1.2.03",
            "1..2.3", ".1.2.3", "1.2.3.", "1.2.3/4",
            "1.2.3-", "1.2.3+", "1.2.3-.", "1.2.3+.",
            "1.2.3-01", "1.2.3-00", "1.2.3-0.01",
            "1.2.3-alpha..beta", "1.2.3-alpha.", "1.2.3+build.",
            "1.2.3-alpha_1", "1.2.3+build_1", "1.2.3+build..x",
            "1.2.3+build+more", "1.2.3-+build", "1.2.3-+",
            "v1.2.3", " 1.2.3", "1.2.3 ", "1.2.3\n", "1.2.3\t",
            "1.2.3-α", "1.2.3-ä",
        ]
        for candidate in invalid {
            #expect(ReleaseVersion(candidate) == nil)
        }
    }

    @Test func acceptsValidVersionStrings() {
        let valid = [
            "0.0.0", "1.2.3", "1.2.3-0", "1.2.3-0.1", "1.2.3-alpha",
            "1.2.3-alpha-1", "1.2.3--", "1.2.3-0a", "1.2.3-0-0",
            "1.2.3+001", "1.2.3+build-1", "1.2.3-alpha+build-1",
            "1.2.3-alpha.beta+build.001",
        ]
        for candidate in valid {
            #expect(ReleaseVersion(candidate) != nil)
        }
    }

    @Test func buildMetadataIsIgnoredByEqualityHashingAndPrecedence() throws {
        let plain = try #require(ReleaseVersion("1.0.0"))
        let first = try #require(ReleaseVersion("1.0.0+20130313144700"))
        let second = try #require(ReleaseVersion("1.0.0+exp.sha.5114f85"))
        #expect(first == second)
        #expect(first == plain)
        #expect(first.hashValue == second.hashValue)
        #expect(first.hashValue == plain.hashValue)
        #expect(!(first < second))
        #expect(!(second < first))
        #expect(first.description == "1.0.0+20130313144700")
    }

    @Test func hugeNumericFieldsCompareWithoutIntegerOverflow() throws {
        let below = try #require(ReleaseVersion("1.0.0-999999999999999999999999999999"))
        let above = try #require(ReleaseVersion("1.0.0-1000000000000000000000000000000"))
        #expect(below < above)
        #expect(!(above < below))

        let smallCore = try #require(ReleaseVersion("999999999999999999999999999999.0.0"))
        let largeCore = try #require(ReleaseVersion("1000000000000000000000000000000.0.0"))
        #expect(smallCore < largeCore)
    }

    @Test func boundsInputTo256UTF8Bytes() {
        let prefix = "1.0.0-"
        let atLimit = prefix + String(repeating: "a", count: 256 - prefix.utf8.count)
        #expect(atLimit.utf8.count == 256)
        #expect(ReleaseVersion(atLimit) != nil)

        let overLimit = prefix + String(repeating: "a", count: 257 - prefix.utf8.count)
        #expect(overLimit.utf8.count == 257)
        #expect(ReleaseVersion(overLimit) == nil)
    }

    @Test func descriptionPreservesInputAndExposesPrereleaseFlag() throws {
        let input = "2.3.4-rc.2+build.7"
        let version = try #require(ReleaseVersion(input))
        #expect(version.description == input)
        #expect(version.isPrerelease)

        let plain = try #require(ReleaseVersion("2.3.4"))
        #expect(!plain.isPrerelease)
        let built = try #require(ReleaseVersion("2.3.4+build.7"))
        #expect(!built.isPrerelease)
    }
}
