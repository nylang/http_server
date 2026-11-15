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

    let field = native.CopyField();
    if kind == 1 {
      request.trailers.Push(field);
    } else {
      request.AddHeader(field);
    }
    index += 1;
  }

  return request;
}

method(Http2ServerNativeField) CopyField() -> HttpField {
  let name = copy(string.ViewFrom(self.name as *const int8, self.name_size));
  let value = copy(string.ViewFrom(self.value as *const int8, self.value_size));
  return HttpField{name: name, value: value};
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

  var headers = Http2WireFields{};
  headers.Prepare(response.fields);
  return self.provider.api.respond(
    self.provider.handle, id, response.status, &headers.fields[0], count, response.body.Data(), response.body.Len()
  );
}

// Keep the normalized names alive until the provider copies the header block.
struct Http2WireFields {
  names: <string>[128];
  fields: <Http2ServerNativeField>[128];
}

method(Http2WireFields) Prepare(fields: ref Array<HttpField>) -> void {
  var index: int32 = 0;
  while index < fields.Len() {
    let field = fields.Get(index);
    self.names[index] = field.name.ToLowerAscii();
    self.fields[index] = Http2ServerNativeField{
      name: self.names[index].data as *const uint8, value: field.value.data as *const uint8,
      name_size: self.names[index].length, value_size: field.value.length
    };
    index += 1;
  }
}
