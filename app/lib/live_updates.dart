import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import 'session.dart';

/// Something changed in a family: [topic] names the area, such as `shopping`,
/// `calendar` or `family`. [resync] stands for "maybe anything", after the app
/// was away or the connection broke.
class LiveEvent {
  const LiveEvent(this.family, this.topic);

  static const resync = LiveEvent('', 'resync');

  final String family;
  final String topic;

  bool get isResync => topic == 'resync';
}

/// Where screens hear of changes others make. Fed by [LiveConnection]; without
/// one, as in tests, nothing comes and [connected] stays false, so screens keep
/// asking now and then by themselves.
class LiveUpdates {
  final _events = StreamController<LiveEvent>.broadcast();

  /// True while the server can tell of changes at once.
  final connected = ValueNotifier(false);

  Stream<LiveEvent> get events => _events.stream;

  /// Changes of one family in one of [topics], and every resync.
  Stream<LiveEvent> of(String family, Set<String> topics) =>
      events.where((e) => e.isResync || (e.family == family && topics.contains(e.topic)));

  void emit(LiveEvent event) {
    if (!_events.isClosed) _events.add(event);
  }
}

/// Keeps GET /api/live open while signed in, a stream of server-sent events, and
/// hands what comes to [AppSession.live]. Connects again after a break, waiting
/// longer each time it fails, and right away when the app comes back.
class LiveConnection {
  LiveConnection({required this.session, http.Client Function()? client}) : _newClient = client ?? http.Client.new;

  final AppSession session;
  final http.Client Function() _newClient;

  /// A heartbeat comes every 25 seconds; without anything for this long the
  /// connection is dead even if nobody said so.
  static const silence = Duration(seconds: 70);

  http.Client? _client;
  AppLifecycleListener? _lifecycle;
  Completer<void>? _wake;
  bool _running = false;
  bool _stopped = false;
  bool _wasConnected = false;
  bool _paused = false;
  Duration _delay = _firstDelay;

  static const _firstDelay = Duration(seconds: 2);
  static const _maxDelay = Duration(minutes: 1);

  LiveUpdates get _live => session.live;

  void start() {
    session.addListener(_sessionChanged);
    _lifecycle = AppLifecycleListener(
      onResume: () {
        _paused = false;
        _delay = _firstDelay;
        _live.emit(LiveEvent.resync);
        _wakeUp();
      },
      // In the background the system closes it anyway, and it costs battery.
      onPause: () {
        _paused = true;
        _close();
      },
    );
    unawaited(_run());
  }

  void dispose() {
    _stopped = true;
    session.removeListener(_sessionChanged);
    _lifecycle?.dispose();
    _close();
    _wakeUp();
  }

  bool get _canConnect =>
      !_paused && session.status == SessionStatus.signedIn && session.api.token != null;

  void _sessionChanged() {
    if (_canConnect) {
      _wakeUp();
    } else {
      _close();
    }
  }

  void _wakeUp() {
    final wake = _wake;
    _wake = null;
    if (wake != null && !wake.isCompleted) wake.complete();
  }

  void _close() {
    _client?.close();
    _client = null;
    _live.connected.value = false;
  }

  /// Waits for [duration], or less when [_wakeUp] is called.
  Future<void> _sleep(Duration? duration) async {
    final wake = _wake = Completer<void>();
    // A timer that goes with the wait, so that nothing is left over after dispose.
    final timer = duration == null ? null : Timer(duration, _wakeUp);
    await wake.future;
    timer?.cancel();
  }

  Future<void> _run() async {
    if (_running) return;
    _running = true;
    while (!_stopped) {
      if (!_canConnect) {
        await _sleep(null);
        continue;
      }
      await _connectOnce();
      if (_stopped) break;
      if (!_canConnect) continue;
      await _sleep(_delay);
      _delay = _delay * 2 > _maxDelay ? _maxDelay : _delay * 2;
    }
    _running = false;
  }

  Future<void> _connectOnce() async {
    final api = session.api;
    final client = _client = _newClient();
    Timer? watchdog;
    try {
      final request = http.Request('GET', Uri.parse('${api.baseUrl}/api/live'))
        ..headers.addAll(api.headers)
        ..headers['Accept'] = 'text/event-stream';
      final response = await client.send(request).timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        // A 401 signs out with the next ordinary request; nothing to do here.
        await response.stream.drain<void>();
        return;
      }
      _live.connected.value = true;
      _delay = _firstDelay;
      // Whatever happened while there was no connection is missed otherwise.
      if (_wasConnected) _live.emit(LiveEvent.resync);
      _wasConnected = true;
      // Nothing for too long: closing the client ends the stream below with an error.
      void arm() {
        watchdog?.cancel();
        watchdog = Timer(silence, client.close);
      }

      arm();
      final lines = response.stream.transform(utf8.decoder).transform(const LineSplitter());
      await for (final line in lines) {
        arm();
        if (!line.startsWith('data:')) continue;
        try {
          final data = jsonDecode(line.substring(5).trim()) as Map<String, dynamic>;
          _live.emit(LiveEvent(data['family'] as String? ?? '', data['topic'] as String? ?? ''));
        } on FormatException {
          // Not ours to understand; the next one may be.
        }
      }
    } catch (e) {
      // Broken, closed on purpose, or silent too long: the loop decides what comes next.
      debugPrint('Live: $e');
    } finally {
      watchdog?.cancel();
      client.close();
      if (identical(_client, client)) _client = null;
      _live.connected.value = false;
    }
  }
}

/// For screens that show what others may change: [listenLive] calls back when the
/// server tells of a change in one of the topics of the family in view, a burst of
/// them taken together.
mixin LiveReload<T extends StatefulWidget> on State<T> {
  StreamSubscription<LiveEvent>? _liveEvents;
  Timer? _liveSoon;

  /// Call once the context can reach the session, as in didChangeDependencies.
  /// [everyFamily] hears the changes of all families of the user, not only the one in view.
  void listenLive(Set<String> topics, VoidCallback onChange, {bool everyFamily = false}) {
    final session = SessionScope.of(context);
    _liveEvents?.cancel();
    final events = everyFamily
        ? session.live.events.where((e) => e.isResync || topics.contains(e.topic))
        : session.live.of(session.current?.id ?? '', topics);
    _liveEvents = events.listen((_) {
      _liveSoon?.cancel();
      _liveSoon = Timer(const Duration(milliseconds: 300), () {
        if (mounted) onChange();
      });
    });
  }

  /// True while changes come at once, and asking regularly is not needed.
  bool get liveConnected => SessionScope.of(context).live.connected.value;

  @override
  void dispose() {
    _liveEvents?.cancel();
    _liveSoon?.cancel();
    super.dispose();
  }
}
