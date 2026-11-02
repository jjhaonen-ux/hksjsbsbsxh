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
  final _existingController = TextEditingController();

  /// false: create a new repository. true: push into one that already exists.
  bool _useExisting = false;
  late String _owner;
  List<String> _orgs = const [];
  late bool _private;
  bool _busy = false;
  String? _error;

  /// Set when GitHub says the name is taken, to offer using that repository.
  RepoAlreadyExists? _duplicate;

  @override
  void initState() {
    super.initState();
    _owner = widget.user.login;
    // A token that cannot touch private repositories starts on "public".
    _private = widget.user.canCreatePrivate;
    _loadOrganizations();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _existingController.dispose();
    super.dispose();
  }

  /// Nice to have, never required: tokens without the right permission just
  /// get no owner picker.
  Future<void> _loadOrganizations() async {
    try {
      final orgs = await widget.service.listOrganizations();
      if (!mounted) return;
      setState(() => _orgs = orgs);
    } catch (_) {}
  }

  Future<void> _submit() => _useExisting ? _continueWithExisting() : _create();

  Future<void> _create() async {
    if (_busy) return;
    final name = _nameController.text.trim();
    if (!isValidRepoName(name)) {
      setState(() {
        _duplicate = null;
        _error = 'الاسم يجب أن يحتوي حروفًا أو أرقامًا أو . _ - فقط '
            '(ولا يكون "." أو "..")';
      });
      return;
    }
    final user = widget.user;
    if (_private && !user.canCreatePrivate) {
      setState(() {
        _duplicate = null;
        _error = 'التوكن لا يحمل نطاق repo اللازم للمستودعات الخاصة. '
            'اختر «عام» أو استخدم توكنًا بصلاحية أوسع.';
      });
      return;
    }
    if (!_private && !user.canCreatePublic) {
      setState(() {
        _duplicate = null;
        _error = 'التوكن لا يحمل نطاق repo ولا public_repo.';
      });
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
      _duplicate = null;
    });
    try {
      final repo = await widget.service.createRepo(
        owner: _owner,
        asOrganization: _owner != user.login,
        name: name,
        isPrivate: _private,
        description: _descriptionController.text.trim(),
      );
      if (!mounted) return;
      await _openPush(repo, isNew: true);
    } on RepoAlreadyExists catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _duplicate = e;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _continueWithExisting() async {
    if (_busy) return;
    final ref = parseRepoRef(_existingController.text);
    if (ref == null) {
      setState(() {
        _duplicate = null;
        _error = 'اكتب المستودع بالصيغة owner/repo أو الصق رابطه من GitHub.';
      });
      return;
    }
    await _openExisting(ref.owner, ref.name);
  }

  Future<void> _openExisting(String owner, String name) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _duplicate = null;
    });
    try {
      final repo = await widget.service.getRepo(owner, name);
      if (!mounted) return;
      await _openPush(repo, isNew: false);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openPush(CreatedRepo repo, {required bool isNew}) async {
    final deleted = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => PushScreen(
          service: widget.service,
          repo: repo,
          user: widget.user,
          isNewRepo: isNew,
        ),
      ),
    );
    if (!mounted) return;
    if (deleted == true) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('حُذف المستودع ${repo.fullName}')),
      );
    }
  }

  Future<void> _signOut() async {
    // Leaving the app's session must not depend on the keystore cooperating.
    final messenger = ScaffoldMessenger.of(context);
    var cleared = true;
    try {
      await const TokenStore().clear();
    } catch (_) {
      cleared = false;
    }
    widget.onSignedOut();
    if (!cleared) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'تم الخروج، لكن تعذر مسح التوكن المحفوظ من الجهاز. '
            'قد يعود التطبيق إلى الدخول به تلقائيًا.',
          ),
          duration: Duration(seconds: 8),
        ),
      );
    }
  }

  Widget _notice(Color color, String text) {
    return Card(
      color: color,
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Text(text),
      ),
    );
  }

  List<Widget> _scopeNotices(ColorScheme colors) {
    final user = widget.user;
    if (!user.isClassic) {
      // Fine-grained: nothing can be checked up front, so be honest about it.
      return [
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            'توكن Fine-grained: لا يمكن فحص صلاحياته مسبقًا. يلزم '
            'Administration + Contents (وWorkflows لملفات .github/workflows)، '
            'ويجب أن يشمل المستودع الهدف.',
            style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
          ),
        ),
      ];
    }
    final scopesText = user.scopes.isEmpty ? 'بلا نطاقات' : user.scopes.join(', ');
    if (!user.canCreatePublic) {
      return [
        _notice(
          colors.errorContainer,
          'التوكن الكلاسيكي لا يحمل نطاق repo ولا public_repo '
          '(النطاقات: $scopesText) — إنشاء المستودعات والرفع سيفشلان.',
        ),
      ];
    }
    return [
      if (!user.canCreatePrivate)
        _notice(
          colors.secondaryContainer,
          'التوكن يحمل public_repo فقط: يمكنك العمل على المستودعات العامة. '
          'للمستودعات الخاصة أضف نطاق repo.',
        ),
      // Without `workflow`, GitHub refuses any file under .github/workflows.
      if (!user.canPushWorkflows)
        _notice(
          colors.secondaryContainer,
          'التوكن لا يحمل نطاق workflow: لن يمكن رفع ملفات '
          '.github/workflows (سيُعرض عليك استبعادها عند الرفع).',
        ),
    ];
  }

  List<Widget> _newRepoFields() {
    final owners = <String>[widget.user.login, ..._orgs];
    return [
      if (_orgs.isNotEmpty) ...[
        DropdownMenu<String>(
          initialSelection: _owner,
          label: const Text('المالك'),
          enabled: !_busy,
          expandedInsets: EdgeInsets.zero,
          requestFocusOnTap: false,
          dropdownMenuEntries: [
            for (final owner in owners)
              DropdownMenuEntry<String>(value: owner, label: owner),
          ],
          onSelected: (value) {
            if (value != null) setState(() => _owner = value);
          },
        ),
        const SizedBox(height: 16),
      ],
      TextField(
        controller: _nameController,
        enabled: !_busy,
        autocorrect: false,
        enableSuggestions: false,
        textDirection: TextDirection.ltr,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(),
        decoration: const InputDecoration(
          labelText: 'اسم المستودع',
          border: OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 16),
      TextField(
        controller: _descriptionController,
        enabled: !_busy,
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
        subtitle: widget.user.canCreatePrivate
            ? null
            : const Text('يحتاج التوكن نطاق repo'),
        value: _private,
        onChanged: (_busy || !widget.user.canCreatePrivate)
            ? null
            : (v) => setState(() => _private = v),
      ),
    ];
  }

  List<Widget> _existingFields() {
    return [
      TextField(
        controller: _existingController,
        enabled: !_busy,
        autocorrect: false,
        enableSuggestions: false,
        keyboardType: TextInputType.url,
        textDirection: TextDirection.ltr,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(),
        decoration: const InputDecoration(
          labelText: 'المستودع (owner/repo أو الرابط)',
          border: OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 8),
      Text(
        'سيُضاف الرفع كـ commit جديد فوق الفرع الافتراضي، وتُستبدل الملفات '
        'التي لها المسار نفسه. يعمل أيضًا مع مستودعات المنظمات التي لك '
        'فيها صلاحية كتابة.',
        style: TextStyle(
          fontSize: 12,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final duplicate = _duplicate;

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
            ..._scopeNotices(colors),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment<bool>(
                  value: false,
                  icon: Icon(Icons.add),
                  label: Text('مستودع جديد'),
                ),
                ButtonSegment<bool>(
                  value: true,
                  icon: Icon(Icons.folder_open),
                  label: Text('مستودع موجود'),
                ),
              ],
              selected: {_useExisting},
              onSelectionChanged: _busy
                  ? null
                  : (selection) => setState(() {
                        _useExisting = selection.first;
                        _error = null;
                        _duplicate = null;
                      }),
            ),
            const SizedBox(height: 20),
            ..._useExisting ? _existingFields() : _newRepoFields(),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(_error!, style: TextStyle(color: colors.error)),
              ),
            if (duplicate != null)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'يمكنك الرفع إلى ${duplicate.fullName} الموجود بدل '
                        'إنشاء مستودع جديد.',
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton(
                        onPressed: _busy
                            ? null
                            : () =>
                                _openExisting(duplicate.owner, duplicate.name),
                        child: const Text('الرفع إلى المستودع الموجود'),
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _busy ? null : _submit,
              icon: _busy
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(_useExisting ? Icons.arrow_forward : Icons.add),
              label: Text(
                _useExisting ? 'المتابعة إلى الرفع' : 'إنشاء المستودع والمتابعة',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
