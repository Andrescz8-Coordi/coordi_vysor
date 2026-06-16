class Device {
  final String serial;
  final String state; // device, offline, unauthorized
  final String? model;

  const Device({required this.serial, required this.state, this.model});

  bool get isReady => state == 'device';

  String get label => model != null ? '$model ($serial)' : serial;

  @override
  bool operator ==(Object other) =>
      other is Device && other.serial == serial && other.state == state;

  @override
  int get hashCode => Object.hash(serial, state);
}
