import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../models/device.dart';
import '../models/network_flow.dart';

/// Network inspector: drives a local mitmproxy and shows captured
/// request/response pairs of debuggable apps that trust the user CA.
class NetworkInspectorScreen extends StatefulWidget {
  const NetworkInspectorScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<NetworkInspectorScreen> createState() => _NetworkInspectorScreenState();
}

class _NetworkInspectorScreenState extends State<NetworkInspectorScreen> {
  NetworkFlow? _selected;
  late final TextEditingController _pkgCtrl =
      TextEditingController(text: widget.controller.targetPackage ?? '');

  AppController get c => widget.controller;

  @override
  void dispose() {
    _pkgCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Inspector de red'),
        actions: [
          IconButton(
            tooltip: 'Limpiar capturas',
            icon: const Icon(Icons.delete_sweep),
            onPressed: () {
              c.clearFlows();
              setState(() => _selected = null);
            },
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: c,
        builder: (context, _) {
          return Column(
            children: [
              _Toolbar(controller: c),
              _AppFilterBar(controller: c, pkgCtrl: _pkgCtrl),
              const _HttpsBanner(),
              const Divider(height: 1),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: 380,
                      child: _FlowList(
                        flows: c.visibleFlows,
                        selected: _selected,
                        targetUid: c.targetUid,
                        onTap: (f) => setState(() => _selected = f),
                      ),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(
                      child: _selected == null
                          ? const Center(
                              child: Text('Selecciona una petición'))
                          : _FlowDetail(flow: _selected!),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final ready =
        c.devices.where((d) => d.isReady).toList();

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          if (!c.capturing) ...[
            _DevicePicker(devices: ready, controller: c),
          ] else
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
              icon: const Icon(Icons.stop),
              label: Text('Detener (${c.captureSerial})'),
              onPressed: c.stopCapture,
            ),
          const SizedBox(width: 12),
          if (c.captureSerial != null)
            OutlinedButton.icon(
              icon: const Icon(Icons.verified_user),
              label: const Text('Instalar CA'),
              onPressed: () => _installCa(context, c),
            ),
          const Spacer(),
          Text('${c.flows.length} peticiones',
              style: Theme.of(context).textTheme.bodySmall),
          if (c.captureError != null)
            Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Text(c.captureError!,
                  style: const TextStyle(
                      color: Colors.redAccent, fontSize: 12)),
            ),
        ],
      ),
    );
  }

  Future<void> _installCa(BuildContext context, AppController c) async {
    final serial = c.captureSerial;
    if (serial == null) return;
    try {
      await c.installCaCert(serial);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Cert enviado a /sdcard/Download. Instálalo en Ajustes > Seguridad > CA.')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }
}

class _DevicePicker extends StatelessWidget {
  const _DevicePicker({required this.devices, required this.controller});

  final List<Device> devices;
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    if (devices.isEmpty) {
      return const Text('No hay dispositivos listos');
    }
    return Wrap(
      spacing: 8,
      children: [
        for (final d in devices)
          FilledButton.icon(
            icon: const Icon(Icons.play_arrow),
            label: Text('Capturar ${d.model ?? d.serial}'),
            onPressed: () => controller.startCapture(d),
          ),
      ],
    );
  }
}

class _AppFilterBar extends StatelessWidget {
  const _AppFilterBar({required this.controller, required this.pkgCtrl});

  final AppController controller;
  final TextEditingController pkgCtrl;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          SizedBox(
            width: 320,
            child: TextField(
              controller: pkgCtrl,
              decoration: const InputDecoration(
                isDense: true,
                labelText: 'Package de la app (debug)',
                hintText: 'com.ejemplo.app',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (v) => c.setTargetPackage(v),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: () => c.setTargetPackage(pkgCtrl.text),
            child: const Text('Resolver UID'),
          ),
          const SizedBox(width: 8),
          if (c.targetPackage != null)
            Text(
              c.targetUid != null
                  ? 'UID ${c.targetUid}'
                  : 'UID no resuelto (¿app instalada?)',
              style: TextStyle(
                fontSize: 12,
                color: c.targetUid != null
                    ? const Color(0xFF3DDC84)
                    : Colors.orangeAccent,
              ),
            ),
          const Spacer(),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Checkbox(
                value: c.onlyTargetApp,
                onChanged: c.targetUid == null
                    ? null
                    : (v) => c.setOnlyTargetApp(v ?? false),
              ),
              const Text('Solo esta app'),
            ],
          ),
        ],
      ),
    );
  }
}

class _HttpsBanner extends StatelessWidget {
  const _HttpsBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: Colors.amber.withValues(alpha: 0.12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: const Text(
        'HTTP se captura directo. Para HTTPS, la app debe ser debug y confiar '
        'en el CA de usuario (instala el cert con "Instalar CA"). '
        'Apps release o con cert pinning no se descifran.',
        style: TextStyle(fontSize: 11),
      ),
    );
  }
}

class _FlowList extends StatelessWidget {
  const _FlowList(
      {required this.flows,
      required this.selected,
      required this.targetUid,
      required this.onTap});

  final List<NetworkFlow> flows;
  final NetworkFlow? selected;
  final int? targetUid;
  final ValueChanged<NetworkFlow> onTap;

  @override
  Widget build(BuildContext context) {
    if (flows.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Sin tráfico todavía.\nInicia la captura y usa la app del dispositivo.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    // Newest first.
    final items = flows.reversed.toList();
    return ListView.builder(
      itemCount: items.length,
      itemBuilder: (context, i) {
        final f = items[i];
        final isTarget = targetUid != null && f.appUid == targetUid;
        final uidLabel =
            f.appUid != null ? 'uid ${f.appUid}' : 'uid ?';
        return ListTile(
          dense: true,
          selected: identical(f, selected),
          leading: _StatusChip(status: f.status),
          title: Row(
            children: [
              if (isTarget)
                const Padding(
                  padding: EdgeInsets.only(right: 4),
                  child: Icon(Icons.adjust,
                      size: 12, color: Color(0xFF3DDC84)),
                ),
              Expanded(
                child: Text(f.path,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
          subtitle: Text(
              '${f.method} · ${f.host} · ${f.durationMs}ms · $uidLabel',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11)),
          onTap: () => onTap(f),
        );
      },
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final int status;

  Color get _color {
    if (status == 0) return Colors.grey;
    if (status >= 500) return Colors.redAccent;
    if (status >= 400) return Colors.orangeAccent;
    if (status >= 300) return Colors.blueAccent;
    return const Color(0xFF3DDC84);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 38,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: _color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(status == 0 ? '—' : '$status',
          style: TextStyle(
              color: _color, fontSize: 12, fontWeight: FontWeight.bold)),
    );
  }
}

class _FlowDetail extends StatelessWidget {
  const _FlowDetail({required this.flow});

  final NetworkFlow flow;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: SelectableText('${flow.method}  ${flow.url}',
                style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
          const TabBar(tabs: [Tab(text: 'Request'), Tab(text: 'Response')]),
          Expanded(
            child: TabBarView(
              children: [
                _Section(headers: flow.reqHeaders, body: flow.reqBody),
                _Section(headers: flow.respHeaders, body: flow.respBody),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.headers, required this.body});

  final Map<String, String> headers;
  final String body;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text('Headers', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        for (final e in headers.entries)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 1),
            child: SelectableText('${e.key}: ${e.value}',
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
          ),
        const SizedBox(height: 16),
        Text('Body', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        SelectableText(body.isEmpty ? '(vacío)' : body,
            style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
      ],
    );
  }
}
