# Event-driven TailscaleKit IPN message delivery

TailscaleKit previously received `watch-ipn-bus` bytes through
`URLSessionDataDelegate`, queued complete newline-delimited chunks, and then had
`MessageProcessor` wake every 100ms to ask whether anything had arrived.

That polling was unnecessary: the URLSession delegate is already an immediate,
event-driven source. It added uniformly distributed 0–100ms observation delay,
periodic wakeups for the lifetime of the node, and made burst handling depend on
a 24-entry queue surviving until the next timer tick.

The implementation is now push-driven:

1. `MessageReader` appends bytes on its serial URLSession delegate queue.
2. When one or more complete newline-delimited messages are queued, it invokes a
   `messagesAvailableHandler` on that queue.
3. `MessageProcessor` coalesces burst notifications and asks the reader to drain
   all currently queued chunks in FIFO order.
4. Decoding remains serialized on `MessageProcessor.workQueue`; consumer calls
   remain actor calls.
5. A `drainRequested` edge closes the arrival-during-drain race without a timer
   or empty repeated drains.
6. The existing congestion behavior remains: once capacity is exceeded the
   reader drains what it retained, reports `queueCongested`, and the app restarts
   the bus with an initial-state snapshot.

A three-run simulator lifecycle harness decoded every netmap with no bus or
protocol errors. NetMap and Starting now appeared in the same log millisecond;
previously each could pay up to the 100ms poll interval.

This does not change the URLSession request timeout/restart behavior. That is a
separate transport-liveness concern in Aperture's `TSNetManager`.
