import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/github_service.dart';
import '../services/token_store.dart';

class TokenScreen extends StatefulWidget {
  const TokenScreen({super.key, required this.onAuthenticated});

  final void Function(String token, GitHubUser user) onAuthenticated;

  @override
  State<TokenScreen> createState() => _TokenScreenState();
}

class _TokenScreenState extends State<TokenScreen> {
  final _controller = TextEditingController();
  bool _obscure = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final token = _controller.text.trim();
    if (token.isEmpty) {
      setState(() => _error = 'أدخل التوكن أولًا');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final service = GitHubService(token: token);
      final user = await service.currentUser();
      await const TokenStore().write(token);
      if (!mounted) return;
      widget.onAuthenticated(token, user);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ربط حساب GitHub')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text(
              'أدخل Personal Access Token. يُخزَّن مشفرًا عبر Keystore '
              'ولا يُرسل إلى أي خادم غير api.github.com.',
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _controller,
              obscureText: _obscure,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'التوكن',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
            const SizedBox(height: 12),
            const SelectableText(
              'الصلاحيات المطلوبة: repo (كلاسيكي) أو '
              'Administration + Contents (Fine-grained)',
              style: TextStyle(fontSize: 12),
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(_error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('تحقق ودخول'),
            ),
          ],
        ),
      ),
    );
  }
}
