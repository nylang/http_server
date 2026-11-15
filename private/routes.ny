// Copyright (c) 2026 tangxiangjiang
// SPDX-License-Identifier: MIT

/** @brief Owns method/path matching and captures without depending on exchange I/O. */
module HttpServerRoutes;
import "stdlib:stdlib.ny";
import "http:http.ny";
import "interface/http_server.ni";

struct HttpRouteSegment {
  value: string;
  capture: bool;
}

struct HttpRoute {
  verb: string;
  path: string;
  id: int32;
  segments: Array<HttpRouteSegment>;
}

/** @brief Owns literal routes and insertion-ordered path patterns. */
pub struct HttpRoutes {
  entries: Array<HttpRoute>;
}

pub static method(HttpRoutes) New() -> HttpRoutes {
  return HttpRoutes{entries: Array<HttpRoute>.New()};
}

pub method(HttpRoutes) Add(verb: ref string, path: ref string, id: int32) -> bool {
  if !HttpRoutes.ValidPath(verb, path) || self.LookupLiteral(verb, path) >= 0 {
    return false;
  }

  self.Insert(HttpRoute{verb: copy(verb), path: copy(path), id: id});
  return true;
}

pub method(HttpRoutes) AddPattern(verb: ref string, path: ref string, id: int32) -> bool {
  if !HttpRoutes.ValidPath(verb, path) {
    return false;
  }

  var segments = Array<HttpRouteSegment>.New();
  var captures: int32 = 0;
  var start: int32 = 1;
  while true {
    let end = segment_end(path, start);
    let segment = path.View(start, end - start);
    if segment.Contains("{") || segment.Contains("}") {
      if segment.length < 3 || !segment.StartsWith("{") || !segment.EndsWith("}") {
        return false;
      }

      let name = segment.View(1, segment.length - 2);
      if !valid_capture_name(name) {
        return false;
      }

      var i: int32 = 0;
      while i < segments.Len() {
        let previous = segments.Get(i);
        if previous.capture && previous.value == name {
          return false;
        }
        i += 1;
      }

      segments.Push(HttpRouteSegment{value: copy(name), capture: true});
      captures += 1;
    } else {
      segments.Push(HttpRouteSegment{value: copy(segment)});
    }

    if end == path.length {
      break;
    }
    start = end + 1;
  }

  if captures == 0 {
    return false;
  }

  var route = HttpRoute{verb: copy(verb), id: id, segments: segments};
  var i: int32 = 0;
  while i < self.entries.Len() {
    if self.entries.Get(i).SamePattern(route) {
      return false;
    }
    i += 1;
  }

  self.Insert(move(route));
  return true;
}

static method(HttpRoutes) ValidPath(verb: ref string, path: ref string) -> bool {
  if !path.StartsWith("/") || path.Contains("?") || path.Contains("#") {
    return false;
  }

  // Apply the same token and origin-form validation as the request parser.
  let fields: <HttpField>[1] = {HttpField{name: "Host", value: "localhost"}};
  return HttpHead.EncodeRequest(verb, path, fields).IsOk();
}

method(HttpRoutes) Insert(route: HttpRoute) -> void {
  // A default-constructed table is usable too.
  if self.entries.Len() == 0 {
    self.entries = Array<HttpRoute>.New();
  }

  self.entries.Push(move(route));
}

pub method(HttpRoutes) Match(request: ref HttpHead) -> int32? {
  let request_target = request.Target();
  let target = request_target.View(0, path_end(request_target));
  let found = self.Find(request.Method(), target);
  if found < 0 {
    return nil;
  }

  return self.entries.Get(found).id;
}

pub method(HttpRoutes) MatchTarget(verb: ref string, target: ref string) -> HttpRouteMatch? {
  let path = target.View(0, path_end(target));
  let found = self.Find(verb, path);
  if found < 0 {
    return nil;
  }

  return self.entries.Get(found).Capture(path);
}

func path_end(target: ref string) -> int32 {
  var end: int32 = 0;
  while end < target.length && target.ByteAt(end) != 63 {
    end += 1;
  }

  return end;
}

method(HttpRoutes) LookupLiteral(verb: ref string, path: ref string) -> int32 {
  var i: int32 = 0;
  while i < self.entries.Len() {
    let route = self.entries.Get(i);
    if route.segments.Len() == 0 && route.verb == verb && route.path == path {
      return i;
    }
    i += 1;
  }

  return -1;
}

method(HttpRoutes) Find(verb: ref string, path: ref string) -> int32 {
  if !path.StartsWith("/") {
    return -1;
  }

  let exact = self.LookupLiteral(verb, path);
  if exact >= 0 {
    return exact;
  }

  var i: int32 = 0;
  while i < self.entries.Len() {
    let route = self.entries.Get(i);
    if route.verb == verb && route.Matches(path) {
      return i;
    }
    i += 1;
  }

  return -1;
}

method(HttpRoute) SamePattern(other: ref HttpRoute) -> bool {
  if self.verb != other.verb || self.segments.Len() != other.segments.Len() {
    return false;
  }

  var i: int32 = 0;
  while i < self.segments.Len() {
    let a = self.segments.Get(i);
    let b = other.segments.Get(i);
    if a.capture != b.capture || (!a.capture && a.value != b.value) {
      return false;
    }
    i += 1;
  }

  return true;
}

method(HttpRoute) Matches(path: ref string) -> bool {
  var start: int32 = 1;
  var i: int32 = 0;
  while i < self.segments.Len() {
    let segment = self.segments.Get(i);
    let end = segment_end(path, start);
    if segment.capture ? end == start : segment.value != path.View(start, end - start) {
      return false;
    }
    if end == path.length {
      return i + 1 == self.segments.Len();
    }
    start = end + 1;
    i += 1;
  }

  return false;
}

// Copy captures only after the whole route has matched.
method(HttpRoute) Capture(path: ref string) -> HttpRouteMatch {
  var params = Array<HttpRouteParam>.New();
  var start: int32 = 1;
  var i: int32 = 0;
  while i < self.segments.Len() {
    let segment = self.segments.Get(i);
    let end = segment_end(path, start);
    if segment.capture {
      params.Push(HttpRouteParam{name: copy(segment.value), value: copy(path.View(start, end - start))});
    }
    if end == path.length {
      break;
    }
    start = end + 1;
    i += 1;
  }

  return HttpRouteMatch{id: self.id, params: params};
}

func segment_end(path: ref string, start: int32) -> int32 {
  var end = start;
  while end < path.length && path.ByteAt(end) != 47 {
    end += 1;
  }

  return end;
}

func valid_capture_name(name: ref string) -> bool {
  var i: int32 = 0;
  while i < name.length {
    let ch = name.ByteAt(i);
    let letter = (ch >= 65 && ch <= 90) || (ch >= 97 && ch <= 122) || ch == 95;
    if !letter && (i == 0 || ch < 48 || ch > 57) {
      return false;
    }
    i += 1;
  }

  return true;
}
