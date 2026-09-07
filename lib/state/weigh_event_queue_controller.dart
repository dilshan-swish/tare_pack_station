import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/headoffice_api.dart';
import 'headoffice_controller.dart';
import 'settings_controller.dart';

/// How many queued weigh events are currently waiting to be resent — shown
/// as a small chip on the orders queue so staff can see at a glance that
/// weighs are being held locally, not silently lost, while the API (or the
/// network) is unreachable. Watch this provider somewhere always-mounted
/// (the orders queue screen, matching headOfficeHeartbeatProvider) to keep
/// its retry timer alive.
final weighEventQueueProvider =
    NotifierProvider<WeighEventQueueController, int>(WeighEventQueueController.new);

class WeighEventQueueController extends Notifier<int> {
  Timer? _timer;

  @override
  int build() {
    final api = ref.watch(headOfficeApiProvider);
    _timer?.cancel();
    ref.onDispose(() => _timer?.cancel());

    unawaited(_refreshCount());
    if (api != null) {
      // Try once immediately (covers "just reconnected"), then periodically
      // — matches the cadence order of magnitude of the head-office
      // heartbeat, frequent enough to drain the queue soon after
      // connectivity returns without hammering a genuinely offline API.
      unawaited(_flush());
      _timer = Timer.periodic(const Duration(seconds: 30), (_) => unawaited(_flush()));
    }
    return 0; // until the first count load lands, a moment later
  }

  Future<void> _refreshCount() async {
    final queue = await ref.read(settingsStoreProvider).loadWeighEventQueue();
    state = queue.length;
  }

  /// Attempts to send [payload] immediately; if that fails for a retryable
  /// reason (no network, a timeout, head office's own 5xx), queues it
  /// locally instead of losing it. Never throws — matches sendWeighEvent's
  /// own contract, so a reporting hiccup can never disrupt dispatching an
  /// order. This is the only place a weigh event is reported from.
  Future<void> sendOrQueue(Map<String, dynamic> payload) async {
    final api = ref.read(headOfficeApiProvider);
    if (api == null) return; // not configured — nothing to send or retry against
    final result = await api.sendWeighEvent(payload);
    if (result == WeighEventSendResult.retryable) {
      await ref.read(settingsStoreProvider).enqueueWeighEvent(payload);
      await _refreshCount();
    }
    // sent -> nothing further to do. rejected -> deliberately dropped
    // (already logged inside sendWeighEvent) rather than queued — the exact
    // same payload would get the exact same rejection forever.
  }

  /// Retries every currently-queued weigh event, oldest first, stopping at
  /// the first retryable failure rather than working through the rest of a
  /// (possibly large) queue at the full HTTP timeout each — that would turn
  /// "still offline" into a multi-minute blocking flush on every timer tick.
  /// A permanently-rejected entry doesn't stop the pass — it's not a
  /// connectivity signal, just one bad payload — so later, valid entries
  /// still get their turn.
  Future<void> _flush() async {
    final api = ref.read(headOfficeApiProvider);
    if (api == null) return;
    final store = ref.read(settingsStoreProvider);
    final queue = await store.loadWeighEventQueue();
    if (queue.isEmpty) return;

    final oldestFirst = queue.entries.toList()
      ..sort((a, b) =>
          (a.value['queuedAt'] as String? ?? '').compareTo(b.value['queuedAt'] as String? ?? ''));

    final toRemove = <String>[];
    for (final entry in oldestFirst) {
      final Map<String, dynamic> payload;
      try {
        payload = Map<String, dynamic>.from(entry.value['payload'] as Map);
      } catch (_) {
        toRemove.add(entry.key); // corrupt entry — can never be sent either way
        continue;
      }
      final result = await api.sendWeighEvent(payload);
      if (result == WeighEventSendResult.retryable) break;
      toRemove.add(entry.key); // sent, or permanently rejected — done with it
    }
    if (toRemove.isNotEmpty) {
      await store.removeQueuedWeighEvents(toRemove);
      await _refreshCount();
    }
  }
}
