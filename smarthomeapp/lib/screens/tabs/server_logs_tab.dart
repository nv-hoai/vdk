import 'package:flutter/material.dart';

class ServerLogsTab extends StatefulWidget {
  const ServerLogsTab({
    super.key,
    required this.logs,
    this.onRefresh,
    this.onClear,
  });

  final List<Map<String, dynamic>> logs;
  final Future<void> Function()? onRefresh;
  final VoidCallback? onClear;

  @override
  State<ServerLogsTab> createState() => _ServerLogsTabState();
}

class _ServerLogsTabState extends State<ServerLogsTab> {
  DateTime? _parseTimestamp(dynamic value) {
    if (value == null) return null;
    try {
      if (value is int) {
        // handle seconds vs milliseconds
        final v = value.toDouble();
        if (v > 1e12) {
          return DateTime.fromMillisecondsSinceEpoch(value);
        }
        if (v > 1e9) {
          return DateTime.fromMillisecondsSinceEpoch((value * 1000).toInt());
        }
        // small number -> treat as seconds
        return DateTime.fromMillisecondsSinceEpoch(value * 1000);
      }
      if (value is String) {
        return DateTime.tryParse(value);
      }
    } catch (_) {}
    return null;
  }

  Widget _buildMetaSummary(Map<String, dynamic> meta) {
    if (meta.isEmpty) return const SizedBox.shrink();
    final parts = <String>[];
    if (meta['deviceId'] != null) parts.add('${meta['deviceId']}');
    if (meta['deviceName'] != null) parts.add('${meta['deviceName']}');
    if (meta['isOn'] != null) parts.add('isOn=${meta['isOn']}');
    if (meta['trigger'] != null) parts.add('trigger=${meta['trigger']}');
    if (meta['reason'] != null) parts.add('reason=${meta['reason']}');
    return Text(
      parts.join(' • '),
      style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
    );
  }

  @override
  Widget build(BuildContext context) {
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
                  if (widget.onRefresh != null) await widget.onRefresh!();
                },
                icon: const Icon(Icons.refresh),
              ),
              IconButton(
                tooltip: 'Clear',
                onPressed: () {
                  if (widget.onClear != null) widget.onClear!();
                },
                icon: const Icon(Icons.delete_outline, color: Colors.red),
              ),
            ],
          ),
        ),
        Expanded(
          child: widget.logs.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.cloud_off,
                        size: 64,
                        color: Colors.grey.shade300,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'No server logs yet',
                        style: TextStyle(
                          color: Colors.grey.shade500,
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(left: 16, right: 16, bottom: 16),
                  itemCount: widget.logs.length,
                  itemBuilder: (context, index) {
                    // show newest first
                    final log = widget.logs[widget.logs.length - 1 - index];
                    final event = log['event'] ?? log['type'] ?? 'log';
                    final clientTs = log['clientTimestamp'] ?? log['timestamp'];
                    final receivedAt = log['receivedAt'];
                    final ts = _parseTimestamp(receivedAt) ?? _parseTimestamp(clientTs) ?? DateTime.now();

                    final meta = (log['meta'] is Map) ? Map<String, dynamic>.from(log['meta']) : <String, dynamic>{};

                    return Card(
                      margin: const EdgeInsets.only(bottom: 12),
                      elevation: 2,
                      shadowColor: Colors.black12,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(color: Colors.grey.shade200),
                      ),
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        leading: CircleAvatar(
                          backgroundColor: Colors.blue.shade50,
                          child: const Icon(Icons.event, color: Colors.blue),
                        ),
                        title: Text(
                          event,
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SizedBox(height: 6),
                            Text(
                              '${ts.year}-${ts.month.toString().padLeft(2, '0')}-${ts.day.toString().padLeft(2, '0')} ${ts.hour.toString().padLeft(2, '0')}:${ts.minute.toString().padLeft(2, '0')}:${ts.second.toString().padLeft(2, '0')}',
                              style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                            ),
                            const SizedBox(height: 6),
                            _buildMetaSummary(meta),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
