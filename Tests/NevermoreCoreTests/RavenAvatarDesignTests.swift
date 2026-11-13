import Foundation
import Testing
@testable import NevermoreCore

// Pinned expectations were generated independently with Python's `hashlib`:
// sha256(b"nevermore-raven-v1\x00" + unicodedata.normalize("NFC", name).encode("utf-8")),
// with digest bytes b0...b11 mapped exactly as documented in RavenAvatarDesign.

@Test func pinnedVectorsMatchIndependentHashlibExpectations() {
    let alice = RavenAvatarDesign(name: "Alice")
    #expect(alice.fingerprint == "39874003871a89b55e2aeb8f1a3a33e99546942dcf72cf03ea9bc7a625be21bb")
    #expect(alice.backgroundHue == 0.2247161865234375)
    #expect(alice.plumageHue == 0.6001960784313726)
    #expect(alice.crest == .spiky)
    #expect(alice.beak == .stout)
    #expect(alice.marking == .brow)
    #expect(alice.facing == .right)
    #expect(alice.headWidth == 49)
    #expect(alice.headHeight == 50)
    #expect(alice.eye == .round)
    #expect(alice.featherCount == 5)
    #expect(alice.motif == .halo)
    // Independently derived from bytes 12...14 of the same pinned digest.
    #expect(alice.silhouette == .broad)
    #expect(alice.palette == .plum)
    #expect(alice.pose == .front)

    // José (U+004A U+006F U+0073 U+00E9), precomposed.
    let jose = RavenAvatarDesign(name: "Jos\u{00E9}")
    #expect(jose.fingerprint == "fe5cf93166a71982fcb5b83c4883c6336cae4dee2166858e61c514749beaf8b8")
    #expect(jose.backgroundHue == 0.99359130859375)
    #expect(jose.plumageHue == 0.7452941176470589)
    #expect(jose.crest == .tufted)
    #expect(jose.beak == .hooked)
    #expect(jose.marking == .cheek)
    #expect(jose.facing == .right)
    #expect(jose.headWidth == 53)
    #expect(jose.headHeight == 54)
    #expect(jose.eye == .almond)
    #expect(jose.featherCount == 2)
    #expect(jose.motif == .plain)
    #expect(jose.silhouette == .round)
    #expect(jose.palette == .rust)
    #expect(jose.pose == .profile)

    // Zoë (U+005A U+006F U+00EB).
    let zoe = RavenAvatarDesign(name: "Zo\u{00EB}")
    #expect(zoe.fingerprint == "8f3992e9c4cd94e50ebfe15bbc966716cf41dfbc8ae7ece683bfc56af20c7108")
    #expect(zoe.backgroundHue == 0.5594635009765625)
    #expect(zoe.plumageHue == 0.6645098039215687)
    #expect(zoe.crest == .spiky)
    #expect(zoe.beak == .compact)
    #expect(zoe.marking == .plain)
    #expect(zoe.facing == .left)
    #expect(zoe.headWidth == 53)
    #expect(zoe.headHeight == 47)
    #expect(zoe.eye == .curious)
    #expect(zoe.featherCount == 3)
    #expect(zoe.motif == .halo)
    #expect(zoe.silhouette == .round)
    #expect(zoe.palette == .ink)
    #expect(zoe.pose == .front)

    // 🐦‍⬛: U+1F426 U+200D U+2B1B, a ZWJ emoji sequence.
    let blackBird = RavenAvatarDesign(name: "\u{1F426}\u{200D}\u{2B1B}")
    #expect(blackBird.fingerprint == "40cf8e6a8979c3b8a88102c10cb4667b4e5448d98ee0c5c47fdf0b52af3d6247")
    #expect(blackBird.backgroundHue == 0.2531585693359375)
    #expect(blackBird.plumageHue == 0.6613725490196078)
    #expect(blackBird.crest == .swept)
    #expect(blackBird.beak == .long)
    #expect(blackBird.marking == .brow)
    #expect(blackBird.facing == .right)
    #expect(blackBird.headWidth == 52)
    #expect(blackBird.headHeight == 47)
    #expect(blackBird.eye == .round)
    #expect(blackBird.featherCount == 4)
    #expect(blackBird.motif == .dots)

    let empty = RavenAvatarDesign(name: "")
    #expect(empty.fingerprint == "2d9ff109da71506a6e2b14c44d84d6a3cbef6076301f240b286f6460303ab7ad")
    #expect(empty.backgroundHue == 0.1782073974609375)
    #expect(empty.plumageHue == 0.7390196078431372)
    #expect(empty.crest == .tufted)
    #expect(empty.beak == .hooked)
    #expect(empty.marking == .bib)
    #expect(empty.facing == .left)
    #expect(empty.headWidth == 51)
    #expect(empty.headHeight == 44)
    #expect(empty.eye == .almond)
    #expect(empty.featherCount == 2)
    #expect(empty.motif == .plain)

    let nevermore = RavenAvatarDesign(name: "nevermore")
    #expect(nevermore.fingerprint == "6f31320ac1ce1ecbf46dba5c022efc324df628e80374b88e26dd1c37fba80817")
    #expect(nevermore.backgroundHue == 0.4343414306640625)
    #expect(nevermore.plumageHue == 0.5892156862745098)
    #expect(nevermore.crest == .smooth)
    #expect(nevermore.beak == .long)
    #expect(nevermore.marking == .brow)
    #expect(nevermore.facing == .left)
    #expect(nevermore.headWidth == 49)
    #expect(nevermore.headHeight == 46)
    #expect(nevermore.eye == .almond)
    #expect(nevermore.featherCount == 4)
    #expect(nevermore.motif == .plain)
}

