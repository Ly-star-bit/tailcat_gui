import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

/// Displays a server token as QR + text with copy/share actions.
class TokenCard extends StatelessWidget {
  const TokenCard({super.key, required this.token});

  final String token;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('连接令牌', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text('把它发给对方，对方在自己的 Tailcat 里输入即可连接。', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            Center(
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8)),
                child: QrImageView(data: token, size: 200, backgroundColor: Colors.white),
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(token, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    icon: const Icon(Icons.copy),
                    label: const Text('复制'),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: token));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('令牌已复制')));
                      }
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.share),
                    label: const Text('分享'),
                    onPressed: () => SharePlus.instance.share(ShareParams(text: token, subject: 'Tailcat 连接令牌')),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
