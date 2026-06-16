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
            Image.asset('assets/logo.png', height: 28),
            const SizedBox(width: 10),
            const Text('Coordi Vysor'),
          ],
        ),
        actions: [
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
              SizedBox(
                width: 340,
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
              const Text('Dispositivos',
                  style: TextStyle(
                      color: Color(0xFFFF5722),
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
      title: Text(device.model ?? device.serial),
      subtitle: Text(
        ready ? device.serial : '${device.serial} · ${device.state}',
        style: TextStyle(
            color: ready ? null : Colors.orangeAccent, fontSize: 12),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (running)
            IconButton(
              tooltip: 'Detener mirror',
              icon: const Icon(Icons.stop_circle, color: Colors.redAccent),
              onPressed: () => controller.stop(device.serial),
            )
          else
            IconButton(
              tooltip: ready ? 'Iniciar mirror' : 'Dispositivo no listo',
              icon: const Icon(Icons.play_circle_fill),
              onPressed: ready ? () => controller.launch(device) : null,
            ),
          if (isTcp)
            IconButton(
              tooltip: 'Desconectar Wi-Fi',
              icon: const Icon(Icons.link_off, color: Colors.orangeAccent),
              onPressed: () => _disconnect(context),
            ),
        ],
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