@Test func channelSeedsMatchIndependentHashlibVectors() {
    // SHA256(b"nevermore-channel-raven-v1\\0" + utf8_byte_length(workspace)
    //        + b":" + NFC(workspace).encode() + NFC(name).encode()).
    #expect(RavenAvatarDesign(channelName: "general", workspace: "Engineering").fingerprint == "2787a47e11e16a6ae7bbce494ef0f3c3d5c2cfb47839e62f74307ef3e8074912")
    #expect(RavenAvatarDesign(channelName: "general", workspace: "").fingerprint == "da2f4b8ce1ae04bbd6146b54426a07e186c74ada6845feb9c70bfb6c5d0b7d08")
    #expect(RavenAvatarDesign(channelName: "开发", workspace: "团队").fingerprint == "b2eadd81376e859cb9246738eceb756d84517920173e4deaedf92d28e918ea06")
}

@Test func channelIdentityIsStableQualifiedAndSeparateFromPeople() {
    let channel = RavenAvatarDesign(channelName: "general", workspace: "Engineering")
    #expect(channel == RavenAvatarDesign(channelName: "general", workspace: "Engineering"))
    #expect(channel != RavenAvatarDesign(channelName: "general", workspace: "Operations"))
    #expect(channel != RavenAvatarDesign(channelName: "random", workspace: "Engineering"))
    #expect(channel != RavenAvatarDesign(name: "general"))
    #expect(RavenAvatarDesign(channelName: "Amélie", workspace: "Café") == RavenAvatarDesign(channelName: "Ame\u{301}lie", workspace: "Cafe\u{301}"))
    #expect(RavenAvatarDesign(channelName: "b:c", workspace: "a") != RavenAvatarDesign(channelName: "c", workspace: "a:b"))
    #expect(RavenAvatarDesign(channelName: "b\u{0000}c", workspace: "a") != RavenAvatarDesign(channelName: "c", workspace: "a\u{0000}b"))
}

@Test func repeatedConstructionIsDeterministic() {
    let first = RavenAvatarDesign(name: "repeat-me")
    for _ in 0..<25 {
        let again = RavenAvatarDesign(name: "repeat-me")
        #expect(again == first)
        #expect(again.fingerprint == first.fingerprint)
        #expect(again.backgroundHue == first.backgroundHue)
        #expect(again.plumageHue == first.plumageHue)
        #expect(again.crest == first.crest)
        #expect(again.beak == first.beak)
        #expect(again.marking == first.marking)
        #expect(again.facing == first.facing)
        #expect(again.headWidth == first.headWidth)
        #expect(again.headHeight == first.headHeight)
        #expect(again.eye == first.eye)
        #expect(again.featherCount == first.featherCount)
        #expect(again.motif == first.motif)
    }
}

@Test func nfcEquivalenceUnifiesCanonicallyEquivalentSpellings() {
    let precomposed = RavenAvatarDesign(name: "José")
    let decomposed = RavenAvatarDesign(name: "Jose\u{301}")
    #expect(precomposed == decomposed)
    #expect(precomposed.fingerprint == decomposed.fingerprint)
    #expect(precomposed.fingerprint == "fe5cf93166a71982fcb5b83c4883c6336cae4dee2166858e61c514749beaf8b8")

    let ring = RavenAvatarDesign(name: "Å")
    let ringDecomposed = RavenAvatarDesign(name: "A\u{30A}")
    #expect(ring == ringDecomposed)
    #expect(ring.fingerprint == ringDecomposed.fingerprint)
}

@Test func caseAndWhitespaceAreSignificant() {
    let alice = RavenAvatarDesign(name: "Alice")
    let variants = ["alice", "ALICE", "Alice ", " Alice", "Ali ce", "Al ice"]
    for variant in variants {
        let design = RavenAvatarDesign(name: variant)
        #expect(design != alice)
        #expect(design.fingerprint != alice.fingerprint)
    }
    // Every variant is a distinct seed, not just distinct from "Alice".
    #expect(Set(variants.map { RavenAvatarDesign(name: $0).fingerprint }).count == variants.count)
}

