import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import '../../config/voice_commands.dart';

// Speech recognition constants
const String _localeId = 'vi_VN';
const Duration _listenDuration = Duration(seconds: 8);
const Duration _pauseDuration = Duration(seconds: 2);

class VoiceControlTab extends StatefulWidget {
  const VoiceControlTab({
    super.key,
    required this.onCommandRecognized,
    required this.onListeningStarted,
    required this.onListeningStopped,
  });

  final Function(String) onCommandRecognized;
  final VoidCallback onListeningStarted;
  final VoidCallback onListeningStopped;

  @override
  State<VoiceControlTab> createState() => _VoiceControlTabState();
}

class _VoiceControlTabState extends State<VoiceControlTab> {
  final stt.SpeechToText _speech = stt.SpeechToText();
  
  bool _speechAvailable = false;
  bool _isListening = false;
  String _lastWords = '';
  String _speechError = '';

  @override
  void initState() {
    super.initState();
    _initSpeech();
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
    if (status == 'listening') {
      widget.onListeningStarted();
      if (mounted) {
        setState(() => _isListening = true);
      }
    } else if (status == 'done' || status == 'notListening') {
      widget.onListeningStopped();
      if (mounted) {
        setState(() => _isListening = false);
      }
    }
  }

  void _onSpeechError(Object error) {
    setState(() {
      _speechError = error.toString();
    });
  }

  Future<void> _toggleListening() async {
    if (!_speechAvailable) {
      await _initSpeech();
      return;
    }

    if (_isListening) {
      await _speech.stop();
    } else {
      setState(() {
        _speechError = '';
        _lastWords = '';
      });

      await _speech.listen(
        onResult: _onSpeechResult,
        listenFor: _listenDuration,
        pauseFor: _pauseDuration,
        localeId: _localeId,
      );
    }
  }

  void _onSpeechResult(dynamic result) {
    final words = (result.recognizedWords ?? '').toString();
    final isFinal = result.finalResult == true;

    setState(() {
      _lastWords = words;
    });

    if (isFinal) {
      widget.onCommandRecognized(words);
    }
  }

  @override
  void dispose() {
    _speech.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final status = _isListening
        ? 'Listening... 🎤'
        : _speechError.isNotEmpty
            ? 'Error: $_speechError'
            : 'Ready to listen';

    return Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Status
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              decoration: BoxDecoration(
                color: _isListening ? Colors.blue.shade50 : Colors.grey.shade100,
                borderRadius: BorderRadius.circular(30),
                border: Border.all(
                  color: _isListening ? Colors.blue.shade200 : Colors.grey.shade300,
                ),
              ),
              child: Text(
                status,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: _isListening ? Colors.blue.shade700 : Colors.grey.shade700,
                ),
              ),
            ),
            const SizedBox(height: 48),

            // Listening Button (Big)
            GestureDetector(
              onTap: _speechAvailable ? _toggleListening : _initSpeech,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                width: _isListening ? 150 : 130,
                height: _isListening ? 150 : 130,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: _isListening
                        ? [Colors.red.shade400, Colors.red.shade600]
                        : [
                            Theme.of(context).colorScheme.primary,
                            Theme.of(context).colorScheme.secondary,
                          ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: (_isListening ? Colors.red : Theme.of(context).colorScheme.primary)
                          .withAlpha((0.4 * 255).round()),
                      blurRadius: _isListening ? 30 : 20,
                      spreadRadius: _isListening ? 10 : 5,
                    ),
                  ],
                ),
                child: Center(
                  child: Icon(
                    _isListening ? Icons.stop_rounded : Icons.mic_rounded,
                    size: 60,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 48),

            // Last heard text
            if (_lastWords.isNotEmpty)
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 24),
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withAlpha((0.05 * 255).round()),
                      blurRadius: 20,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    Text(
                      'Heard Command',
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey.shade500,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1.2,
                        textBaseline: TextBaseline.alphabetic,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _lastWords,
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 32),

            // Command hints
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 24),
              padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.secondary.withAlpha((0.1 * 255).round()),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: Theme.of(context).colorScheme.secondary.withAlpha((0.3 * 255).round()),
                ),
              ),
              child: Text(
                VoiceCommandConfig.getHints(),
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.grey.shade800,
                  height: 1.6,
                ),
              ),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}
