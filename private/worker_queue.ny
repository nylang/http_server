// Copyright (c) 2026 tangxiangjiang
// SPDX-License-Identifier: MIT

/** @brief Owns bounded socket handoff and the first fatal error for an HTTP worker pool.
 * @note The acceptor is the sole producer. The mutex covers the pending socket,
 * worker occupancy, admission closure and failure. Socket I/O runs outside it. */
module HttpServerWorkerHandoff;
import "stdlib:stdlib.ny";
import "net_core:net_core.ny";
import "interface/http_server.ni";

/** @brief Synchronized handoff shared by the acceptor and the workers. */
pub struct HttpServerWorkerQueue {
  mutex: Mutex;
  changed: ConditionVariable;
  stop: NetCancellation;
  capacity: int32;
  occupied: int32;
  closed: bool;
  failure: HttpServerError?;
  pending: TcpConnection?;
}

/** @brief Allocate the synchronization state before admitting connections. */
pub static method(HttpServerWorkerQueue) New(
  capacity: int32, stop: ref NetCancellation
) -> Result<arc<HttpServerWorkerQueue>, HttpServerError> {
  var lock = Mutex.New();
  var signal = ConditionVariable.New();
  if lock.IsErr() || signal.IsErr() {
    return HttpServerError{kind: HttpServerErrorKind.WorkerUnavailable};
  }

  let queue: arc<HttpServerWorkerQueue> = new arc<HttpServerWorkerQueue>{
    mutex: move(lock.get_if<Mutex>() as Mutex), changed: move(signal.get_if<ConditionVariable>() as ConditionVariable),
    stop: stop, capacity: capacity
  };
  return queue;
}

/** @brief Check whether the only producer can accept another socket. */
pub method(HttpServerWorkerQueue) AwaitCapacity() -> bool {
  self.mutex.Lock();
  while !self.closed && !self.stop.IsCancelled() && (self.occupied == self.capacity || self.pending != nil) {
    // External cancellation signals the network wake handle. Recheck it
    // periodically while the acceptor is waiting for a worker slot.
    self.changed.WaitTimeout(self.mutex, 25u32);
  }
  let ready = !self.closed && !self.stop.IsCancelled();
  self.mutex.Unlock();

  return ready;
}

/** @brief Transfer an accepted socket into the reserved handoff slot. */
pub method(HttpServerWorkerQueue) Offer(connection: TcpConnection) -> void {
  self.mutex.Lock();
  if !self.closed && !self.stop.IsCancelled() {
    self.pending = move(connection);
    self.occupied += 1;
    self.changed.NotifyAll();
  }
  self.mutex.Unlock();
}

/** @brief Take a connection or return nil when admission stops. */
pub method(HttpServerWorkerQueue) Take() -> TcpConnection? {
  self.mutex.Lock();
  while !self.closed && !self.stop.IsCancelled() && self.pending == nil {
    self.changed.Wait(self.mutex);
  }

  var connection: TcpConnection? = nil;
  if !self.closed && !self.stop.IsCancelled() {
    connection = move(self.pending);
    self.pending = nil;
    self.changed.NotifyAll();
  }
  self.mutex.Unlock();

  return move(connection);
}

/** @brief Release a slot after its worker has retired the connection. */
pub method(HttpServerWorkerQueue) FinishConnection() -> void {
  self.mutex.Lock();
  self.occupied -= 1;
  self.changed.NotifyAll();
  self.mutex.Unlock();
}

/** @brief Retain the first fatal error and wake both network and handoff waits. */
pub method(HttpServerWorkerQueue) Fail(error: HttpServerError) -> void {
  self.mutex.Lock();
  if self.failure == nil {
    self.failure = error;
  }
  self.closed = true;
  self.changed.NotifyAll();
  self.mutex.Unlock();
  self.stop.Cancel();
}

/** @brief Stop the handoff and release any unclaimed socket. */
pub method(HttpServerWorkerQueue) Close() -> void {
  self.mutex.Lock();
  self.closed = true;
  self.pending = nil;
  self.changed.NotifyAll();
  self.mutex.Unlock();
}

/** @brief Read the recorded fatal error after the workers have stopped. */
pub method(HttpServerWorkerQueue) Outcome() -> Result<Unit, HttpServerError> {
  self.mutex.Lock();
  let error = self.failure;
  self.mutex.Unlock();
  if error != nil {
    return error as HttpServerError;
  }

  return UnitValue();
}
