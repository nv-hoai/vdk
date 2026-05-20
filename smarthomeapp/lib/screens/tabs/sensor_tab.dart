import 'package:flutter/material.dart';

class SensorTab extends StatelessWidget {
  const SensorTab({
    super.key,
    required this.readings,
    this.onRefresh,
    this.onClear,
  });

  final List<Map<String, dynamic>> readings;
  final Future<void> Function()? onRefresh;
  final VoidCallback? onClear;

  String _formatTimestamp(Map<String, dynamic> reading) {
    final raw = reading['receivedAt']?.toString();
    if (raw == null || raw.isEmpty) {
      return 'Unknown time';
    }
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) {
      return raw;
    }
    final y = parsed.year.toString();
    final m = parsed.month.toString().padLeft(2, '0');
    final d = parsed.day.toString().padLeft(2, '0');
    final h = parsed.hour.toString().padLeft(2, '0');
    final min = parsed.minute.toString().padLeft(2, '0');
    final s = parsed.second.toString().padLeft(2, '0');
    return '$y-$m-$d $h:$min:$s';
  }

  String _valueLabel(dynamic value, String suffix) {
    if (value == null) return '--';
    if (value is num) {
      return '${value.toStringAsFixed(value is int ? 0 : 1)}$suffix';
    }
    return '$value$suffix';
  }

  Map<String, dynamic>? _latestReading() {
    if (readings.isEmpty) return null;
    return readings.first;
  }

  @override
  Widget build(BuildContext context) {
    final latest = _latestReading();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              IconButton(
                tooltip: 'Refresh',
                onPressed: () async {
                  if (onRefresh != null) {
                    await onRefresh!();
                  }
                },
                icon: const Icon(Icons.refresh),
              ),
              IconButton(
                tooltip: 'Clear',
                onPressed: onClear,
                icon: const Icon(Icons.delete_outline, color: Colors.red),
              ),
            ],
          ),
        ),
        Expanded(
          child: readings.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.sensors_off, size: 64, color: Colors.grey.shade300),
                      const SizedBox(height: 16),
                      Text(
                        'No sensor data yet',
                        style: TextStyle(
                          color: Colors.grey.shade500,
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.only(left: 16, right: 16, bottom: 16),
                  children: [
                    if (latest != null) ...[
                      Card(
                        elevation: 2,
                        shadowColor: Colors.black12,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                          side: BorderSide(color: Colors.green.shade200),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  CircleAvatar(
                                    backgroundColor: Colors.green.shade50,
                                    child: const Icon(Icons.sensors, color: Colors.green),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        const Text(
                                          'Latest Sensor Snapshot',
                                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          _formatTimestamp(latest),
                                          style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 16),
                              _metricRow('Temperature', _valueLabel(latest['temperature'], '°C'), Icons.thermostat, Colors.orange),
                              const SizedBox(height: 10),
                              _metricRow('Humidity', _valueLabel(latest['humidity'], '%'), Icons.water_drop, Colors.blue),
                              const SizedBox(height: 10),
                              _metricRow('Light', _valueLabel(latest['light'], ''), Icons.light_mode, Colors.amber),
                              const SizedBox(height: 10),
                              _metricRow('Gas', _valueLabel(latest['gas'], ''), Icons.gas_meter, Colors.red),
                              const SizedBox(height: 10),
                              _metricRow('PIR', latest['pir'] == 1 ? 'Motion detected' : 'No motion', Icons.motion_photos_on, Colors.purple),
                              const SizedBox(height: 10),
                              _metricRow('Buzzer', latest['buzzerActive'] == true ? 'ON' : 'OFF', Icons.notifications_active, Colors.teal),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                    Text(
                      'Recent sensor records',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Colors.grey.shade700),
                    ),
                    const SizedBox(height: 8),
                    ...readings.map(
                      (reading) => Card(
                        margin: const EdgeInsets.only(bottom: 12),
                        elevation: 1,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                          side: BorderSide(color: Colors.grey.shade200),
                        ),
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: Colors.green.shade50,
                            child: const Icon(Icons.data_usage, color: Colors.green),
                          ),
                          title: Text(_formatTimestamp(reading)),
                          subtitle: Padding(
                            padding: const EdgeInsets.only(top: 6.0),
                            child: Text(
                              'Temp ${_valueLabel(reading['temperature'], '°C')} • Hum ${_valueLabel(reading['humidity'], '%')} • Light ${_valueLabel(reading['light'], '')} • Gas ${_valueLabel(reading['gas'], '')}',
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _metricRow(String label, String value, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Text(
            value,
            style: TextStyle(fontWeight: FontWeight.bold, color: color),
          ),
        ],
      ),
    );
  }
}