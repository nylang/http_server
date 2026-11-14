// Copyright (c) 2026 tangxiangjiang
// SPDX-License-Identifier: MIT

/** @brief Owns the literal method/path routing table independently of exchange I/O. */
module HttpServerRoutes;
import "stdlib:stdlib.ny";
import "http:http.ny";
import "interface/http_server.ni";

struct HttpRoute {
  verb: string;
  path: string;
  id: int32;
}

/** @brief Owns an insertion-ordered set of literal HTTP routes. */
pub struct HttpRoutes {
  entries: Array<HttpRoute>;
}

pub static method(HttpRoutes) New() -> HttpRoutes {
  return HttpRoutes{entries: Array<HttpRoute>.New()};
}

pub method(HttpRoutes) Add(verb: ref string, path: ref string, id: int32) -> bool {
  if verb.length == 0 || !path.StartsWith("/") || path.Contains("?") || path.Contains("#") ||
      self.Lookup(verb, path) != nil {
    return false;
  }

  // A default-constructed table is usable too.
  if self.entries.Len() == 0 {
    self.entries = Array<HttpRoute>.New();
  }

  self.entries.Push(HttpRoute{verb: copy(verb), path: copy(path), id: id});
  return true;
}

pub method(HttpRoutes) Match(request: ref HttpHead) -> int32? {
  let target = request.Target();
  var end: int32 = 0;
  while end < target.length && target.ByteAt(end) != 63 {
    end += 1;
  }

  return self.Lookup(request.Method(), target.View(0, end));
}

method(HttpRoutes) Lookup(verb: ref string, path: ref string) -> int32? {
  var i: int32 = 0;
  while i < self.entries.Len() {
    let route = self.entries.Get(i);
    if route.verb == verb && route.path == path {
      return route.id;
    }
    i += 1;
  }

  return nil;
}
