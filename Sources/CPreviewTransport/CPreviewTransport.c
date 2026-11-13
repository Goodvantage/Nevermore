#include "CPreviewTransport.h"
#include <arpa/inet.h>
#include <curl/curl.h>
#include <pthread.h>
#include <sys/socket.h>

struct Callbacks {
    NMPreviewBytes header;
    NMPreviewBytes body;
    NMPreviewSocketAllowed socket_allowed;
    void *context;
};

static pthread_once_t initialization = PTHREAD_ONCE_INIT;
static CURLcode initialization_result;

static void initialize_curl(void) {
    initialization_result = curl_global_init(CURL_GLOBAL_DEFAULT);
}

static size_t receive_header(char *bytes, size_t size, size_t count, void *raw) {
    struct Callbacks *callbacks = raw;
    if (size != 0 && count > SIZE_MAX / size) return 0;
    return callbacks->header((const uint8_t *)bytes, size * count, callbacks->context);
}

static size_t receive_body(char *bytes, size_t size, size_t count, void *raw) {
    struct Callbacks *callbacks = raw;
    if (size != 0 && count > SIZE_MAX / size) return 0;
    return callbacks->body((const uint8_t *)bytes, size * count, callbacks->context);
}

static curl_socket_t open_checked_socket(void *raw, curlsocktype purpose,
                                         struct curl_sockaddr *address) {
    struct Callbacks *callbacks = raw;
    if (purpose != CURLSOCKTYPE_IPCXN) return CURL_SOCKET_BAD;
    char numeric[INET6_ADDRSTRLEN];
    const void *source;
    uint16_t port;
    if (address->family == AF_INET) {
        const struct sockaddr_in *v4 = (const struct sockaddr_in *)&address->addr;
        source = &v4->sin_addr;
        port = ntohs(v4->sin_port);
    } else if (address->family == AF_INET6) {
        const struct sockaddr_in6 *v6 = (const struct sockaddr_in6 *)&address->addr;
        source = &v6->sin6_addr;
        port = ntohs(v6->sin6_port);
    } else {
        return CURL_SOCKET_BAD;
    }
    if (port != 443 || !inet_ntop(address->family, source, numeric, sizeof(numeric))) return CURL_SOCKET_BAD;
    if (!callbacks->socket_allowed(numeric, callbacks->context)) return CURL_SOCKET_BAD;
    return socket(address->family, address->socktype, address->protocol);
}

int nm_preview_fetch(const char *url, const char *resolve_entry,
                     const char *user_agent, const char *accept,
                     long connect_seconds, long total_seconds,
                     NMPreviewBytes header, NMPreviewBytes body,
                     NMPreviewSocketAllowed socket_allowed, void *context) {
    pthread_once(&initialization, initialize_curl);
    if (initialization_result != CURLE_OK) return (int)initialization_result;
    CURL *curl = curl_easy_init();
    if (!curl) return (int)CURLE_FAILED_INIT;
    struct curl_slist *resolve = curl_slist_append(NULL, resolve_entry);
    struct curl_slist *headers = curl_slist_append(NULL, accept);
    if (!resolve || !headers) {
        curl_slist_free_all(resolve);
        curl_slist_free_all(headers);
        curl_easy_cleanup(curl);
        return (int)CURLE_OUT_OF_MEMORY;
    }
    struct Callbacks callbacks = {header, body, socket_allowed, context};
    CURLcode result;
    // Fail closed if a system libcurl rejects any required option.
#define OPTION(key, value) do { result = curl_easy_setopt(curl, key, value); if (result != CURLE_OK) goto done; } while (0)
    OPTION(CURLOPT_URL, url);
    OPTION(CURLOPT_RESOLVE, resolve);
    OPTION(CURLOPT_PROXY, "");
    OPTION(CURLOPT_PROTOCOLS_STR, "https");
    OPTION(CURLOPT_FOLLOWLOCATION, 0L);
    OPTION(CURLOPT_NETRC, (long)CURL_NETRC_IGNORED);
    OPTION(CURLOPT_HTTPAUTH, (long)CURLAUTH_NONE);
    OPTION(CURLOPT_SSL_VERIFYPEER, 1L);
    OPTION(CURLOPT_SSL_VERIFYHOST, 2L);
    OPTION(CURLOPT_HTTP_VERSION, (long)CURL_HTTP_VERSION_1_1);
    OPTION(CURLOPT_FRESH_CONNECT, 1L);
    OPTION(CURLOPT_FORBID_REUSE, 1L);
    OPTION(CURLOPT_NOSIGNAL, 1L);
    OPTION(CURLOPT_CONNECTTIMEOUT, connect_seconds);
    OPTION(CURLOPT_TIMEOUT, total_seconds);
    OPTION(CURLOPT_LOW_SPEED_LIMIT, 1L);
    OPTION(CURLOPT_LOW_SPEED_TIME, connect_seconds);
    OPTION(CURLOPT_USERAGENT, user_agent);
    OPTION(CURLOPT_HTTPHEADER, headers);
    OPTION(CURLOPT_ACCEPT_ENCODING, "");
    OPTION(CURLOPT_HEADERFUNCTION, receive_header);
    OPTION(CURLOPT_HEADERDATA, &callbacks);
    OPTION(CURLOPT_WRITEFUNCTION, receive_body);
    OPTION(CURLOPT_WRITEDATA, &callbacks);
    OPTION(CURLOPT_OPENSOCKETFUNCTION, open_checked_socket);
    OPTION(CURLOPT_OPENSOCKETDATA, &callbacks);
    result = curl_easy_perform(curl);
#undef OPTION
 done:
    curl_easy_cleanup(curl);
    curl_slist_free_all(resolve);
    curl_slist_free_all(headers);
    return (int)result;
}
