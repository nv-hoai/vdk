import 'package:flutter/material.dart';

/// Vietnamese voice commands configuration for Whisper AI transcription
class VoiceCommandConfig {
  /// Voice phrases to turn devices ON (Vietnamese - normalized without diacritics)
  static const List<String> onPhrases = [
    'bat',
    'bat len',
    'mo',
  ];

  /// Voice phrases to turn devices OFF (Vietnamese - normalized without diacritics)
  static const List<String> offPhrases = [
    'tat',
    'tat di',
    'dong',
    'thoi',
  ];

  /// Device names and room aliases in Vietnamese (normalized without diacritics)
  static const Map<String, String> vietnameseDeviceAliases = {
    // Rooms (phong)
    'phong khach': 'living room',
    'khach': 'living room',
    'phong ngu 1': 'bedroom 1',
    'phong ngu 2': 'bedroom 2',
    'phong ngu 3': 'bedroom 3',
    'ngu 1': 'bedroom 1',
    'ngu 2': 'bedroom 2',
    'ngu 3': 'bedroom 3',
    
    // Devices
    'den': 'lamp',
    'quat': 'fan',
    'co': 'fan',
    'dieu hoa': 'ac',
    
    // All/Everything
    'tat ca': 'all',
    'tat ca den': 'all lamps',
    'tat ca quat': 'all fans',
    'het': 'all',
  };

  /// Get device name hints for UI
  static String getHints() {
    return '''Ví dụ lệnh:
• "bật đèn phòng khách" (turn on living room lamp)
• "tắt quạt phòng ngủ" (turn off bedroom fan)
• "bật tất cả" (turn on all)
• "tắt hết" (turn off all)''';
  }
}
