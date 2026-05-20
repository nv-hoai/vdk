import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/device.dart';

/// Esp32Client is WS-first: it connects to `/ws/app` to receive snapshots,
/// realtime logs and to send commands. HTTP has been removed as a fallback.
class Esp32Client {
  Esp32Client({
    required this.baseUrl,
  });

  final String baseUrl;

  // WebSocket related
  WebSocketChannel? _wsChannel;
  StreamSubscription? _wsSub;
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  final Map<String, Completer<Map<String, dynamic>>> _pendingRequests = {};
  final _realtimeController = StreamController<Map<String, dynamic>>.broadcast();
  List<Device> _lastDevices = [];

  /// Stream of realtime messages (logs/sensors) received via WebSocket.
  Stream<Map<String, dynamic>> get realtimeStream => _realtimeController.stream;

  /// Build default WS URI from baseUrl. Assumes server will provide
  /// an application WebSocket endpoint at `/ws/app`.
  Uri _defaultWsUri() {
    final uri = Uri.parse(baseUrl);
    final scheme = (uri.scheme == 'https' || uri.scheme == 'wss') ? 'wss' : 'ws';
    return Uri(scheme: scheme, host: uri.host, port: uri.hasPort ? uri.port : null, path: '/ws/app');
  }

  /// Connect WebSocket; optional [wsUri] overrides default.
  void connectWebSocket({Uri? wsUri}) {
    final uri = wsUri ?? _defaultWsUri();
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _closeWs();

    try {
      _wsChannel = WebSocketChannel.connect(uri);
      _wsSub = _wsChannel!.stream.listen(_onWsMessage, onDone: _onWsDone, onError: _onWsError, cancelOnError: true);
      // Reset reconnect attempts on successful connect
      _reconnectAttempts = 0;
    } catch (e) {
      _scheduleReconnect();
    }
  }

  void disconnectWebSocket() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _closeWs();
  }

  void _closeWs() {
    _wsSub?.cancel();
    _wsSub = null;
    try {
      _wsChannel?.sink.close();
    } catch (_) {}
    _wsChannel = null;
  }

  void _onWsMessage(dynamic raw) {
    // no-op: incoming raw frame
    try {
      final decoded = jsonDecode(raw as String);
      if (decoded is Map<String, dynamic>) {
        // decoded message
        // If message contains requestId, complete the pending request
        if (decoded.containsKey('requestId')) {
          final rid = decoded['requestId']?.toString();
          if (rid != null) {
            final completer = _pendingRequests.remove(rid);
            completer?..complete(decoded);
            return;
          }
        }

        final type = decoded['type'];

        // Snapshot handling: initial devices/logs
        if (type == 'snapshot') {
          final devicesRaw = decoded['devices'] as List?;
          if (devicesRaw != null) {
            _lastDevices = devicesRaw.whereType<Map<String, dynamic>>().map(Device.fromJson).toList();
          }
          _realtimeController.add(decoded);
          return;
        }

        _realtimeController.add(decoded);
      }
    } catch (_) {
      // ignore malformed messages
    }
  }

  void _onWsDone() {
    _scheduleReconnect();
  }

  void _onWsError(Object error) {
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_reconnectTimer != null) return;
    _reconnectAttempts = (_reconnectAttempts + 1).clamp(1, 30);
    // Exponential backoff base 1000ms, cap 60s, add jitter up to 500ms
    final base = 1000;
    final maxDelay = 60000;
    final exp = (base * (1 << (_reconnectAttempts > 10 ? 10 : _reconnectAttempts))).clamp(base, maxDelay);
    final jitter = (DateTime.now().millisecondsSinceEpoch % 500);
    final delayMs = (exp + jitter).clamp(base, maxDelay);

    _reconnectTimer = Timer(Duration(milliseconds: delayMs), () {
      _reconnectTimer = null;
      connectWebSocket();
    });
  }

  /// Send a command over WebSocket if connected; returns true on success.
  bool sendCommandOverWs(String id, bool isOn) {
    if (_wsChannel == null) return false;
    final msg = jsonEncode({'action': 'set_state', 'deviceId': id, 'isOn': isOn});
    try {
      _wsChannel!.sink.add(msg);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Send a request and await ack from server (over WS). Returns ack payload.
  Future<Map<String, dynamic>> sendRequestAwaitAck(Map<String, dynamic> request, {Duration timeout = const Duration(seconds: 5)}) async {
    if (_wsChannel == null) throw Exception('WebSocket not connected');
    final requestId = DateTime.now().millisecondsSinceEpoch.toString();
    request['requestId'] = requestId;
    final completer = Completer<Map<String, dynamic>>();
    _pendingRequests[requestId] = completer;
    _wsChannel!.sink.add(jsonEncode(request));
    return completer.future.timeout(timeout, onTimeout: () {
      _pendingRequests.remove(requestId);
      throw Exception('Request timed out');
    });
  }

  Future<List<Device>> fetchDevices() async {
    // Return last known devices from the latest snapshot. If none available,
    // return an empty list. Throws if no snapshot received yet.
    if (_lastDevices.isEmpty) {
      throw Exception('No devices snapshot available (WS not connected)');
    }
    return _lastDevices;
  }

  /// Try to send command via WS if connected; otherwise fallback to HTTP POST.
  Future<Device> setDeviceState(String id, bool isOn) async {
    // Use request/ack over WebSocket and wait for ack
    final req = {'action': 'set_state', 'deviceId': id, 'isOn': isOn};
    final ack = await sendRequestAwaitAck(req);
    if (ack['status'] == 'ok' && ack['device'] is Map<String, dynamic>) {
      return Device.fromJson(Map<String, dynamic>.from(ack['device']));
    }

    throw Exception('Failed to set device state: ${ack['error'] ?? 'unknown'}');
  }

  Future<List<Map<String, dynamic>>> fetchLogs({int limit = 100}) async {
    if (_wsChannel == null) throw Exception('WebSocket not connected');

    final resp = await sendRequestAwaitAck({'action': 'get_logs', 'limit': limit});
    final logs = (resp['logs'] as List?)?.whereType<Map<String, dynamic>>().toList() ?? [];
    final sensors = (resp['sensors'] as List?)?.whereType<Map<String, dynamic>>().toList() ?? [];
    final merged = <Map<String, dynamic>>[];
    merged.addAll(logs);
    merged.addAll(sensors);
    merged.sort((a, b) {
      final tsA = a['receivedAt'] ?? a['timestamp'] ?? '';
      final tsB = b['receivedAt'] ?? b['timestamp'] ?? '';
      return tsB.toString().compareTo(tsA.toString());
    });
    return merged;
  }

  Future<List<Map<String, dynamic>>> fetchSensors({int limit = 100}) async {
    if (_wsChannel == null) throw Exception('WebSocket not connected');
    final resp = await sendRequestAwaitAck({'action': 'get_logs', 'limit': limit});
    final sensors = (resp['sensors'] as List?)?.whereType<Map<String, dynamic>>().toList() ?? [];
    return sensors;
  }

  /// Dispose resources when no longer needed.
  void dispose() {
    disconnectWebSocket();
    _realtimeController.close();
  }
}
