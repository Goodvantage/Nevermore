import Testing
@testable import RavenProtocol

@Test func onlyADefinitiveRefusalProvesAMutationDidNotLand() {
    #expect(RavenError.http(403, "PermissionError").definitivelyRefusedMutation)
    #expect(RavenError.http(400, "ValidationError").definitivelyRefusedMutation)
    #expect(RavenError.invalidSite.definitivelyRefusedMutation)
    for error in [RavenError.resourceLimit(RavenError.maximumAttachmentBytes), .unauthorized, .transport, .invalidResponse,
                  .http(409, nil), .http(429, nil), .http(500, nil)] {
        #expect(!error.definitivelyRefusedMutation)
    }
}
