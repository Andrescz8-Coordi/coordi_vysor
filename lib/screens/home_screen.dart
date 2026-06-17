import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../models/device.dart';
import '../services/adb_service.dart';
import 'options_panel.dart';
import 'wifi_wizard.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Image.asset(
              controller.isDark ? 'assets/logo_dark.png' : 'assets/logo_light.png',
              height: 28,
            ),
            const SizedBox(width: 10),
            const Text('Coordi Vysor'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Cambiar tema',
            icon: Icon(controller.isDark ? Icons.light_mode : Icons.dark_mode),
            onPressed: controller.toggleTheme,
          ),
          IconButton(
            tooltip: 'Inspector de red',
            icon: const Icon(Icons.lan),
            onPressed: null,
          ),
          IconButton(
            tooltip: 'Asistente de conexión Wi-Fi',
            icon: const Icon(Icons.wifi),
            onPressed: () => WifiWizard.show(context, controller),
          ),
          IconButton(
            tooltip: 'Refrescar',
            icon: const Icon(Icons.refresh),
            onPressed: controller.refresh,
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: 340,
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                child: _DeviceList(controller: controller),
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: OptionsPanel(controller: controller),
              ),
            ],
          );
        },
      ),
    );
  }

}

class _DeviceList extends StatelessWidget {
  const _DeviceList({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final devices = controller.devices;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Text('Dispositivos',
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.bold,
                      fontSize: 16)),
              const Spacer(),
              if (controller.loading)
                const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2)),
            ],
          ),
        ),
        if (controller.error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(controller.error!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
          ),
        Expanded(
          child: devices.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'No hay dispositivos.\n\nConecta por USB (con depuración USB activa)\no usa Wi-Fi con el botón de arriba.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: devices.length,
                  itemBuilder: (context, i) =>
                      _DeviceTile(controller: controller, device: devices[i]),
                ),
        ),
      ],
    );
  }
}

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({required this.controller, required this.device});

  final AppController controller;
  final Device device;

  @override
  Widget build(BuildContext context) {
    final running = controller.isRunning(device.serial);
    final ready = device.isReady;
    final isTcp = !AdbService.isUsbSerial(device.serial);

    return ListTile(
      leading: Icon(
        running
            ? Icons.cast_connected
            : isTcp
                ? Icons.wifi
                : Icons.smartphone,
        color: running
            ? const Color(0xFF3DDC84)
            : ready
                ? null
                : Colors.orangeAccent,
      ),
      title: Text(device.model ?? device.serial,
          overflow: TextOverflow.ellipsis),
      subtitle: Text(
        ready ? device.serial : '${device.serial} · ${device.state}',
        style: TextStyle(
            color: ready ? null : Colors.orangeAccent, fontSize: 12),
      ),
      trailing: SizedBox(
        height: 40,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (running && controller.isRecording(device.serial))
              _RecordingControls(
                serial: device.serial,
                controller: controller,
              )
            else if (running)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _SmallIconButton(
                    tooltip: 'Grabar',
                    icon: Icons.fiber_manual_record,
                    color: Theme.of(context).colorScheme.primary,
                    onPressed: () => controller.startRecording(device.serial),
                  ),
                  _SmallIconButton(
                    tooltip: 'Detener mirror',
                    icon: Icons.stop_circle,
                    color: Colors.redAccent,
                    onPressed: () => controller.stop(device.serial),
                  ),
                ],
              )
            else
              _SmallIconButton(
                tooltip: ready ? 'Iniciar mirror' : 'Dispositivo no listo',
                icon: Icons.play_circle_fill,
                color: Theme.of(context).colorScheme.primary,
                onPressed: ready ? () => controller.launch(device) : null,
              ),
            if (isTcp)
              _SmallIconButton(
                tooltip: 'Desconectar Wi-Fi',
                icon: Icons.link_off,
                color: Theme.of(context).colorScheme.primary,
                onPressed: () => _disconnect(context),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _disconnect(BuildContext context) async {
    final msg = await controller.disconnectTcp(device.serial);
    if (context.mounted && msg.isNotEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg)));
    }
  }
}

/// Compact icon button (24×24 instead of default 48×48).
class _SmallIconButton extends StatelessWidget {
  const _SmallIconButton({
    required this.tooltip,
    required this.icon,
    required this.color,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final Color color;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 28,
        height: 28,
        child: IconButton(
          tooltip: tooltip,
          icon: Icon(icon, size: 18, color: color),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
          onPressed: onPressed,
        ),
      );
}

class _RecordingControls extends StatelessWidget {
  const _RecordingControls({
    required this.serial,
    required this.controller,
  });

  final String serial;
  final AppController controller;

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '${d.inHours.toString().padLeft(2, '0')}:$m:$s';
  }

  Future<void> _handleStop(BuildContext context) async {
    // Capture the navigator before the dialog is shown.
    final nav = Navigator.of(context, rootNavigator: true);

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: Card(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 28, vertical: 22),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
                SizedBox(width: 16),
                Text('Generando video…'),
              ],
            ),
          ),
        ),
      ),
    );

    await controller.stopRecording(serial);

    // Pop the processing dialog. Don't check context.mounted because the
    // widget may have been rebuilt (recording state changed).
    nav.pop();
  }

  @override
  Widget build(BuildContext context) {
    final elapsed = controller.recordElapsed;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.fiber_manual_record, color: Colors.redAccent, size: 14),
        const SizedBox(width: 3),
        Text(
          _formatDuration(elapsed),
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(width: 2),
        _SmallIconButton(
          tooltip: 'Guardar',
          icon: Icons.stop_circle,
          color: Colors.redAccent,
          onPressed: () => _handleStop(context),
        ),
        _SmallIconButton(
          tooltip: 'Cancelar',
          icon: Icons.delete_outline,
          color: Colors.grey,
          onPressed: () => controller.cancelRecording(serial),
        ),
      ],
    );
  }
}
