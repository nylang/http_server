// Copyright (c) 2026 tangxiangjiang
// SPDX-License-Identifier: MIT

#include <nghttp2/nghttp2.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

enum { MAX_FIELDS = 128, MAX_HEADER_BYTES = 32768, MAX_STREAMS = 16 };

typedef struct {
    const uint8_t *name;
    const uint8_t *value;
    int32_t name_size;
    int32_t value_size;
} h2_field;

typedef struct {
    h2_field text;
    int trailer;
} h2_header;

typedef struct {
    int32_t id;
    int received_head;
    int reset;
    int head_only;
    int expect_continue;
    uint64_t ready;
    int field_count;
    size_t header_bytes;
    h2_header headers[MAX_FIELDS];
    uint8_t *body;
    size_t used;
    size_t capacity;
    size_t sent;
} h2_stream;

typedef struct {
    nghttp2_session *session;
    int streams;
    size_t body_limit;
    int secure;
    uint64_t sequence;
    uint32_t goaway_error;
    h2_stream slots[MAX_STREAMS];
} h2_server;

static int equal(const uint8_t *bytes, size_t length, const char *value) {
    return length == strlen(value) && !memcmp(bytes, value, length);
}

static int continues(const uint8_t *bytes, size_t length) {
    static const char expected[] = "100-continue";
    if (length != sizeof(expected) - 1) return 0;
    for (size_t i = 0; i < length; ++i) {
        uint8_t ch = bytes[i];
        if (ch >= 'A' && ch <= 'Z') ch += 'a' - 'A';
        if (ch != (uint8_t)expected[i]) return 0;
    }
    return 1;
}

static void release_request(h2_stream *stream) {
    for (int i = 0; i < stream->field_count; ++i) free((void *)stream->headers[i].text.name);
    free(stream->body);
    stream->field_count = 0;
    stream->body = NULL;
    stream->used = 0;
    stream->capacity = 0;
}

static void destroy_stream(h2_stream *stream) {
    release_request(stream);
    memset(stream, 0, sizeof(*stream));
}

static int closed_stream(nghttp2_session *session, int32_t id, uint32_t error, void *opaque) {
    (void)error;
    (void)opaque;
    h2_stream *stream = nghttp2_session_get_stream_user_data(session, id);
    if (stream) destroy_stream(stream);
    return 0;
}

static int reject_stream(nghttp2_session *session, h2_stream *stream, uint32_t code) {
    if (stream->reset) return 0;
    stream->reset = 1;
    stream->ready = 0;
    return nghttp2_submit_rst_stream(session, NGHTTP2_FLAG_NONE, stream->id, code)
        ? NGHTTP2_ERR_CALLBACK_FAILURE : 0;
}

static int begin_headers(nghttp2_session *session, const nghttp2_frame *frame, void *opaque) {
    h2_server *server = opaque;
    if (frame->headers.cat != NGHTTP2_HCAT_REQUEST) return 0;
    for (int i = 0; i < server->streams; ++i) {
        h2_stream *stream = &server->slots[i];
        if (stream->id == 0) {
            stream->id = frame->hd.stream_id;
            if (nghttp2_session_set_stream_user_data(session, stream->id, stream))
                return NGHTTP2_ERR_CALLBACK_FAILURE;
            return 0;
        }
    }
    return nghttp2_submit_rst_stream(session, NGHTTP2_FLAG_NONE, frame->hd.stream_id, NGHTTP2_REFUSED_STREAM)
        ? NGHTTP2_ERR_CALLBACK_FAILURE : 0;
}

