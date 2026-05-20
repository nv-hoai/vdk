
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
  /// Map: normalized Vietnamese phrase → device ID
  /// IMPORTANT: longer/more-specific phrases must come first so they are
  /// matched before their substrings (e.g. 'phong ngu 1' before 'phong ngu').
  static const Map<String, String> vietnameseDeviceAliases = {
    // --- Specific lamp aliases (map directly to device IDs) ---
    'den phong khach': 'lamp-1',
    'den phong ngu 1': 'lamp-bed1',
    'den phong ngu 2': 'lamp-bed2',
    'den ngu 1': 'lamp-bed1',
    'den ngu 2': 'lamp-bed2',
    'den ngu': 'lamp-bed1',       // fallback bedroom → bed1
    'den khach': 'lamp-1',

    // --- Room phrases (used when no device type is specified) ---
    'phong khach': 'lamp-1',
    'phong ngu 1': 'lamp-bed1',
    'phong ngu 2': 'lamp-bed2',
    'ngu 1': 'lamp-bed1',
    'ngu 2': 'lamp-bed2',
    'khach': 'lamp-1',

    // --- Generic device type words ---
    'den': 'lamp',
    'quat': 'fan-1',
    'co': 'fan-1',
    'dieu hoa': 'ac',

    // --- All/Everything ---
    'tat ca den': 'all lamps',
    'tat ca quat': 'all fans',
    'tat ca': 'all',
    'het': 'all',
  };

  /// Get device name hints for UI
  static String getHints() {
    return '''Ví dụ lệnh:
• "bật đèn phòng khách"
• "tắt đèn phòng ngủ 1"
• "bật đèn phòng ngủ 2"
• "bật quạt" / "tắt quạt"
• "bật tất cả" / "tắt hết"''';
  }
}
