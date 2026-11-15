// Copyright (c) 2026 tangxiangjiang
// SPDX-License-Identifier: MIT

part of Http2ServerDriver;

// The native provider borrows this context throughout its lifetime. It
// invokes the callbacks from the connection pump and during explicit close.
struct Http2StreamCallbackState {
  handler: Http2StreamHandler;
  api: Http2StreamingProviderApi;
}

pub static method(Http2Server) ServeStreamingTcp(
  connection: ref mut TcpConnection, provider_file: ref string, handler: Http2StreamHandler,
  limits: ref Http2Limits, options: ref NetOperationOptions
) -> Result<Unit, Http2Error> {
  let adapter = HttpServerTcp{connection: move(connection)};
  return Http2Server.ServeStreamingTransport(move(adapter), false, provider_file, move(handler), limits, options);
}

pub static method(Http2Server) ServeStreamingTransport(
  transport: WebSocketTransport, secure: bool, provider_file: ref string, handler: Http2StreamHandler,
  limits: ref Http2Limits, options: ref NetOperationOptions
) -> Result<Unit, Http2Error> {
  if provider_file.length == 0 || !limits.IsValid() {
    transport.Abort();
    return Http2Error{kind: Http2ErrorKind.InvalidArgument};
  }

  var state = Http2StreamCallbackState{handler: move(handler)};
  let callbacks = Http2StreamCallbacks{
    head: nyra_http2_stream_head as Http2StreamHeadCallback,
    data: nyra_http2_stream_data as Http2StreamDataCallback,
    end: nyra_http2_stream_end as Http2StreamHeadCallback,
    closed: nyra_http2_stream_closed as Http2StreamClosedCallback,
    produce: nyra_http2_stream_produce as Http2StreamProduceCallback
  };
  let context = (&mut state) as *mut void;
  var opened = Http2ServerProvider.OpenStreaming(provider_file, limits, secure, callbacks, context, state.api);
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

method(Http2ServerSession) RunStreaming() -> Result<Unit, Http2Error> {
  var scratch: <uint8>[16384] = <uint8>[16384]{};
  let buffer = NetMutableBytes.FromRaw(&mut scratch[0], 16384ip).get_if<NetMutableBytes>() as NetMutableBytes;
  while true {
    let checked = self.Check();
    if checked.IsErr() {
      return checked;
    }

    let more = self.Pump(buffer);
    if more.IsErr() {
      return more.get_if<Http2Error>() as Http2Error;
    }
    if !(more.get_if<bool>() as bool) {
      return UnitValue();
    }
  }

  return Http2Error{kind: Http2ErrorKind.Protocol};
}

@extern("C") func nyra_http2_stream_head(context: *mut void, session: *mut int8, id: int32, count: int32) -> int32 {
  unsafe {
    return (* (context as *mut Http2StreamCallbackState)).Head(session, id, count);
  }
}

@extern("C") func nyra_http2_stream_data(context: *mut void, id: int32, bytes: *const uint8, size: int32) -> int32 {
  let admitted = NetBytes.FromRaw(bytes, size as intptr);
  if admitted.IsErr() {
    return -1;
  }

  let data = admitted.get_if<NetBytes>() as NetBytes;
  unsafe {
    let state = context as *mut Http2StreamCallbackState;
    return (*state).handler.OnData(id, data).IsOk() ? 0 : -1;
  }
}

@extern("C") func nyra_http2_stream_end(context: *mut void, session: *mut int8, id: int32, count: int32) -> int32 {
  unsafe {
    return (* (context as *mut Http2StreamCallbackState)).End(session, id, count);
  }
}

@extern("C") func nyra_http2_stream_closed(context: *mut void, id: int32, code: uint32) -> void {
  unsafe {
    let state = context as *mut Http2StreamCallbackState;
    (*state).handler.OnClose(id, code);
  }
}

@extern("C") func nyra_http2_stream_produce(context: *mut void, id: int32, bytes: *mut uint8, size: int32) -> int32 {
  let admitted = NetMutableBytes.FromRaw(bytes, size as intptr);
  if admitted.IsErr() {
    return -1;
  }

  let output = admitted.get_if<NetMutableBytes>() as NetMutableBytes;
  unsafe {
    let state = context as *mut Http2StreamCallbackState;
    let produced = (*state).handler.Produce(id, output);
    if produced.IsErr() {
      return -1;
    }

    return produced.get_if<int32>() as int32;
  }
}

method(Http2StreamCallbackState) Head(session: *mut int8, id: int32, count: int32) -> int32 {
  let request = Http2StreamRequest.Read(self.api.core, session, id, count);
  if request.IsErr() {
    return -1;
  }

  return self.handler.OnHead(request.get_if<Http2StreamRequest>() as Http2StreamRequest).IsOk() ? 0 : -1;
}

static method(Http2StreamRequest) Read(
  api: ref Http2ServerProviderApi, session: *mut int8, id: int32, count: int32
) -> Result<Http2StreamRequest, Http2Error> {
  var request = Http2StreamRequest{stream_id: id, fields: Array<HttpField>.New()};
  var index: int32 = 0;
  while index < count {
    var native = Http2ServerNativeField{};
    if api.field(session, id, index, &mut native) != 0 {
      return Http2Error{kind: Http2ErrorKind.Protocol};
    }

    request.AddHeader(native.CopyField());
    index += 1;
  }

  return request;
}

method(Http2StreamRequest) AddHeader(field: ref HttpField) -> void {
  if field.name == ":method" {
    self.verb = field.value;
  } else if field.name == ":scheme" {
    self.scheme = field.value;
  } else if field.name == ":path" {
    self.target = field.value;
  } else if field.name == ":authority" {
    self.authority = field.value;
  } else {
    self.fields.Push(field);
  }
}

method(Http2StreamCallbackState) End(session: *mut int8, id: int32, count: int32) -> int32 {
  let trailers = Http2WireFields.ReadTrailers(self.api.core, session, id, count);
  if trailers.IsErr() {
    return -1;
  }

  let ended = self.handler.OnEnd(id, trailers.get_if<Array<HttpField>>() as Array<HttpField>);
  if ended.IsErr() {
    return -1;
  }

  return (ended.get_if<Http2StreamResponse>() as Http2StreamResponse).Submit(self.api.respond, session, id);
}

static method(Http2WireFields) ReadTrailers(
  api: ref Http2ServerProviderApi, session: *mut int8, id: int32, count: int32
) -> Result<Array<HttpField>, Http2Error> {
  var trailers = Array<HttpField>.New();
  var index: int32 = 0;
  while index < count {
    var native = Http2ServerNativeField{};
    if api.field(session, id, index, &mut native) != 1 {
      return Http2Error{kind: Http2ErrorKind.Protocol};
    }

    trailers.Push(native.CopyField());
    index += 1;
  }

  return trailers;
}

method(Http2StreamResponse) Submit(respond: Http2StreamRespond, session: *mut int8, id: int32) -> int32 {
  let fields = self.fields.Len();
  if fields >= 128 {
    return -1;
  }

  var headers = Http2WireFields{};
  headers.Prepare(self.fields);
  return respond(session, id, self.status, &headers.fields[0], fields, self.has_body ? 1 : 0);
}
