import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import '../config/app_config.dart';
import '../config/voice_commands.dart';
import '../models/device.dart';
import '../services/esp32_client.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final Esp32Client _client = Esp32Client(baseUrl: AppConfig.esp32BaseUrl);
  final stt.SpeechToText _speech = stt.SpeechToText();

  bool _loading = true;
  String? _error;
  List<Device> _devices = const [];
  bool _speechAvailable = false;
  bool _isListening = false;
  String _lastWords = '';
  String _speechError = '';

  @override
  void initState() {
    super.initState();
    _loadDevices();
    _initSpeech();
  }

  @override
  void dispose() {
    _speech.stop();
    super.dispose();
  }

  Future<void> _initSpeech() async {
    final available = await _speech.initialize(
      onStatus: _onSpeechStatus,
      onError: _onSpeechError,
    );

    if (!mounted) {
      return;
    }

    setState(() {
      _speechAvailable = available;
      if (!available) {
        _speechError = 'Speech recognition is not available.';
      }
    });
  }

  void _onSpeechStatus(String status) {
    if (!mounted) {
      return;
    }

    setState(() {
      _isListening = _speech.isListening;
    });
  }

  void _onSpeechError(Object error) {
    if (!mounted) {
      return;
    }

    setState(() {
      _speechError = error.toString();
      _isListening = false;
    });
  }

  Future<void> _loadDevices() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final devices = await _client.fetchDevices();
      setState(() {
        _devices = devices;
        _loading = false;
      });
    } catch (error) {
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  Future<void> _toggleDevice(Device device, bool nextState) async {
    final previous = device;
    setState(() {
      _devices = _devices
          .map((item) => item.id == device.id
              ? item.copyWith(isOn: nextState)
              : item)
          .toList();
    });

    try {
      final updated = await _client.setDeviceState(device.id, nextState);
      setState(() {
        _devices = _devices
            .map((item) => item.id == updated.id ? updated : item)
            .toList();
      });
    } catch (_) {
      setState(() {
        _devices = _devices
            .map((item) => item.id == previous.id ? previous : item)
            .toList();
      });

      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to update device state.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Smart Home'),
      ),
      body: RefreshIndicator(
        onRefresh: _loadDevices,
        child: _buildBody(),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _speechAvailable ? _toggleListening : _initSpeech,
        icon: Icon(_isListening ? Icons.stop : Icons.mic),
        label: Text(_isListening ? 'Stop' : 'Listen'),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            'Error: $_error',
            style: const TextStyle(color: Colors.redAccent),
          ),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: _loadDevices,
            child: const Text('Retry'),
          ),
        ],
      );
    }

    if (_devices.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(24),
        children: const [
          Text('No devices found.'),
        ],
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 12),
      itemCount: _devices.length + 1,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        if (index == 0) {
          return _buildSpeechPanel();
        }

        final device = _devices[index - 1];
        return ListTile(
          leading: Icon(device.isOn ? Icons.lightbulb : Icons.lightbulb_outline),
          title: Text(device.name),
          subtitle: Text(_buildSubtitle(device)),
          trailing: Switch(
            value: device.isOn,
            onChanged: (value) => _toggleDevice(device, value),
          ),
        );
      },
    );
  }

  Widget _buildSpeechPanel() {
    final status = _isListening
        ? 'Listening...'
        : _speechAvailable
            ? 'Ready'
            : 'Unavailable';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(_isListening ? Icons.mic : Icons.mic_none),
                  const SizedBox(width: 8),
                  Text('Voice control: $status'),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                _lastWords.isEmpty
                    ? VoiceCommandConfig.getHints()
                    : 'Heard: $_lastWords',
              ),
              if (_speechError.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  _speechError,
                  style: const TextStyle(color: Colors.redAccent),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _toggleListening() async {
    if (_isListening) {
      await _speech.stop();
      if (!mounted) {
        return;
      }
      setState(() {
        _isListening = false;
      });
      return;
    }

    if (!_speechAvailable) {
      await _initSpeech();
    }

    if (!_speechAvailable) {
      _showSnackBar('Speech recognition is not available.');
      return;
    }

    setState(() {
      _speechError = '';
      _lastWords = '';
    });

    await _speech.listen(
      onResult: _onSpeechResult,
      listenFor: const Duration(seconds: 8),
      pauseFor: const Duration(seconds: 2),
      localeId: 'vi_VN',
    );

    if (!mounted) {
      return;
    }

    setState(() {
      _isListening = true;
    });
  }

  void _onSpeechResult(Object result) {
    final dynamicResult = result as dynamic;
    final words = (dynamicResult.recognizedWords ?? '').toString();
    final isFinal = dynamicResult.finalResult == true;

    setState(() {
      _lastWords = words;
    });

    if (isFinal) {
      _handleCommand(_lastWords);
    }
  }

  Future<void> _handleCommand(String words) async {
    final command = _parseCommand(words);
    if (command == null) {
      _showSnackBar('Command not recognized.');
      return;
    }

    if (command.applyAll) {
      List<Device> targetDevices = _devices;
      
      if (command.filterType == 'lamps') {
        targetDevices = _devices.where((d) => d.name.toLowerCase().contains('lamp') || d.name.toLowerCase().contains('den')).toList();
      } else if (command.filterType == 'fans') {
        targetDevices = _devices.where((d) => d.name.toLowerCase().contains('fan') || d.name.toLowerCase().contains('quat')).toList();
      }
      
      for (final device in targetDevices) {
        if (device.isOn != command.isOn) {
          await _toggleDevice(device, command.isOn);
        }
      }
      
      final typeStr = command.filterType == 'lamps' ? 'all lamps' : 
                      command.filterType == 'fans' ? 'all fans' : 'all devices';
      _showSnackBar('Applied to $typeStr.');
      return;
    }

    final device = command.device;
    if (device == null) {
      _showSnackBar('Device not found.');
      return;
    }

    await _toggleDevice(device, command.isOn);
    _showSnackBar('Updated ${device.name}.');
  }

  _SpeechCommand? _parseCommand(String words) {
    final normalized = _normalizeText(words);
    if (normalized.isEmpty) {
      return null;
    }

    final action = _parseAction(normalized);
    if (action == null) {
      return null;
    }

    // Check for all devices types
    if (normalized.contains('tat ca quat') || normalized.contains('het quat')) {
      return _SpeechCommand(isOn: action, applyAll: true, filterType: 'fans');
    }
    if (normalized.contains('tat ca den') || normalized.contains('het den')) {
      return _SpeechCommand(isOn: action, applyAll: true, filterType: 'lamps');
    }
    if (normalized.contains('all') || 
        normalized.contains('everything') ||
        normalized.contains('tat ca') ||
        normalized.contains('het')) {
      return _SpeechCommand(isOn: action, applyAll: true, filterType: 'all');
    }

    final device = _findDeviceByName(normalized);
    return _SpeechCommand(isOn: action, device: device, applyAll: false);
  }

  bool? _parseAction(String normalized) {
    if (_containsAny(normalized, VoiceCommandConfig.onPhrases) ||
        _containsWord(normalized, 'on')) {
      return true;
    }
    if (_containsAny(normalized, VoiceCommandConfig.offPhrases) ||
        _containsWord(normalized, 'off')) {
      return false;
    }

    return null;
  }

  Device? _findDeviceByName(String normalized) {
    // Apply Vietnamese aliases
    String searchText = _applyVietnameseAliases(normalized);

    Device? bestMatch;
    var bestScore = 0;

    for (final device in _devices) {
      final name = _normalizeText(device.name);
      if (name.isEmpty) {
        continue;
      }

      if (searchText.contains(name)) {
        final score = name.length;
        if (score > bestScore) {
          bestScore = score;
          bestMatch = device;
        }
        continue;
      }

      final tokens = name.split(' ');
      for (final token in tokens) {
        if (token.length < 3) {
          continue;
        }
        if (searchText.contains(token)) {
          final score = token.length;
          if (score > bestScore) {
            bestScore = score;
            bestMatch = device;
          }
        }
      }
    }

    return bestMatch;
  }

  String _applyVietnameseAliases(String text) {
    String result = text;
    for (final entry in VoiceCommandConfig.vietnameseDeviceAliases.entries) {
      result = result.replaceAll(entry.key, entry.value);
    }
    return result;
  }

  String _normalizeText(String input) {
    final stripped = _stripDiacritics(input);
    return stripped
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9 ]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String _stripDiacritics(String input) {
    const map = {
      'a': 'a',
      'á': 'a',
      'à': 'a',
      'ả': 'a',
      'ã': 'a',
      'ạ': 'a',
      'ă': 'a',
      'ắ': 'a',
      'ằ': 'a',
      'ẳ': 'a',
      'ẵ': 'a',
      'ặ': 'a',
      'â': 'a',
      'ấ': 'a',
      'ầ': 'a',
      'ẩ': 'a',
      'ẫ': 'a',
      'ậ': 'a',
      'e': 'e',
      'é': 'e',
      'è': 'e',
      'ẻ': 'e',
      'ẽ': 'e',
      'ẹ': 'e',
      'ê': 'e',
      'ế': 'e',
      'ề': 'e',
      'ể': 'e',
      'ễ': 'e',
      'ệ': 'e',
      'i': 'i',
      'í': 'i',
      'ì': 'i',
      'ỉ': 'i',
      'ĩ': 'i',
      'ị': 'i',
      'o': 'o',
      'ó': 'o',
      'ò': 'o',
      'ỏ': 'o',
      'õ': 'o',
      'ọ': 'o',
      'ô': 'o',
      'ố': 'o',
      'ồ': 'o',
      'ổ': 'o',
      'ỗ': 'o',
      'ộ': 'o',
      'ơ': 'o',
      'ớ': 'o',
      'ờ': 'o',
      'ở': 'o',
      'ỡ': 'o',
      'ợ': 'o',
      'u': 'u',
      'ú': 'u',
      'ù': 'u',
      'ủ': 'u',
      'ũ': 'u',
      'ụ': 'u',
      'ư': 'u',
      'ứ': 'u',
      'ừ': 'u',
      'ử': 'u',
      'ữ': 'u',
      'ự': 'u',
      'y': 'y',
      'ý': 'y',
      'ỳ': 'y',
      'ỷ': 'y',
      'ỹ': 'y',
      'ỵ': 'y',
      'đ': 'd',
    };

    final buffer = StringBuffer();
    for (final rune in input.runes) {
      final char = String.fromCharCode(rune);
      buffer.write(map[char] ?? char);
    }
    return buffer.toString();
  }

  bool _containsAny(String text, List<String> phrases) {
    for (final phrase in phrases) {
      if (text.contains(phrase)) {
        return true;
      }
    }
    return false;
  }

  bool _containsWord(String text, String word) {
    return RegExp('\\b$word\\b').hasMatch(text);
  }

  void _showSnackBar(String message) {
    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  String _buildSubtitle(Device device) {
    final status = device.isOn ? 'On' : 'Off';
    final typeLabel = device.type.isNotEmpty ? device.type : 'unknown';
    final updatedAt = device.updatedAt;
    if (updatedAt == null) {
      return '$status • $typeLabel';
    }

    final local = updatedAt.toLocal();
    String twoDigit(int value) => value.toString().padLeft(2, '0');
    final timestamp =
        '${local.year}-${twoDigit(local.month)}-${twoDigit(local.day)} '
        '${twoDigit(local.hour)}:${twoDigit(local.minute)}';
    return '$status • $typeLabel • $timestamp';
  }
}

class _SpeechCommand {
  _SpeechCommand({
    required this.isOn,
    this.device,
    required this.applyAll,
    this.filterType = 'all',
  });

  final bool isOn;
  final Device? device;
  final bool applyAll;
  final String filterType; // 'all', 'lamps', 'fans'
}
