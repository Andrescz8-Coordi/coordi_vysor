import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../models/scrcpy_options.dart';

/// Right-hand panel: shared scrcpy launch options.
class OptionsPanel extends StatelessWidget {
  const OptionsPanel({super.key, required this.controller});

  final AppController controller;

  ScrcpyOptions get o => controller.options;
  void _set(ScrcpyOptions next) => controller.updateOptions(next);

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('Opciones de scrcpy',
            style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.bold,
                fontSize: 16)),
        const SizedBox(height: 4),
        Text('Se aplican al iniciar un mirror.',
            style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 12)),
        const SizedBox(height: 20),

        _SectionTitle('Video'),
        _SliderRow(
          label: 'Resolución máx (px, 0 = sin límite)',
          value: (o.maxSize ?? 0).toDouble(),
          min: 0,
          max: 2560,
          divisions: 16,
          display: (v) => v == 0 ? 'sin límite' : '${v.toInt()}px',
          onChanged: (v) => _set(o.copyWith(maxSize: v.toInt())),
        ),
        _SliderRow(
          label: 'Bitrate (Mbps)',
          value: (o.bitrateMbps ?? 8).toDouble(),
          min: 1,
          max: 32,
          divisions: 31,
          display: (v) => '${v.toInt()} Mbps',
          onChanged: (v) => _set(o.copyWith(bitrateMbps: v.toInt())),
        ),
        _SliderRow(
          label: 'FPS máx',
          value: (o.maxFps ?? 30).toDouble(),
          min: 10,
          max: 120,
          divisions: 11,
          display: (v) => '${v.toInt()} fps',
          onChanged: (v) => _set(o.copyWith(maxFps: v.toInt())),
        ),
        _DropdownRow(
          label: 'Codec de video',
          value: o.videoCodec ?? 'h265',
          items: const [
            DropdownItem('h264', 'H.264 (AVC) — mayor compatibilidad'),
            DropdownItem('h265', 'H.265 (HEVC) — ~50% más compresión'),
            DropdownItem('av1', 'AV1 — máxima compresión (más lento)'),
          ],
          onChanged: (v) => _set(o.copyWith(videoCodec: v)),
        ),

        const SizedBox(height: 12),
        _SectionTitle('Ventana'),
        _SwitchRow('Pantalla completa', o.fullscreen,
            (v) => _set(o.copyWith(fullscreen: v))),
        _SwitchRow('Sin bordes', o.borderless,
            (v) => _set(o.copyWith(borderless: v))),
        _SwitchRow('Siempre encima', o.alwaysOnTop,
            (v) => _set(o.copyWith(alwaysOnTop: v))),

        const SizedBox(height: 12),
        _SectionTitle('Comportamiento'),
        _SwitchRow('Mantener despierto', o.stayAwake,
            (v) => _set(o.copyWith(stayAwake: v))),
        _SwitchRow('Apagar pantalla del teléfono', o.turnScreenOff,
            (v) => _set(o.copyWith(turnScreenOff: v))),
        _SwitchRow('Sin audio', o.noAudio,
            (v) => _set(o.copyWith(noAudio: v))),
        _SwitchRow('Solo ver (sin control)', o.noControl,
            (v) => _set(o.copyWith(noControl: v))),

        const SizedBox(height: 12),
        _SectionTitle('Grabación'),
        _SwitchRow('Grabar pantalla', o.record,
            (v) => _set(o.copyWith(record: v))),
        if (o.record) ...[
          _SwitchRow('Comprimir video (H.265)', o.compress,
              (v) => _set(o.copyWith(compress: v))),
          if (o.compress)
            _SliderRow(
              label: 'Calidad (CRF, menor = mejor)',
              value: o.compressCrf.toDouble(),
              min: 18,
              max: 40,
              divisions: 22,
              display: (v) => 'CRF ${v.toInt()}',
              onChanged: (v) => _set(o.copyWith(compressCrf: v.toInt())),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Al detener la grabación se abrirá un diálogo para elegir '
              'el nombre y la ubicación del archivo.',
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],

      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 4, top: 8),
        child: Text(text,
            style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w600)),
      );
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow(this.label, this.value, this.onChanged);
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  @override
  Widget build(BuildContext context) => SwitchListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: Text(label),
        value: value,
        onChanged: onChanged,
      );
}

class DropdownItem {
  const DropdownItem(this.value, this.label);
  final String value;
  final String label;
}

class _DropdownRow extends StatelessWidget {
  const _DropdownRow({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final String label;
  final String value;
  final List<DropdownItem> items;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 4),
          child: Text(label, style: const TextStyle(fontSize: 13)),
        ),
        DropdownButtonFormField<String>(
          value: value,
          isExpanded: true,
          decoration: const InputDecoration(
            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            border: OutlineInputBorder(),
          ),
          items: items.map((item) {
            return DropdownMenuItem(
              value: item.value,
              child: Text(item.label, style: const TextStyle(fontSize: 12)),
            );
          }).toList(),
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ],
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.display,
    required this.onChanged,
  });

  final String label;
  final double value, min, max;
  final int divisions;
  final String Function(double) display;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
            Text(display(value),
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.primary)),
          ],
        ),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          onChanged: onChanged,
        ),
      ],
    );
  }
}
