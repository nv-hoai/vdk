import 'package:flutter/material.dart';

import '../../models/device.dart';


class ManualControlTab extends StatefulWidget {
  const ManualControlTab({
    super.key,
    required this.devices,
    required this.onDeviceToggled,
  });

  final List<Device> devices;
  final Future<void> Function(Device device, bool nextState) onDeviceToggled;

  @override
  State<ManualControlTab> createState() => _ManualControlTabState();
}

class _ManualControlTabState extends State<ManualControlTab> {
  late Map<String, bool> _togglingState;

  @override
  void initState() {
    super.initState();
    _togglingState = {};
  }

  Future<void> _toggle(Device device, bool nextState) async {
    setState(() {
      _togglingState[device.id] = true;
    });

    try {
      await widget.onDeviceToggled(device, nextState);
    } finally {
      if (mounted) {
        setState(() {
          _togglingState[device.id] = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.devices.isEmpty) {
      return const Center(child: Text('No devices'));
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: widget.devices.length,
      itemBuilder: (context, index) {
        final device = widget.devices[index];
        final isToggling = _togglingState[device.id] ?? false;

        IconData getIcon() {
          final name = device.name.toLowerCase();
          if (name.contains('lamp') || name.contains('den') || name.contains('đèn')) return Icons.lightbulb;
          if (name.contains('fan') || name.contains('quat') || name.contains('quạt')) return Icons.mode_fan_off; // Wait, there's no mode_fan_off but air is
          return Icons.device_hub;
        }

        return Card(
          margin: const EdgeInsets.only(bottom: 16),
          elevation: device.isOn ? 8 : 2,
          shadowColor: device.isOn ? Theme.of(context).colorScheme.primary.withAlpha((0.4 * 255).round()) : Colors.black12,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
              side: BorderSide(
              color: device.isOn ? Theme.of(context).colorScheme.primary.withAlpha((0.5 * 255).round()) : Colors.transparent,
              width: 1.5,
            ),
          ),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              gradient: device.isOn
                      ? LinearGradient(
                      colors: [
                        Theme.of(context).colorScheme.primary.withAlpha((0.05 * 255).round()),
                        Theme.of(context).colorScheme.secondary.withAlpha((0.1 * 255).round()),
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    )
                  : null,
            ),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              leading: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                    color: device.isOn 
                      ? Theme.of(context).colorScheme.primary.withAlpha((0.15 * 255).round()) 
                      : Colors.grey.shade100,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  getIcon(),
                  color: device.isOn ? Theme.of(context).colorScheme.primary : Colors.grey.shade500,
                  size: 28,
                ),
              ),
              title: Text(
                device.name,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
              ),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 4.0),
                child: Text(
                  device.isOn ? 'Active' : 'Inactive',
                  style: TextStyle(
                    color: device.isOn ? Theme.of(context).colorScheme.primary : Colors.grey.shade500,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              trailing: isToggling
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Switch(
                      value: device.isOn,
                      onChanged: (value) => _toggle(device, value),
                    ),
            ),
          ),
        );
      },
    );
  }
}
