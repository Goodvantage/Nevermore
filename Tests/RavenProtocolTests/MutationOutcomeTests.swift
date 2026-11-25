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

/// A token-endpoint server fault is not a client mistake: the grant can
/// succeed later, so a queued send must stay retryable instead of being
/// parked as rejected.
@Test func oauthServerFaultsStayRetryable() {
    #expect(!RavenError.oauth("server_error").isPermanent)
    #expect(!RavenError.oauth("temporarily_unavailable").isPermanent)
}

@Test func oauthClientFaultsRemainPermanent() {
    for code in ["invalid_grant", "invalid_client", "unauthorized_client", "access_denied"] {
        #expect(RavenError.oauth(code).isPermanent)
    }
}