static int receive_header(nghttp2_session *session, const nghttp2_frame *frame,
                           const uint8_t *name, size_t name_size, const uint8_t *value,
                           size_t value_size, uint8_t flags, void *opaque) {
    (void)flags;
    h2_server *server = opaque;
    h2_stream *stream = nghttp2_session_get_stream_user_data(session, frame->hd.stream_id);
    if (!stream || stream->reset) return 0;
    if (stream->field_count == MAX_FIELDS || name_size > MAX_HEADER_BYTES || value_size > MAX_HEADER_BYTES ||
        name_size + value_size + 32 > MAX_HEADER_BYTES - stream->header_bytes)
        return reject_stream(session, stream, NGHTTP2_ENHANCE_YOUR_CALM);

    if (equal(name, name_size, ":method")) {
        if (equal(value, value_size, "CONNECT"))
            return reject_stream(session, stream, NGHTTP2_REFUSED_STREAM);
        stream->head_only = equal(value, value_size, "HEAD");
    } else if (equal(name, name_size, ":scheme") &&
               !equal(value, value_size, server->secure ? "https" : "http")) {
        return reject_stream(session, stream, NGHTTP2_PROTOCOL_ERROR);
    } else if (!stream->received_head && equal(name, name_size, "expect")) {
        if (stream->expect_continue || !continues(value, value_size))
            return reject_stream(session, stream, NGHTTP2_REFUSED_STREAM);
        stream->expect_continue = 1;
    }

    uint8_t *bytes = malloc(name_size + value_size);
    if (!bytes) return NGHTTP2_ERR_CALLBACK_FAILURE;
    memcpy(bytes, name, name_size);
    if (value_size) memcpy(bytes + name_size, value, value_size);
    stream->headers[stream->field_count++] = (h2_header){
        {bytes, bytes + name_size, (int32_t)name_size, (int32_t)value_size}, stream->received_head
    };
    stream->header_bytes += name_size + value_size + 32;
    return 0;
}

static int receive_frame(nghttp2_session *session, const nghttp2_frame *frame, void *opaque) {
    h2_server *server = opaque;
    if (frame->hd.type != NGHTTP2_HEADERS && frame->hd.type != NGHTTP2_DATA) return 0;
    h2_stream *stream = nghttp2_session_get_stream_user_data(session, frame->hd.stream_id);
    if (!stream || stream->reset) return 0;
    if (frame->hd.type == NGHTTP2_HEADERS && !stream->received_head) {
        stream->received_head = 1;
        if (stream->expect_continue && !(frame->hd.flags & NGHTTP2_FLAG_END_STREAM)) {
            nghttp2_nv interim = {(uint8_t *)":status", (uint8_t *)"100", 7, 3, NGHTTP2_NV_FLAG_NONE};
            if (nghttp2_submit_headers(session, NGHTTP2_FLAG_NONE, stream->id, NULL, &interim, 1, NULL))
                return NGHTTP2_ERR_CALLBACK_FAILURE;
        }
    }
    if (frame->hd.flags & NGHTTP2_FLAG_END_STREAM) stream->ready = ++server->sequence;
    return 0;
}

static int sent_frame(nghttp2_session *session, const nghttp2_frame *frame, void *opaque) {
    (void)session;
    h2_server *server = opaque;
    if (frame->hd.type == NGHTTP2_GOAWAY) server->goaway_error = frame->goaway.error_code;
    return 0;
}

static int receive_data(nghttp2_session *session, uint8_t flags, int32_t id,
                        const uint8_t *bytes, size_t length, void *opaque) {
    (void)flags;
    h2_server *server = opaque;
    h2_stream *stream = nghttp2_session_get_stream_user_data(session, id);
    if (!stream || stream->reset || length == 0) return 0;
    if (length > server->body_limit - stream->used)
        return reject_stream(session, stream, NGHTTP2_ENHANCE_YOUR_CALM);

    size_t needed = stream->used + length;
    if (needed > stream->capacity) {
        size_t capacity = stream->capacity ? stream->capacity * 2 : 4096;
        if (capacity < needed) capacity = needed;
        if (capacity > server->body_limit) capacity = server->body_limit;
        uint8_t *memory = realloc(stream->body, capacity);
        if (!memory) return NGHTTP2_ERR_CALLBACK_FAILURE;
        stream->body = memory;
        stream->capacity = capacity;
    }
    memcpy(stream->body + stream->used, bytes, length);
    stream->used = needed;
    return 0;
}

static void drop(h2_server *server) {
    if (!server) return;
    if (server->session) nghttp2_session_del(server->session);
    for (int i = 0; i < server->streams; ++i) destroy_stream(&server->slots[i]);
    free(server);
}

