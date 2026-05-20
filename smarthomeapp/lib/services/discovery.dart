import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Simple UDP discovery helper for LAN testing.
/// Sends a broadcast packet and waits for a single JSON reply.
Future<Map<String, dynamic>?> discoverServer({
  int port = 5001,
  Duration timeout = const Duration(seconds: 2),
}) async {
  RawDatagramSocket? socket;
  try {
    socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    socket.broadcastEnabled = true;

    final completer = Completer<Map<String, dynamic>?>();

    socket.listen((event) {
      if (event == RawSocketEvent.read) {
        final dg = socket?.receive();
        if (dg == null) return;
        try {
          final msg = utf8.decode(dg.data);
          final data = jsonDecode(msg) as Map<String, dynamic>;
          if (!completer.isCompleted) completer.complete(data);
        } catch (_) {
          // ignore parse errors
        }
      }
    });

    socket.send(utf8.encode('DISCOVER_SMARTHOME'), InternetAddress('255.255.255.255'), port);

    // Timeout
    Future.delayed(timeout, () {
      if (!completer.isCompleted) completer.complete(null);
    });

    final result = await completer.future;
    return result;
  } finally {
    try {
      socket?.close();
    } catch (_) {}
  }
}
