import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/github_service.dart';
import '../services/token_store.dart';

class TokenScreen extends StatefulWidget {
  const TokenScreen({super.key, required this.onAuthenticated, this.notice});

  /// Hands over the service that verified the token (the caller owns it from
  /// now on) and, when saving the token failed, a warning to show.
  final void Function(
    String token,
    GitHubUser user,
    GitHubService service,
    String? warning,
  ) onAuthenticated;

  /// Explains why the user is asked for a token again (e.g. the saved one was
  /// revoked or expired).
  final String? notice;

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
    final service = GitHubService(token: token);

    // 1) Is the token valid? Only a failure HERE means "bad token".
    final GitHubUser user;
    try {
      user = await service.currentUser();
    } catch (e) {
      service.close();
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _busy = false;
      });
      return;
    }

    // 2) Remember it. Failing to do so must not turn a good token into a
    //    "login failed": the user simply stays signed in for this session.
    String? warning;
    try {
      await const TokenStore().write(token);
    } catch (_) {
      warning = 'تم الدخول، لكن تعذر حفظ التوكن على هذا الجهاز؛ '
          'سيُطلب منك إدخاله مجددًا عند فتح التطبيق لاحقًا.';
    }

    if (!mounted) {
      service.close();
      return;
    }
    widget.onAuthenticated(token, user, service, warning);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ربط حساب GitHub')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (widget.notice != null)
              Card(
                color: Theme.of(context).colorScheme.secondaryContainer,
                margin: const EdgeInsets.only(bottom: 16),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(widget.notice!),
                ),
              ),
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
              // Tokens are Latin text: keep them left-to-right inside the
              // Arabic layout.
              textDirection: TextDirection.ltr,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) {
                if (!_busy) _submit();
              },
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
              'الصلاحيات المطلوبة: repo (كلاسيكي؛ ويكفي public_repo إن كانت '
              'مستودعاتك عامة فقط) أو Administration + Contents (Fine-grained).\n'
              'لرفع ملفات .github/workflows أضف أيضًا: workflow (كلاسيكي) أو '
              'Workflows (Fine-grained). وفي Fine-grained يُنصح باختيار '
              'All repositories لأن المستودع الجديد لا يكون ضمن مستودعات '
              'محددة مسبقًا.',
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