static h2_server *create(int32_t slots, int32_t limit, int32_t secure) {
    if (slots <= 0 || slots > MAX_STREAMS || limit <= 0 || limit > 16777216) return NULL;
    h2_server *server = calloc(1, sizeof(*server));
    if (!server) return NULL;
    server->streams = slots;
    server->body_limit = (size_t)limit;
    server->secure = secure;
    nghttp2_session_callbacks *callbacks = NULL;
    nghttp2_option *options = NULL;
    int status = -1;
    if (nghttp2_session_callbacks_new(&callbacks) || nghttp2_option_new(&options)) goto done;
    nghttp2_session_callbacks_set_on_begin_headers_callback(callbacks, begin_headers);
    nghttp2_session_callbacks_set_on_header_callback(callbacks, receive_header);
    nghttp2_session_callbacks_set_on_frame_recv_callback(callbacks, receive_frame);
    nghttp2_session_callbacks_set_on_frame_send_callback(callbacks, sent_frame);
    nghttp2_session_callbacks_set_on_data_chunk_recv_callback(callbacks, receive_data);
    nghttp2_session_callbacks_set_on_stream_close_callback(callbacks, closed_stream);
    nghttp2_option_set_max_settings(options, 32);
    nghttp2_option_set_max_outbound_ack(options, 64);
    nghttp2_option_set_max_continuations(options, 16);
    if (nghttp2_session_server_new2(&server->session, callbacks, server, options)) goto done;
    nghttp2_settings_entry settings[] = {
        {NGHTTP2_SETTINGS_MAX_CONCURRENT_STREAMS, (uint32_t)slots},
        {NGHTTP2_SETTINGS_MAX_HEADER_LIST_SIZE, MAX_HEADER_BYTES}
    };
    status = nghttp2_submit_settings(server->session, NGHTTP2_FLAG_NONE, settings, 2);
done:
    if (callbacks) nghttp2_session_callbacks_del(callbacks);
    if (options) nghttp2_option_del(options);
    if (status == 0) return server;
    drop(server);
    return NULL;
}

static intptr_t output(h2_server *server, const uint8_t **bytes) {
    return nghttp2_session_mem_send2(server->session, bytes);
}

static intptr_t input(h2_server *server, const uint8_t *bytes, intptr_t size) {
    return nghttp2_session_mem_recv2(server->session, bytes, (size_t)size);
}

static int32_t state(h2_server *server) {
    if (server->goaway_error) return -1;
    return nghttp2_session_want_read(server->session);
}

static int32_t pending(h2_server *server) {
    for (int i = 0; i < server->streams; ++i)
        if (server->slots[i].id != 0 && !server->slots[i].reset) return 1;
    return 0;
}

static int32_t next(h2_server *server, const uint8_t **body, int32_t *length, int32_t *count) {
    h2_stream *ready = NULL;
    for (int i = 0; i < server->streams; ++i) {
        h2_stream *stream = &server->slots[i];
        if (stream->ready && (!ready || stream->ready < ready->ready)) ready = stream;
    }
    if (!ready) return 0;
    *body = ready->body;
    *length = (int32_t)ready->used;
    *count = ready->field_count;
    return ready->id;
}

static int32_t field(h2_server *server, int32_t id, int32_t index, h2_field *value) {
    h2_stream *stream = nghttp2_session_get_stream_user_data(server->session, id);
    if (!stream || index < 0 || index >= stream->field_count) return -1;
    *value = stream->headers[index].text;
    return stream->headers[index].trailer;
}

static nghttp2_ssize response_data(nghttp2_session *session, int32_t id, uint8_t *output_bytes,
                                  size_t capacity, uint32_t *flags, nghttp2_data_source *source, void *opaque) {
    (void)session; (void)id; (void)opaque;
    h2_stream *stream = source->ptr;
    size_t count = stream->used - stream->sent;
    if (count > capacity) count = capacity;
    if (count) memcpy(output_bytes, stream->body + stream->sent, count);
    stream->sent += count;
    if (stream->sent == stream->used) *flags |= NGHTTP2_DATA_FLAG_EOF;
    return (nghttp2_ssize)count;
}

