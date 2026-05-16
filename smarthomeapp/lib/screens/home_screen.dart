import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import '../config/app_config.dart';
import '../config/voice_commands.dart';
import '../models/device.dart';
import '../services/esp32_client.dart';
import 'tabs/device_state_log_tab.dart';
import 'tabs/manual_control_tab.dart';
import 'tabs/voice_control_tab.dart';
import 'tabs/server_logs_tab.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    {
  final Esp32Client _client = Esp32Client(baseUrl: AppConfig.esp32BaseUrl);

  int _currentIndex = 1;
  bool _loading = true;
  String? _error;
  List<Device> _devices = const [];
  List<DeviceLog> _deviceLogs = [];
  List<Map<String, dynamic>> _serverLogs = [];

  @override
  void initState() {
    super.initState();
    _loadDevices();
  }

  Future<void> _loadServerLogs() async {
    try {
      final logs = await _client.fetchLogs(limit: 200);
      if (!mounted) return;
      setState(() {
        _serverLogs = logs;
      });
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to load server logs: $error')),
      );
    }
  }

  @override
  void dispose() {
    super.dispose();
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
        // Log device state change
        _deviceLogs.add(
          DeviceLog(
            deviceName: device.name,
            deviceId: device.id,
            newState: nextState,
            timestamp: DateTime.now(),
          ),
        );
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
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Smart Home')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Smart Home')),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 16),
              Text(_error!),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _loadDevices,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    final titles = ['Voice Control', 'Smart Home', 'Device Log', 'Server Log'];
    return Scaffold(
      appBar: AppBar(
        title: Text(titles[_currentIndex]),
        elevation: 0,
      ),
      body: IndexedStack(
        index: _currentIndex,
        children: [
          VoiceControlTab(
            onCommandRecognized: _handleVoiceCommand,
            onListeningStarted: () {},
            onListeningStopped: () {},
          ),
          ManualControlTab(
            devices: _devices,
            onDeviceToggled: _toggleDevice,
          ),
          DeviceStateLogTab(
            logs: _deviceLogs,
            onClearLogs: () {
              setState(() {
                _deviceLogs.clear();
              });
            },
          ),
          ServerLogsTab(
            logs: _serverLogs,
            onRefresh: _loadServerLogs,
            onClear: () {
              setState(() {
                _serverLogs.clear();
              });
            },
          ),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) {
          setState(() {
            _currentIndex = index;
          });
          // Load server logs when user opens the Server Log tab
          if (index == 3) {
            _loadServerLogs();
          }
        },
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.mic_none),
            activeIcon: Icon(Icons.mic),
            label: 'Voice',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.space_dashboard_outlined),
            activeIcon: Icon(Icons.space_dashboard),
            label: 'Control',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.history_outlined),
            activeIcon: Icon(Icons.history),
            label: 'Log',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.cloud_outlined),
            activeIcon: Icon(Icons.cloud),
            label: 'Server',
          ),
        ],
      ),
    );
  }

  Future<void> _handleVoiceCommand(String words) async {
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
