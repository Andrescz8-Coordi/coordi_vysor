import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../models/device.dart';

/// Didactic 3-step wizard to connect a device over Wi-Fi.
///
/// Mirrors the manual flow, showing each adb command as it runs:
///   1. `adb -s <serial> tcpip 5555`   (device on USB)
///   2. `adb connect <ip>:5555`        (device still on USB)
///   3. unplug USB — device keeps working over Wi-Fi
class WifiWizard extends StatefulWidget {
  const WifiWizard({super.key, required this.controller});

  final AppController controller;

  static Future<void> show(BuildContext context, AppController controller) {
    return showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640, maxHeight: 640),
          child: WifiWizard(controller: controller),
        ),
      ),
    );
  }

  @override
  State<WifiWizard> createState() => _WifiWizardState();
}

class _WifiWizardState extends State<WifiWizard> {
  static const _port = 5555;

  int _step = 0;
  Device? _usbDevice;
  final _ipController = TextEditingController();
  bool _busy = false;
  String? _log;
  bool _tcpipOk = false;
  bool _connected = false;

  AppController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    final usb = c.usbDevices;
    if (usb.isNotEmpty) _usbDevice = usb.first;
  }

  @override
  void dispose() {
    _ipController.dispose();
    super.dispose();
  }

  String get _hostPort => '${_ipController.text.trim()}:$_port';

  Future<void> _runStep1() async {
    if (_usbDevice == null) return;
    setState(() {
      _busy = true;
      _log = null;
    });
    try {
      final msg = await c.enableTcpip(_usbDevice!.serial, port: _port);
      // Try to pre-fill the IP for step 2.
      final ip = await c.detectDeviceIp(_usbDevice!.serial);
      if (ip != null) _ipController.text = ip;
      setState(() {
        _tcpipOk = true;
        _log = msg + (ip != null ? '\nIP detectada: $ip' : '');
        _step = 1;
      });
    } catch (e) {
      setState(() => _log = 'Error: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _runStep2() async {
    if (_ipController.text.trim().isEmpty) return;
    setState(() {
      _busy = true;
      _log = null;
    });
    try {
      final msg = await c.connectTcp(_hostPort);
      final ok = msg.toLowerCase().contains('connected');
      setState(() {
        _connected = ok;
        _log = msg;
        if (ok) _step = 2;
      });
    } catch (e) {
      setState(() => _log = 'Error: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final usb = c.usbDevices;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 12, 0),
          child: Row(
            children: [
              const Icon(Icons.wifi, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Text('Conectar por Wi-Fi',
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                        fontSize: 18,
                        fontWeight: FontWeight.bold)),
              ),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
        ),
        Expanded(
          child: Stepper(
            currentStep: _step,
            controlsBuilder: (context, details) => const SizedBox.shrink(),
            onStepTapped: (s) {
              // Allow going back to review earlier steps.
              if (s < _step) setState(() => _step = s);
            },
            steps: [
              _stepUsb(usb),
              _stepConnect(),
              _stepDone(),
            ],
          ),
        ),
        if (_log != null)
          Container(
            margin: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.black26,
              borderRadius: BorderRadius.circular(8),
            ),
            width: double.infinity,
            child: SelectableText(
              _log!,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
      ],
    );
  }

  Step _stepUsb(List<Device> usb) {
    return Step(
      title: const Text('1 · Activar modo Wi-Fi (con USB)'),
      isActive: _step >= 0,
      state: _tcpipOk ? StepState.complete : StepState.indexed,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Conecta el teléfono por USB (con depuración USB activa). '
            'Esto reinicia el adb del teléfono para que escuche por red.',
          ),
          const SizedBox(height: 12),
          if (usb.isEmpty)
            const _Hint(
              icon: Icons.usb_off,
              text: 'No hay dispositivo USB listo. Conéctalo y acepta el '
                  'diálogo "¿Permitir depuración USB?" en el teléfono.',
              warn: true,
            )
          else
            DropdownButtonFormField<Device>(
              value: _usbDevice,
              decoration: const InputDecoration(
                labelText: 'Dispositivo USB',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final d in usb)
                  DropdownMenuItem(value: d, child: Text(d.label)),
              ],
              onChanged: (d) => setState(() => _usbDevice = d),
            ),
          const SizedBox(height: 12),
          _CommandChip('adb -s ${_usbDevice?.serial ?? '<serial>'} tcpip $_port'),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed:
                (usb.isEmpty || _busy) ? null : _runStep1,
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.play_arrow),
            label: const Text('Activar modo TCP/IP'),
          ),
        ],
      ),
    );
  }

  Step _stepConnect() {
    return Step(
      title: const Text('2 · Conectar por IP (con USB aún)'),
      isActive: _step >= 1,
      state: _connected
          ? StepState.complete
          : (_step >= 1 ? StepState.indexed : StepState.disabled),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Con el teléfono y el computador en la misma red Wi-Fi, conéctate '
            'a su IP. La detectamos automáticamente; verifícala.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _ipController,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: 'IP del teléfono',
              hintText: '192.168.1.5',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          _CommandChip('adb connect $_hostPort'),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: (_busy || _ipController.text.trim().isEmpty)
                ? null
                : _runStep2,
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.link),
            label: const Text('Conectar'),
          ),
        ],
      ),
    );
  }

  Step _stepDone() {
    return Step(
      title: const Text('3 · Desconectar USB'),
      isActive: _step >= 2,
      state: _connected ? StepState.complete : StepState.disabled,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _Hint(
            icon: Icons.check_circle,
            text: 'Conectado por Wi-Fi. Ya puedes desconectar el cable USB: '
                'el dispositivo sigue en la lista y puedes lanzar el mirror.',
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.done),
            label: const Text('Listo'),
          ),
        ],
      ),
    );
  }
}

class _CommandChip extends StatelessWidget {
  const _CommandChip(this.cmd);
  final String cmd;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black38,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        children: [
          const Icon(Icons.terminal, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText(cmd,
                style:
                    const TextStyle(fontFamily: 'monospace', fontSize: 12.5)),
          ),
        ],
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.icon, required this.text, this.warn = false});
  final IconData icon;
  final String text;
  final bool warn;
  @override
  Widget build(BuildContext context) {
    final color = warn ? Colors.orangeAccent : const Color(0xFF3DDC84);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 10),
        Expanded(child: Text(text)),
      ],
    );
  }
}
