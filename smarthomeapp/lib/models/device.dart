class Device {
  final String id;
  final String name;
  final String type;
  final bool isOn;
  final DateTime? updatedAt;

  const Device({
    required this.id,
    required this.name,
    required this.type,
    required this.isOn,
    required this.updatedAt,
  });

  Device copyWith({
    String? id,
    String? name,
    String? type,
    bool? isOn,
    DateTime? updatedAt,
  }) {
    return Device(
      id: id ?? this.id,
      name: name ?? this.name,
      type: type ?? this.type,
      isOn: isOn ?? this.isOn,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  factory Device.fromJson(Map<String, dynamic> json) {
    final dynamic stateValue = json.containsKey('isOn')
        ? json['isOn']
        : json.containsKey('state')
            ? json['state']
            : false;

    return Device(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? 'Unknown',
      type: json['type']?.toString() ?? 'unknown',
      isOn: stateValue == true || stateValue == 1 || stateValue == 'on',
      updatedAt: DateTime.tryParse(json['updatedAt']?.toString() ?? ''),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'type': type,
      'isOn': isOn,
      'updatedAt': updatedAt?.toUtc().toIso8601String(),
    };
  }
}
