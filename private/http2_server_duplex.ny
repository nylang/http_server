// Copyright (c) 2026 tangxiangjiang
// SPDX-License-Identifier: MIT

part of Http2ServerDriver;

// Owns the handler for a connection. Native callbacks borrow the context
// until explicit provider close and own the HTTP/2 stream state.
struct Http2DuplexCallbackState {
  handler: Http2DuplexHandler;
  api: Http2DuplexProviderApi;
}

pub static method(Http2Server) ServeDuplexTcp(
  connection: ref mut TcpConnection, provider_file: ref string, handler: Http2DuplexHandler,
  limits: ref Http2Limits, options: ref NetOperationOptions
) -> Result<Unit, Http2Error> {
  let adapter = HttpServerTcp{connection: move(connection)};
  return Http2Server.ServeDuplexTransport(move(adapter), false, provider_file, move(handler), limits, options);
}

pub static method(Http2Server) ServeDuplexTransport(
  transport: WebSocketTransport, secure: bool, provider_file: ref string, handler: Http2DuplexHandler,
  limits: ref Http2Limits, options: ref NetOperationOptions
) -> Result<Unit, Http2Error> {
  if provider_file.length == 0 || !limits.IsValid() {
    transport.Abort();
    return Http2Error{kind: Http2ErrorKind.InvalidArgument};
  }

  var state = Http2DuplexCallbackState{handler: move(handler)};
  let callbacks = Http2DuplexCallbacks{
    head: nyra_http2_duplex_head as Http2StreamHeadCallback,
    data: nyra_http2_duplex_data as Http2DuplexDataCallback,
    end: nyra_http2_duplex_end as Http2StreamHeadCallback,
    closed: nyra_http2_duplex_closed as Http2StreamClosedCallback,
    produce: nyra_http2_duplex_produce as Http2DuplexProduceCallback
  };
  let context = (&mut state) as *mut void;
  var opened = Http2ServerProvider.OpenDuplex(provider_file, limits, secure, callbacks, context, state.api);
  if opened.IsErr() {
    transport.Abort();
    return opened.get_if<Http2Error>() as Http2Error;
  }

  var session = Http2ServerSession{
    provider: move(opened.get_if<Http2ServerProvider>() as Http2ServerProvider), transport: move(transport), options: options
  };
  let served = session.RunStreaming();
  session.provider.Close();
  session.transport.Abort();
  return served;
}

@extern("C") func nyra_http2_duplex_head(context: *mut void, session: *mut int8, id: int32, count: int32) -> int32 {
  unsafe {
    let state = context as *mut Http2DuplexCallbackState;
    let request = Http2StreamRequest.Read((*state).api.core, session, id, count);
    if request.IsErr() {
      return -1;
    }

    let action = (*state).handler.OnHead(request.get_if<Http2StreamRequest>() as Http2StreamRequest);
    return (*state).Apply(session, id, action);
  }
}

@extern("C") func nyra_http2_duplex_data(
  context: *mut void, session: *mut int8, id: int32, bytes: *const uint8, size: int32
) -> int32 {
  let admitted = NetBytes.FromRaw(bytes, size as intptr);
  if admitted.IsErr() {
    return -1;
  }

  unsafe {
    let state = context as *mut Http2DuplexCallbackState;
    let action = (*state).handler.OnData(id, admitted.get_if<NetBytes>() as NetBytes);
    return (*state).Apply(session, id, action);
  }
}

@extern("C") func nyra_http2_duplex_end(context: *mut void, session: *mut int8, id: int32, count: int32) -> int32 {
  unsafe {
    let state = context as *mut Http2DuplexCallbackState;
    let trailers = Http2WireFields.ReadTrailers((*state).api.core, session, id, count);
    if trailers.IsErr() {
      return -1;
    }

    let action = (*state).handler.OnEnd(id, trailers.get_if<Array<HttpField>>() as Array<HttpField>);
    return (*state).Apply(session, id, action);
  }
}

@extern("C") func nyra_http2_duplex_closed(context: *mut void, id: int32, code: uint32) -> void {
  unsafe {
    let state = context as *mut Http2DuplexCallbackState;
    (*state).handler.OnClose(id, code);
  }
}

@extern("C") func nyra_http2_duplex_produce(
  context: *mut void, id: int32, bytes: *mut uint8, size: int32, end: *mut int32
) -> int32 {
  let admitted = NetMutableBytes.FromRaw(bytes, size as intptr);
  if admitted.IsErr() {
    return -1;
  }

  unsafe {
    let state = context as *mut Http2DuplexCallbackState;
    let result = (*state).handler.Produce(id, admitted.get_if<NetMutableBytes>() as NetMutableBytes);
    if result.IsErr() {
      return -1;
    }

    let chunk = result.get_if<Http2DuplexChunk>() as Http2DuplexChunk;
    *end = chunk.end ? 1 : 0;
    return chunk.written;
  }
}

method(Http2DuplexCallbackState) Apply(
  session: *mut int8, id: int32, result: Result<Http2DuplexAction, Http2Error>
) -> int32 {
  if result.IsErr() {
    return -1;
  }

  let action = result.get_if<Http2DuplexAction>() as Http2DuplexAction;
  if action.response == nil {
    return 0;
  }

  return (action.response as Http2StreamResponse).Submit(self.api.respond, session, id);
}
