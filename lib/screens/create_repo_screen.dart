import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/github_service.dart';
import '../services/token_store.dart';
import 'push_screen.dart';

class CreateRepoScreen extends StatefulWidget {
  const CreateRepoScreen({
    super.key,
    required this.service,
    required this.user,
    required this.onSignedOut,
  });

  final GitHubService service;
  final GitHubUser user;
  final VoidCallback onSignedOut;

  @override
  State<CreateRepoScreen> createState() => _CreateRepoScreenState();
}

class _CreateRepoScreenState extends State<CreateRepoScreen> {
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  bool _private = true;
  bool _busy = false;
  String? _error;

  static final _namePattern = RegExp(r'^[A-Za-z0-9._-]{1,100}$');

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final name = _nameController.text.trim();
    if (!_namePattern.hasMatch(name)) {
      setState(() => _error = 'الاسم يجب أن يحتوي حروفًا أو أرقامًا أو . _ - فقط');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final repo = await widget.service.createRepo(
        name: name,
        isPrivate: _private,
        description: _descriptionController.text.trim(),
      );
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => PushScreen(service: widget.service, repo: repo),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signOut() async {
    await const TokenStore().clear();
    widget.onSignedOut();
  }

  @override
  Widget build(BuildContext context) {
    // Fine-grained tokens report no scopes, so only warn for classic ones.
    final scopes = widget.user.scopes;
    final missingRepoScope = scopes.isNotEmpty && !scopes.contains('repo');

    return Scaffold(
      appBar: AppBar(
        title: Text('مرحبًا ${widget.user.login}'),
        actions: [
          IconButton(
            tooltip: 'تسجيل الخروج',
            onPressed: _busy ? null : _signOut,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (missingRepoScope)
              Card(
                color: Theme.of(context).colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    'التوكن لا يحمل نطاق repo (النطاقات: '
                    '${widget.user.scopes.join(", ")}) — إنشاء المستودعات سيفشل.',
                  ),
                ),
              ),
            const SizedBox(height: 8),
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'اسم المستودع',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _descriptionController,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'الوصف (اختياري)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('مستودع خاص'),
              value: _private,
              onChanged: (v) => setState(() => _private = v),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _busy ? null : _create,
              icon: _busy
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.add),
              label: const Text('إنشاء المستودع والمتابعة'),
            ),
          ],
        ),
      ),
    );
  }
}
