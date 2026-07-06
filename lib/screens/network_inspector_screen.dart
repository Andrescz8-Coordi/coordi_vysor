import 'dart:convert';

import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../models/debug_app.dart';
import '../models/device.dart';
import '../models/network_flow.dart';

/// Inspector de red: inyecta un agente JVMTI vía `attach-agent` en apps
/// debug en ejecución y muestra peticiones/respuestas capturadas.
class NetworkInspectorScreen extends StatefulWidget {
  const NetworkInspectorScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<NetworkInspectorScreen> createState() => _NetworkInspectorScreenState();
}

class _NetworkInspectorScreenState extends State<NetworkInspectorScreen> {
  NetworkFlow? _selected;
  Device? _pickedDevice;
  bool _attaching = false;

  AppController get c => widget.controller;

  Future<void> _attachAgent(DebugApp app) async {
    if (_attaching) return;
    setState(() => _attaching = true);
    try {
      await c.startAgentCapture(_pickedDevice!, app.package);
    } finally {
      if (mounted) setState(() => _attaching = false);
    }
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
              _Toolbar(
                controller: c,
                pickedDevice: _pickedDevice,
                onPickDevice: (d) {
                  setState(() => _pickedDevice = d);
                  c.refreshDebugApps(d.serial);
                },
              ),
              if (!c.capturing && _pickedDevice != null)
                _DebugAppPicker(
                  controller: c,
                  device: _pickedDevice!,
                  attaching: _attaching,
                  onAttach: _attachAgent,
                ),
              if (_attaching)
                const LinearProgressIndicator()
              else if (c.captureError != null)
                Container(
                  width: double.infinity,
                  color: Colors.redAccent.withValues(alpha: 0.12),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline, size: 16, color: Colors.redAccent),
                      const SizedBox(width: 8),
                      Expanded(
                        child: SelectableText(
                          c.captureError!,
                          style: const TextStyle(fontSize: 11, color: Colors.redAccent),
                        ),
                      ),
                    ],
                  ),
                ),
              const _AgentBanner(),
              if (c.agentStatus != null) _AgentStatusBar(status: c.agentStatus!),
              if (c.capturing) _DiagnosticPanel(controller: c),
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
                        package: c.capturePackage,
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
  const _Toolbar({
    required this.controller,
    required this.pickedDevice,
    required this.onPickDevice,
  });

  final AppController controller;
  final Device? pickedDevice;
  final ValueChanged<Device> onPickDevice;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final ready = c.devices.where((d) => d.isReady).toList();

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          if (c.capturing)
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
              icon: const Icon(Icons.stop),
              label: Text(
                'Detener (${c.capturePackage ?? c.captureSerial})',
              ),
              onPressed: c.stopCapture,
            )
          else ...[
            DropdownButton<Device>(
              hint: const Text('Dispositivo'),
              value: pickedDevice,
              items: [
                for (final d in ready)
                  DropdownMenuItem(
                    value: d,
                    child: Text(d.model ?? d.serial),
                  ),
              ],
              onChanged: ready.isEmpty ? null : (d) { if (d != null) onPickDevice(d); },
            ),
          ],
          const Spacer(),
          Text('${c.flows.length} peticiones',
              style: Theme.of(context).textTheme.bodySmall),
          if (c.captureError != null)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(left: 12),
                child: Text(
                  c.captureError!,
                  style: const TextStyle(
                    color: Colors.redAccent,
                    fontSize: 12,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _DebugAppPicker extends StatelessWidget {
  const _DebugAppPicker({
    required this.controller,
    required this.device,
    required this.attaching,
    required this.onAttach,
  });

  final AppController controller;
  final Device device;
  final bool attaching;
  final ValueChanged<DebugApp> onAttach;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                'Apps debug en ${device.model ?? device.serial}',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Refrescar',
                icon: c.loadingDebugApps
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
                onPressed: c.loadingDebugApps || attaching
                    ? null
                    : () => c.refreshDebugApps(device.serial),
              ),
            ],
          ),
          if (c.debugApps.isEmpty)
            const Text(
              'No hay apps debug instaladas, o aún no se han listado.',
              style: TextStyle(fontSize: 12),
            )
          else
            SizedBox(
              height: 120,
              child: ListView.builder(
                itemCount: c.debugApps.length,
                itemBuilder: (context, i) {
                  final app = c.debugApps[i];
                  final canAttach = app.isRunning && !attaching;
                  return ListTile(
                    dense: true,
                    leading: Icon(
                      app.isRunning ? Icons.play_circle : Icons.pause_circle,
                      color: app.isRunning
                          ? const Color(0xFF3DDC84)
                          : Colors.grey,
                      size: 20,
                    ),
                    title: Text(app.package, style: const TextStyle(fontSize: 13)),
                    subtitle: Text(
                      app.isRunning
                          ? 'En ejecución — lista para attach'
                          : 'Abre la app en el dispositivo primero',
                      style: TextStyle(
                        fontSize: 11,
                        color: app.isRunning
                            ? const Color(0xFF3DDC84)
                            : Colors.orangeAccent,
                      ),
                    ),
                    trailing: FilledButton(
                      onPressed: canAttach ? () => onAttach(app) : null,
                      child: attaching
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text('Adjuntar agente'),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _AgentBanner extends StatelessWidget {
  const _AgentBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: Colors.blue.withValues(alpha: 0.10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: const Text(
        'Modo agente JVMTI: captura Volley, OkHttp, Retrofit y HttpURLConnection '
        'en apps debug, sin modificar el código de la app.',
        style: TextStyle(fontSize: 11),
      ),
    );
  }
}

class _AgentStatusBar extends StatelessWidget {
  const _AgentStatusBar({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: const Color(0xFF3DDC84).withValues(alpha: 0.12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Text(status, style: const TextStyle(fontSize: 11)),
    );
  }
}

class _DiagnosticPanel extends StatefulWidget {
  const _DiagnosticPanel({required this.controller});

  final AppController controller;

  @override
  State<_DiagnosticPanel> createState() => _DiagnosticPanelState();
}

class _DiagnosticPanelState extends State<_DiagnosticPanel> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return ExpansionTile(
      initiallyExpanded: _expanded,
      onExpansionChanged: (v) => setState(() => _expanded = v),
      title: const Text('Diagnóstico del agente', style: TextStyle(fontSize: 12)),
      subtitle: Text(
        'Socket: ${c.agentCapture.socketConnected ? "OK" : "no conectado"} · '
        '${c.agentDiagnostics.length} eventos',
        style: const TextStyle(fontSize: 10),
      ),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.bug_report, size: 16),
                label: const Text('Leer Logcat del dispositivo'),
                onPressed: () async {
                  await c.refreshAgentLogSnapshot();
                },
              ),
              const SizedBox(height: 8),
              if (c.agentDiagnostics.isNotEmpty) ...[
                const Text('Eventos recientes:', style: TextStyle(fontSize: 10)),
                const SizedBox(height: 4),
                Container(
                  constraints: const BoxConstraints(maxHeight: 120),
                  padding: const EdgeInsets.all(8),
                  color: Colors.black.withValues(alpha: 0.25),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      c.agentDiagnostics.join('\n'),
                      style: const TextStyle(fontSize: 10, fontFamily: 'monospace'),
                    ),
                  ),
                ),
              ],
              if (c.agentLogSnapshot != null) ...[
                const SizedBox(height: 8),
                const Text('Logcat (CoordiNetAgent):', style: TextStyle(fontSize: 10)),
                const SizedBox(height: 4),
                Container(
                  constraints: const BoxConstraints(maxHeight: 160),
                  padding: const EdgeInsets.all(8),
                  color: Colors.black.withValues(alpha: 0.25),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      c.agentLogSnapshot!,
                      style: const TextStyle(fontSize: 10, fontFamily: 'monospace'),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 8),
              const SelectableText(
                'Manual (terminal):\n'
                'adb logcat -c && adb logcat -s CoordiNetAgent:I\n'
                'Tras adjuntar debes ver Agent_OnAttach, JVMTI capabilities OK,\n'
                'autoprueba y agent://pipeline-ok en la lista.\n'
                'Luego usa la app: busca "metodo visto: performRequest" o "hook activo tipo=3".',
                style: TextStyle(fontSize: 10),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _FlowList extends StatelessWidget {
  const _FlowList({
    required this.flows,
    required this.selected,
    required this.package,
    required this.onTap,
  });

  final List<NetworkFlow> flows;
  final NetworkFlow? selected;
  final String? package;
  final ValueChanged<NetworkFlow> onTap;

  @override
  Widget build(BuildContext context) {
    if (flows.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            package == null
                ? 'Selecciona dispositivo y adjunta el agente a una app debug.'
                : 'Sin tráfico todavía.\nUsa $package en el dispositivo.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final items = flows.reversed.toList();
    return ListView.separated(
      itemCount: items.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final f = items[i];
        final hasToken = f.requestBearerToken != null;
        return ListTile(
          dense: true,
          selected: identical(f, selected),
          leading: _StatusChip(status: f.status),
          title: Row(
            children: [
              _MethodBadge(method: f.method),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  f.path.isEmpty ? '/' : f.path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              if (hasToken)
                const Padding(
                  padding: EdgeInsets.only(left: 4),
                  child: Icon(Icons.vpn_key, size: 13, color: Colors.amber),
                ),
            ],
          ),
          subtitle: Text(
            '${f.host} · ${f.durationMs}ms',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11),
          ),
          onTap: () => onTap(f),
        );
      },
    );
  }
}

class _MethodBadge extends StatelessWidget {
  const _MethodBadge({required this.method});

  final String method;

  Color get _color {
    switch (method.toUpperCase()) {
      case 'GET':
        return const Color(0xFF3DDC84);
      case 'POST':
        return Colors.blueAccent;
      case 'PUT':
      case 'PATCH':
        return Colors.orangeAccent;
      case 'DELETE':
        return Colors.redAccent;
      default:
        return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    final label = method.isEmpty ? '—' : method.toUpperCase();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: _color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: _color,
          fontSize: 10,
          fontWeight: FontWeight.bold,
        ),
      ),
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
    return Tooltip(
      message: _statusLabel(status),
      child: Container(
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
      ),
    );
  }
}

String _statusLabel(int code) {
  switch (code) {
    case 200: return '200 OK';
    case 201: return '201 Created';
    case 204: return '204 No Content';
    case 301: return '301 Moved Permanently';
    case 302: return '302 Found';
    case 304: return '304 Not Modified';
    case 400: return '400 Bad Request';
    case 401: return '401 Unauthorized';
    case 403: return '403 Forbidden';
    case 404: return '404 Not Found';
    case 405: return '405 Method Not Allowed';
    case 409: return '409 Conflict';
    case 422: return '422 Unprocessable Entity';
    case 429: return '429 Too Many Requests';
    case 500: return '500 Internal Server Error';
    case 502: return '502 Bad Gateway';
    case 503: return '503 Service Unavailable';
    case 504: return '504 Gateway Timeout';
    default: return '$code';
  }
}

Color _statusColor(int code) {
  if (code == 0) return Colors.grey;
  if (code >= 500) return Colors.redAccent;
  if (code >= 400) return Colors.orangeAccent;
  if (code >= 300) return Colors.blueAccent;
  return const Color(0xFF3DDC84);
}

String _tryFormatJson(String raw) {
  if (raw.isEmpty) return raw;
  try {
    final parsed = jsonDecode(raw);
    if (parsed is! Map && parsed is! List) return raw;
    return const JsonEncoder.withIndent('  ').convert(parsed);
  } catch (_) {
    return raw;
  }
}

class _FlowDetail extends StatelessWidget {
  const _FlowDetail({required this.flow});

  final NetworkFlow flow;

  @override
  Widget build(BuildContext context) {
    final statusLabel = _statusLabel(flow.status);
    final statusColor = _statusColor(flow.status);
    return DefaultTabController(
      length: 2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: statusColor.withValues(alpha: 0.08),
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: statusColor.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        statusLabel,
                        style: TextStyle(
                          color: statusColor,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(flow.method,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.w600,
                            fontSize: 14)),
                    const SizedBox(width: 8),
                    if (flow.durationMs > 0)
                      Text('${flow.durationMs}ms',
                          style: TextStyle(
                              color: flow.durationMs > 2000
                                  ? Colors.redAccent
                                  : Colors.grey,
                              fontSize: 12)),
                  ],
                ),
                const SizedBox(height: 4),
                SelectableText(flow.url,
                    style:
                        const TextStyle(fontSize: 12, fontFamily: 'monospace')),
              ],
            ),
          ),
          const TabBar(tabs: [Tab(text: 'Request'), Tab(text: 'Response')]),
          Expanded(
            child: TabBarView(
              children: [
                _Section(
                  bearerToken: flow.requestBearerToken,
                  body: flow.reqBody,
                  emptyBodyLabel: 'La petición no envió body.',
                ),
                _Section(
                  bearerToken: flow.responseBearerToken,
                  body: flow.respBody,
                  emptyBodyLabel: 'La respuesta no trajo body.',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.bearerToken,
    required this.body,
    required this.emptyBodyLabel,
  });

  /// Token Bearer detectado en el header Authorization (o null si no hay).
  final String? bearerToken;
  final String body;
  final String emptyBodyLabel;

  @override
  Widget build(BuildContext context) {
    final formattedBody = body.isEmpty ? '' : _tryFormatJson(body);
    final isJson = formattedBody.isNotEmpty && formattedBody != body;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _BearerTokenCard(token: bearerToken),
        const SizedBox(height: 16),
        Row(
          children: [
            Text('Body', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(width: 6),
            if (isJson)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: Colors.blueAccent.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: const Text(
                  'JSON',
                  style: TextStyle(
                    color: Colors.blueAccent,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(4),
          ),
          child: formattedBody.isEmpty
              ? Text(
                  emptyBodyLabel,
                  style: const TextStyle(
                    fontSize: 12,
                    fontStyle: FontStyle.italic,
                    color: Colors.grey,
                  ),
                )
              : SelectableText(
                  formattedBody,
                  style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                ),
        ),
      ],
    );
  }
}

/// Muestra el token Bearer (Authorization) resaltado, o indica que no hay.
class _BearerTokenCard extends StatelessWidget {
  const _BearerTokenCard({required this.token});

  final String? token;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (token == null) {
      return Row(
        children: [
          Icon(Icons.key_off, size: 15, color: Colors.grey.shade500),
          const SizedBox(width: 6),
          Text(
            'Sin Bearer token',
            style: TextStyle(
              fontSize: 12,
              fontStyle: FontStyle.italic,
              color: Colors.grey.shade500,
            ),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.vpn_key, size: 15, color: Colors.amber),
            const SizedBox(width: 6),
            Text('Bearer token', style: Theme.of(context).textTheme.titleSmall),
          ],
        ),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.amber.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: Colors.amberAccent.withValues(alpha: 0.4)),
          ),
          child: SelectableText.rich(
            TextSpan(
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
              children: [
                TextSpan(
                  text: 'Bearer ',
                  style: TextStyle(
                    color: Colors.amber.shade700,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                TextSpan(
                  text: token,
                  style: TextStyle(color: cs.onSurface),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