static int32_t reset(h2_server *server, int32_t id) {
    h2_stream *stream = nghttp2_session_get_stream_user_data(server->session, id);
    return stream ? reject_stream(server->session, stream, NGHTTP2_INTERNAL_ERROR) : 0;
}

static int32_t respond(h2_server *server, int32_t id, int32_t status, const h2_field *headers,
                       int32_t count, const uint8_t *data, int32_t size) {
    h2_stream *stream = nghttp2_session_get_stream_user_data(server->session, id);
    if (!stream || !stream->ready) return -1;
    if (status < 200 || status > 599 || count < 0 || count >= MAX_FIELDS ||
        size < 0 || (size_t)size > server->body_limit ||
        (size && (stream->head_only || status == 204 || status == 205 || status == 304))) return -2;
    uint8_t status_text[] = {(uint8_t)('0' + status / 100), (uint8_t)('0' + status / 10 % 10),
                             (uint8_t)('0' + status % 10)};
    nghttp2_nv wire[MAX_FIELDS] = {{(uint8_t *)":status", status_text, 7, 3, NGHTTP2_NV_FLAG_NONE}};
    size_t total = 42;
    for (int i = 0; i < count; ++i) {
        const h2_field *h = &headers[i];
        if (h->name_size <= 0 || h->value_size < 0 || h->name_size > MAX_HEADER_BYTES ||
            h->value_size > MAX_HEADER_BYTES) return -2;
        size_t name_size = (size_t)h->name_size, value_size = (size_t)h->value_size;
        const uint8_t *value = value_size ? h->value : (const uint8_t *)"";
        total += name_size + value_size + 32;
        if (total > MAX_HEADER_BYTES || h->name[0] == ':' || !nghttp2_check_header_name(h->name, name_size) ||
            !nghttp2_check_header_value_rfc9113(value, value_size) ||
            equal(h->name, name_size, "connection") || equal(h->name, name_size, "upgrade") ||
            equal(h->name, name_size, "transfer-encoding") || equal(h->name, name_size, "keep-alive") ||
            equal(h->name, name_size, "proxy-connection") || equal(h->name, name_size, "content-length") ||
            equal(h->name, name_size, "te")) return -2;
        uint8_t flags = equal(h->name, name_size, "set-cookie") ? NGHTTP2_NV_FLAG_NO_INDEX : NGHTTP2_NV_FLAG_NONE;
        wire[i + 1] = (nghttp2_nv){(uint8_t *)h->name, (uint8_t *)value, name_size, value_size, flags};
    }
    release_request(stream);
    stream->ready = 0;
    if (size) {
        stream->body = malloc((size_t)size);
        if (!stream->body) return -1;
        memcpy(stream->body, data, (size_t)size);
        stream->used = (size_t)size;
    }
    nghttp2_data_provider2 provider = {{.ptr = stream}, response_data};
    return nghttp2_submit_response2(server->session, id, wire, (size_t)count + 1, size ? &provider : NULL);
}

typedef struct {
    h2_server *(*create)(int32_t, int32_t, int32_t);
    void (*drop)(h2_server *);
    intptr_t (*output)(h2_server *, const uint8_t **);
    intptr_t (*input)(h2_server *, const uint8_t *, intptr_t);
    int32_t (*state)(h2_server *);
    int32_t (*pending)(h2_server *);
    int32_t (*next)(h2_server *, const uint8_t **, int32_t *, int32_t *);
    int32_t (*field)(h2_server *, int32_t, int32_t, h2_field *);
    int32_t (*respond)(h2_server *, int32_t, int32_t, const h2_field *, int32_t, const uint8_t *, int32_t);
    int32_t (*reset)(h2_server *, int32_t);
} h2_server_api;

#ifdef _WIN32
__declspec(dllexport)
#else
__attribute__((visibility("default")))
#endif
int32_t nyra_http2_server_provider(int32_t version, h2_server_api *api) {
    if (version != 1 || !api) return 0;
    *api = (h2_server_api){create, drop, output, input, state, pending, next, field, respond, reset};
    return 1;
}
