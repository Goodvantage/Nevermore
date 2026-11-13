#ifndef NEVERMORE_PREVIEW_TRANSPORT_H
#define NEVERMORE_PREVIEW_TRANSPORT_H

#include <stddef.h>
#include <stdint.h>

/// Callbacks run synchronously on the thread calling nm_preview_fetch.
/// Returning fewer than count bytes stops the transfer.
typedef size_t (*NMPreviewBytes)(const uint8_t *bytes, size_t count, void *context);
/// Reject a socket before it is opened. address is a numeric IPv4/IPv6 string.
typedef int (*NMPreviewSocketAllowed)(const char *address, void *context);

/// A single HTTPS GET using macOS's system libcurl. resolve_entry is a
/// host:443:address[,address] entry, not an instruction to resolve again.
/// No proxies, redirects, credentials, cookies or connection reuse.
int nm_preview_fetch(const char *url, const char *resolve_entry,
                     const char *user_agent, const char *accept,
                     long connect_seconds, long total_seconds,
                     NMPreviewBytes header, NMPreviewBytes body,
                     NMPreviewSocketAllowed socket_allowed, void *context);

#endif
