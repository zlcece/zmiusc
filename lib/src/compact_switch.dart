import 'package:flutter/material.dart';

const double compactSwitchScale = 0.8;

class CompactSwitch extends StatelessWidget {
  const CompactSwitch({
    required this.value,
    required this.onChanged,
    super.key,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Transform.scale(
      scale: compactSwitchScale,
      alignment: Alignment.centerRight,
      child: Switch(value: value, onChanged: onChanged),
    );
  }
}

class CompactSwitchListTile extends StatelessWidget {
  const CompactSwitchListTile({
    required this.value,
    required this.onChanged,
    required this.title,
    this.subtitle,
    this.contentPadding,
    super.key,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final Widget title;
  final Widget? subtitle;
  final EdgeInsetsGeometry? contentPadding;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding:
          contentPadding ?? const EdgeInsets.symmetric(horizontal: 16),
      visualDensity: VisualDensity.compact,
      title: title,
      subtitle: subtitle,
      onTap: onChanged == null ? null : () => onChanged!(!value),
      trailing: CompactSwitch(value: value, onChanged: onChanged),
    );
  }
}
