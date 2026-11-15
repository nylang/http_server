// Copyright (c) 2026 tangxiangjiang
// SPDX-License-Identifier: MIT

part of Http2ServerDriver;

method(Http2ServerSession) Dispatch(handler: ref mut Http2ServerHandler) -> Result<Unit, Http2Error> {
  while true {
    var body: *const uint8 = nil;
    var size: int32 = 0;
    var fields: int32 = 0;
    let id = self.provider.api.next(self.provider.handle, &mut body, &mut size, &mut fields);
    if id == 0 {
      return UnitValue();
    }

    let requests = self.CopyRequest(id, body, size, fields);
    if requests.IsErr() {
      return requests.get_if<Http2Error>() as Http2Error;
    }
    let request = requests.get_if<Http2ServerRequest>() as Http2ServerRequest;
    let reply = handler.Handle(request);
    if reply.IsErr() {
      if self.provider.api.reset(self.provider.handle, id) != 0 {
        return Http2Error{kind: Http2ErrorKind.Protocol};
      }
    } else {
      let response = reply.get_if<Http2ServerResponse>() as Http2ServerResponse;
      let code = self.SubmitResponse(id, response);
      if code != 0 {
        if code != -2 || self.provider.api.reset(self.provider.handle, id) != 0 {
          return Http2Error{kind: Http2ErrorKind.Protocol, code: code};
        }
      }
    }
  }

  return Http2Error{kind: Http2ErrorKind.Protocol};
}

method(Http2ServerSession) CopyRequest(
  id: int32, data: *const uint8, size: int32, count: int32
) -> Result<Http2ServerRequest, Http2Error> {
  var request = Http2ServerRequest{
    stream_id: id, fields: Array<HttpField>.New(), trailers: Array<HttpField>.New(), body: ByteBuffer.New()
  };
  if request.body.Write(data, size as intptr).IsErr() {
    return Http2Error{kind: Http2ErrorKind.ResourceExhausted};
  }

  var index: int32 = 0;
  while index < count {
    var native = Http2ServerNativeField{};
    let kind = self.provider.api.field(self.provider.handle, id, index, &mut native);
    if kind < 0 {
      return Http2Error{kind: Http2ErrorKind.Protocol};
    }

    let name = copy(string.ViewFrom(native.name as *const int8, native.name_size));
    let value = copy(string.ViewFrom(native.value as *const int8, native.value_size));
    let field = HttpField{name: name, value: value};
    if kind == 1 {
      request.trailers.Push(field);
    } else {
      request.AddHeader(field);
    }
    index += 1;
  }

  return request;
}

method(Http2ServerRequest) AddHeader(field: ref HttpField) -> void {
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

method(Http2ServerSession) SubmitResponse(id: int32, response: ref Http2ServerResponse) -> int32 {
  let count = response.fields.Len();
  if count >= 128 {
    return -2;
  }

  var names: <string>[128] = <string>[128]{};
  var native: <Http2ServerNativeField>[128] = <Http2ServerNativeField>[128]{};
  var index: int32 = 0;
  while index < count {
    let field = response.fields.Get(index);
    names[index] = field.name.ToLowerAscii();
    native[index] = Http2ServerNativeField{
      name: names[index].data as *const uint8, value: field.value.data as *const uint8,
      name_size: names[index].length, value_size: field.value.length
    };
    index += 1;
  }

  return self.provider.api.respond(
    self.provider.handle, id, response.status, &native[0], count, response.body.Data(), response.body.Len()
  );
}
