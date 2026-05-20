import 'package:flutter/foundation.dart';

class AppConfig {
  static const int serverPort = 5000;
  static const String fallbackLanHost = '10.152.235.10';

  /// Web uses the current browser host so Chrome can reach a local server.
  /// Mobile keeps the LAN fallback for manual testing.
  static String get esp32BaseUrl {
    if (kIsWeb) {
      final host = Uri.base.host.isEmpty ? 'localhost' : Uri.base.host;
      return 'http://$host:$serverPort';
    }
    return 'http://$fallbackLanHost:$serverPort';
  }
}