@Test func seedIsTheUsernameNotADisplayLabel() {
    // The literal string is the seed; labels like "You" are not special-cased.
    let you = RavenAvatarDesign(name: "You")
    #expect(you == RavenAvatarDesign(name: "You"))
    #expect(you.fingerprint != RavenAvatarDesign(name: "you").fingerprint)
    #expect(you.fingerprint != RavenAvatarDesign(name: "You ").fingerprint)
}

@Test func nonASCIIUsernamesAreValidSeeds() {
    for name in ["Zoë", "Renée", "日本語", "Ångström", "München"] {
        let design = RavenAvatarDesign(name: name)
        #expect(design.fingerprint.count == 64)
        #expect(design.fingerprint.allSatisfy { "0123456789abcdef".contains($0) })
        #expect(design == RavenAvatarDesign(name: name))
    }
}

@Test func emojiUsernamesAreValidSeeds() {
    let design = RavenAvatarDesign(name: "🦅")
    #expect(design.fingerprint.count == 64)
    #expect(design.fingerprint.allSatisfy { "0123456789abcdef".contains($0) })
    #expect(design == RavenAvatarDesign(name: "🦅"))
}

@Test func emptyUsernameIsValidSeed() {
    let design = RavenAvatarDesign(name: "")
    #expect(design.fingerprint.count == 64)
    #expect(design == RavenAvatarDesign(name: ""))
}

@Test func traitsStayInRangeAcrossOneThousandNames() {
    for index in 0..<1000 {
        let design = RavenAvatarDesign(name: "user-\(index)")
        #expect(design.fingerprint.count == 64)
        #expect(design.fingerprint.allSatisfy { "0123456789abcdef".contains($0) })
        #expect(design.backgroundHue >= 0)
        #expect(design.backgroundHue < 1)
        #expect(design.plumageHue >= 0.55)
        #expect(design.plumageHue <= 0.75)
        #expect(design.crest.rawValue >= 0 && design.crest.rawValue <= 4)
        #expect(design.beak.rawValue >= 0 && design.beak.rawValue <= 3)
        #expect(design.marking.rawValue >= 0 && design.marking.rawValue <= 4)
        #expect(design.facing.rawValue >= 0 && design.facing.rawValue <= 1)
        #expect(design.headWidth >= 44 && design.headWidth <= 54)
        #expect(design.headHeight >= 44 && design.headHeight <= 54)
        #expect(design.eye.rawValue >= 0 && design.eye.rawValue <= 2)
        #expect(design.featherCount >= 2 && design.featherCount <= 5)
        #expect(design.motif.rawValue >= 0 && design.motif.rawValue <= 3)
    }
}

@Test func everyDiscreteTraitVariesAcrossOneThousandNames() {
    // Demonstrates that each discrete trait is actually exercised by the frozen
    // byte mapping. It does not claim that rendered images are collision-free:
    // most digest bytes never affect the visible traits.
    var crests: Set<RavenAvatarDesign.Crest> = []
    var beaks: Set<RavenAvatarDesign.Beak> = []
    var markings: Set<RavenAvatarDesign.Marking> = []
    var facings: Set<RavenAvatarDesign.Facing> = []
    var eyes: Set<RavenAvatarDesign.Eye> = []
    var motifs: Set<RavenAvatarDesign.Motif> = []
    var silhouettes: Set<RavenAvatarDesign.Silhouette> = []
    var palettes: Set<RavenAvatarDesign.Palette> = []
    var poses: Set<RavenAvatarDesign.Pose> = []
    var featherCounts: Set<Int> = []
    for index in 0..<1000 {
        let design = RavenAvatarDesign(name: "user-\(index)")
        crests.insert(design.crest)
        beaks.insert(design.beak)
        markings.insert(design.marking)
        facings.insert(design.facing)
        eyes.insert(design.eye)
        motifs.insert(design.motif)
        silhouettes.insert(design.silhouette)
        palettes.insert(design.palette)
        poses.insert(design.pose)
        featherCounts.insert(design.featherCount)
    }
    #expect(crests == Set(RavenAvatarDesign.Crest.allCases))
    #expect(beaks == Set(RavenAvatarDesign.Beak.allCases))
    #expect(markings == Set(RavenAvatarDesign.Marking.allCases))
    #expect(facings == Set(RavenAvatarDesign.Facing.allCases))
    #expect(eyes == Set(RavenAvatarDesign.Eye.allCases))
    #expect(motifs == Set(RavenAvatarDesign.Motif.allCases))
    #expect(silhouettes == Set(RavenAvatarDesign.Silhouette.allCases))
    #expect(palettes == Set(RavenAvatarDesign.Palette.allCases))
    #expect(poses == Set(RavenAvatarDesign.Pose.allCases))
    #expect(featherCounts == Set([2, 3, 4, 5]))
}
