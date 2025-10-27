import 'dart:async';

import 'grid_layout_store.dart';

/// Payload for geometry mutation processing.
class GeometryMutationJob {
  GeometryMutationJob({
    required this.geometry,
    required this.notify,
    required this.ticket,
  });

  final GridLayoutGeometry geometry;
  final bool notify;
  final GeometryMutationTicket ticket;
}

/// Token that allows a running job to observe whether it has been superseded.
class GeometryMutationTicket {
  GeometryMutationTicket._(this._id, this._queue);

  final int _id;
  final GeometryMutationQueue _queue;

  /// Returns true when a newer job has been enqueued after this ticket.
  bool get isCancelled => _queue._latestSequence != _id;
}

typedef GeometryMutationWorker = Future<void> Function(GeometryMutationJob job);

/// Queues geometry mutations and ensures they are applied sequentially with throttling.
class GeometryMutationQueue {
  GeometryMutationQueue({
    required GeometryMutationWorker worker,
    Duration throttle = const Duration(milliseconds: 60),
  })  : _worker = worker,
        _throttle = throttle;

  final GeometryMutationWorker _worker;
  final Duration _throttle;

  GeometryMutationJob? _pendingJob;
  bool _processing = false;
  Timer? _throttleTimer;
  DateTime? _lastRun;
  int _sequence = 0;
  int _latestSequence = 0;

  /// Schedules a geometry mutation. Only the most recent request is retained.
  void enqueue(GridLayoutGeometry geometry, {required bool notify}) {
    final ticket = GeometryMutationTicket._(++_sequence, this);
    _latestSequence = ticket._id;
    _pendingJob = GeometryMutationJob(
      geometry: geometry,
      notify: notify,
      ticket: ticket,
    );
    _schedule();
  }

  void _schedule() {
    if (_processing || _pendingJob == null) {
      return;
    }
    final now = DateTime.now();
    final delay = _lastRun == null ? Duration.zero : _computeDelay(now);
    if (delay <= Duration.zero) {
      _startNext();
      return;
    }
    _throttleTimer?.cancel();
    _throttleTimer = Timer(delay, () {
      _throttleTimer = null;
      _startNext();
    });
  }

  Duration _computeDelay(DateTime now) {
    final elapsed = now.difference(_lastRun!);
    if (elapsed >= _throttle) {
      return Duration.zero;
    }
    return _throttle - elapsed;
  }

  void _startNext() {
    final job = _pendingJob;
    if (job == null) {
      return;
    }
    _pendingJob = null;
    _processing = true;
    _lastRun = DateTime.now();
    Future<void>(() async {
      try {
        await _worker(job);
      } finally {
        _processing = false;
        _schedule();
      }
    });
  }

  void dispose() {
    _throttleTimer?.cancel();
  }
}
