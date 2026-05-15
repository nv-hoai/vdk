import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/device.dart';

class Esp32Client {
  Esp32Client({
    required this.baseUrl,
    http.Client? httpClient,
  }) : _httpClient = httpClient ?? http.Client();

  final String baseUrl;
  final http.Client _httpClient;

  Future<List<Device>> fetchDevices() async {
    final uri = Uri.parse('$baseUrl/devices');
    final response = await _httpClient
        .get(uri)
        .timeout(const Duration(seconds: 5));

    if (response.statusCode != 200) {
      throw Exception('Failed to fetch devices (${response.statusCode})');
    }

    final dynamic decoded = jsonDecode(response.body);
    if (decoded is! List) {
      throw Exception('Invalid devices response');
    }

    return decoded
        .whereType<Map<String, dynamic>>()
        .map(Device.fromJson)
        .toList();
  }

  Future<Device> setDeviceState(String id, bool isOn) async {
    final uri = Uri.parse('$baseUrl/devices/$id/state');
    final response = await _httpClient
        .post(
          uri,
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({'isOn': isOn}),
        )
        .timeout(const Duration(seconds: 5));

    if (response.statusCode != 200) {
      throw Exception('Failed to update device (${response.statusCode})');
    }

    final dynamic decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw Exception('Invalid device response');
    }

    return Device.fromJson(decoded);
  }
}
