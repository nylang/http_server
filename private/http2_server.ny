// Copyright (c) 2026 tangxiangjiang
// SPDX-License-Identifier: MIT

/** @brief Drives HTTP/2 connection I/O and serial dispatch of completed requests. */
module Http2ServerDriver;
part "http2_server_requests.ny";
import "stdlib:stdlib.ny";
import "net_core:net_core.ny";
import "http:http.ny";
import "http:http2.ny";
import "interface/http2_server.ni";
import "private/http2_server_provider.ny";
import "private/exchange.ny";

/** @brief HTTP/2 accept and dispatch operations. */
pub struct Http2Server {}

pub static method(Http2Server) ServeTcp(
  connection: ref mut TcpConnection, provider_file: ref string, handler: ref mut Http2ServerHandler,
  limits: ref Http2Limits, options: ref NetOperationOptions
) -> Result<Unit, Http2Error> {
  let adapter = HttpServerTcp{connection: move(connection)};
  return Http2Server.ServeTransport(move(adapter), false, provider_file, handler, limits, options);
}

pub static method(Http2Server) ServeTransport(
  transport: WebSocketTransport, secure: bool, provider_file: ref string,
  handler: ref mut Http2ServerHandler, limits: ref Http2Limits, options: ref NetOperationOptions
) -> Result<Unit, Http2Error> {
  if provider_file.length == 0 || !limits.IsValid() {
    transport.Abort();
    return Http2Error{kind: Http2ErrorKind.InvalidArgument};
  }

  var opened = Http2ServerProvider.Open(provider_file, limits, secure);
  if opened.IsErr() {
    transport.Abort();
    return opened.get_if<Http2Error>() as Http2Error;
  }

  var session = Http2ServerSession{
    provider: move(opened.get_if<Http2ServerProvider>() as Http2ServerProvider), transport: transport, options: options
  };
  let served = session.Run(handler);
  session.transport.Abort();
  return served;
}

struct Http2ServerSession {
  provider: Http2ServerProvider;
  transport: WebSocketTransport;
  options: NetOperationOptions;
}

method(Http2ServerSession) Run(handler: ref mut Http2ServerHandler) -> Result<Unit, Http2Error> {
  var scratch: <uint8>[16384] = <uint8>[16384]{};
  let buffer = NetMutableBytes.FromRaw(&mut scratch[0], 16384ip).get_if<NetMutableBytes>() as NetMutableBytes;
  while true {
    let checked = self.options.Check(Instant.Now().ToDurationSinceEpochish().ToNanoseconds());
    if checked.IsErr() {
      return Http2Error{kind: Http2ErrorKind.Network, network: checked.get_if<NetError>()};
    }
    let dispatched = self.Dispatch(handler);
    if dispatched.IsErr() {
      return dispatched;
    }
    let flushed = self.Flush();
    if flushed.IsErr() {
      return flushed;
    }

    let state = self.provider.api.state(self.provider.handle);
    if state < 0 {
      return Http2Error{kind: Http2ErrorKind.Protocol};
    }
    if state == 0 {
      return UnitValue();
    }
    let read = self.transport.Read(buffer, self.options);
    if read.IsErr() {
      return Http2ServerSession.MapTransport(read.get_if<WebSocketError>() as WebSocketError);
    }

    let size = read.get_if<intptr>() as intptr;
    if size == 0ip {
      if self.provider.api.pending(self.provider.handle) != 0 {
        return Http2Error{kind: Http2ErrorKind.UnexpectedEof};
      }
      return UnitValue();
    }
    if size < 0ip || size > buffer.Len() || self.provider.api.input(self.provider.handle, &scratch[0], size) != size {
      return Http2Error{kind: Http2ErrorKind.Protocol};
    }
  }

  return Http2Error{kind: Http2ErrorKind.Protocol};
}

method(Http2ServerSession) Flush() -> Result<Unit, Http2Error> {
  while true {
    var bytes: *const uint8 = nil;
    let size = self.provider.api.output(self.provider.handle, &mut bytes);
    if size < 0ip {
      return Http2Error{kind: Http2ErrorKind.Protocol, code: size as int32};
    }
    if size == 0ip {
      return UnitValue();
    }

    let block = NetBytes.FromRaw(bytes, size).get_if<NetBytes>() as NetBytes;
    let sent = self.transport.WriteAll(block, self.options);
    if sent.IsErr() {
      return Http2ServerSession.MapTransport(sent.get_if<WebSocketError>() as WebSocketError);
    }
  }

  return Http2Error{kind: Http2ErrorKind.Protocol};
}

static method(Http2ServerSession) MapTransport(error: ref WebSocketError) -> Http2Error {
  if error.kind == WebSocketErrorKind.Tls {
    return Http2Error{kind: Http2ErrorKind.Tls};
  }
  if error.kind == WebSocketErrorKind.UnexpectedEof {
    return Http2Error{kind: Http2ErrorKind.UnexpectedEof};
  }

  return Http2Error{kind: Http2ErrorKind.Network, network: error.network_error};
}
