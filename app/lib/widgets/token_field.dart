import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../platform/platform_caps.dart';
import 'scan_screen.dart';

/// Token entry with paste and (on Android) camera-scan helpers.
class TokenField extends StatelessWidget {
  const TokenField({super.key, required this.controller, this.autofocus = false});

  final TextEditingController controller;
  final bool autofocus;

  static String? validate(String? v) {
    final t = (v ?? '').trim().replaceFirst('tailcat=', '');
    if (t.isEmpty) return '请输入连接令牌';
    if (!t.startsWith('tc') && !t.contains('.')) return '令牌应以 tc 开头（或是带 TXT 记录的域名）';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      autofocus: autofocus,
      maxLines: 3,
      minLines: 1,
      autocorrect: false,
      enableSuggestions: false,
      style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
      decoration: InputDecoration(
        labelText: '连接令牌',
        hintText: 'tc…（对方屏幕上显示的令牌）',
        border: const OutlineInputBorder(),
        suffixIcon: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: '粘贴',
              icon: const Icon(Icons.content_paste),
              onPressed: () async {
                final data = await Clipboard.getData(Clipboard.kTextPlain);
                final text = data?.text?.trim();
                if (text != null && text.isNotEmpty) controller.text = text;
              },
            ),
            if (PlatformCaps.canScanQr)
              IconButton(
                tooltip: '扫码',
                icon: const Icon(Icons.qr_code_scanner),
                onPressed: () async {
                  final v = await Navigator.of(context).push<String>(
                    MaterialPageRoute(builder: (_) => const ScanScreen()),
                  );
                  if (v != null) controller.text = v;
                },
              ),
          ],
        ),
      ),
      validator: validate,
    );
  }
}
