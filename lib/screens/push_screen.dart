import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/models.dart';
import '../services/github_service.dart';
import '../services/secret_scanner.dart';
import '../services/zip_service.dart';

enum _WorkflowChoice { exclude, keep }

enum _SecretChoice { exclude, keep }

/// "أقل من 0.1" for tiny archives instead of a misleading "0.00".
String _formatMegabytes(int bytes) {
  final mb = bytes / (1024 * 1024);
  if (mb < 0.1) return 'أقل من 0.1 ميغابايت';
  return '${mb.toStringAsFixed(1)} ميغابايت';
}

class PushScreen extends StatefulWidget {
  const PushScreen({
    super.key,
    required this.service,
    required this.repo,
    required this.user,
    this.isNewRepo = false,
  });

  final GitHubService service;
  final CreatedRepo repo;

  /// The signed-in user; its token type decides which warnings make sense.
  final GitHubUser user;

  /// True when this app created [repo] a moment ago. Only then is deleting it
  /// offered (as long as nothing of the user's was uploaded).
  final bool isNewRepo;

  @override
  State<PushScreen> createState() => _PushScreenState();
}

class _PushScreenState extends State<PushScreen> {
  final _messageController = TextEditingController();

  // ---- the selected archive
  ZipExtractionResult? _zip;

  /// What would be uploaded right now: [_zip] seen through the "strip wrapper
  /// folder" switch. Recomputed (cheaply, no re-extraction) by
  /// [_refreshFiles] whenever either of them changes.
  List<ExtractedFile> _files = const [];
  bool _hasWorkflowFiles = false;
  int _skippedByCount = 0;
  int _skippedBySize = 0;
  bool _stripRoot = true;

  // ---- picking / extraction
  bool _picking = false; // system picker open OR extraction running
  bool _extracting = false;
  int _extractDone = 0;
  int _extractTotal = 0;

  // ---- upload
  bool _starting = false; // guards against a double tap on "start"
  bool _uploading = false;
  bool _cancelRequested = false;
  Future<void>? _uploadSettled; // completes when the upload has fully stopped
  bool _hasRun = false; // an upload was attempted for the current archive
  bool _cancelled = false;
  int _excludedWorkflows = 0;
  int _excludedSecrets = 0;
  bool _deleting = false;
  PushStage _stage = PushStage.preparing;
  int _done = 0;
  int _total = 0;
  String? _detail;
  String? _error;
  PushResult? _result;

  @override
  void initState() {
    super.initState();
    _messageController.text = 'Import project from ZIP';
  }

  @override
  void dispose() {
    // If the user chose to leave mid-upload, make it stop at its next
    // checkpoint.
    _cancelRequested = true;
    _messageController.dispose();

    final zip = _zip;
    if (zip != null) {
      final settled = _uploadSettled;
      if (_uploading && settled != null) {
        // The upload is still reading these files: delete them only once it
        // has really stopped.
        unawaited(settled.whenComplete(zip.cleanup));
      } else {
        unawaited(zip.cleanup());
      }
    }
    super.dispose();
  }

  // ------------------------------------------------------------ picking

  /// Recomputes everything derived from [_zip] and [_stripRoot]. Call inside
  /// `setState`.
  void _refreshFiles() {
    final zip = _zip;
    if (zip == null) {
      _files = const [];
      _hasWorkflowFiles = false;
      _skippedByCount = 0;
      _skippedBySize = 0;
      return;
    }
    _files = zip.filesFor(stripWrapper: _stripRoot);
    _hasWorkflowFiles = _files.any((f) => f.isWorkflowFile);
    _skippedByCount = zip.skippedCount(SkipKind.fileCountLimit);
    _skippedBySize = zip.skippedCount(SkipKind.fileTooBig);
  }

  void _onStripChanged(bool value) {
    setState(() {
      _stripRoot = value;
      _refreshFiles();
    });
  }

  Future<void> _pickZip() async {
    if (_picking || _uploading || _deleting) return;
    setState(() => _picking = true);
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['zip'],
        withData: false,
      );
      final path = picked?.files.firstOrNull?.path;
      // Dismissing the picker changes nothing: the current archive stays.
      if (path == null || !mounted) return;

      // A new file was chosen. From here on the previous archive is gone
      // even if this one turns out to be unusable, so a stale archive can
      // never be uploaded by mistake.
      final previous = _zip;
      setState(() {
        _zip = null;
        _refreshFiles();
        _error = null;
        _result = null;
        _cancelled = false;
        _hasRun = false;
        _excludedWorkflows = 0;
        _excludedSecrets = 0;
        _detail = null;
        _done = 0;
        _total = 0;
        _stage = PushStage.preparing;
        _extracting = true;
        _extractDone = 0;
        _extractTotal = 0;
      });
      await previous?.cleanup();

      if (!path.toLowerCase().endsWith('.zip')) {
        if (!mounted) return;
        setState(() => _error = 'الملف المختار ليس ZIP');
        return;
      }

      final extracted = await ZipService().extract(
        path,
        onProgress: (done, total) {
          if (!mounted) return;
          setState(() {
            _extractDone = done;
            _extractTotal = total;
          });
        },
      );
      if (!mounted) {
        // The user left while the isolate was still working.
        await extracted.cleanup();
        return;
      }
      setState(() {
        _zip = extracted;
        _refreshFiles();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      // The picker leaves a copy of the chosen file in the app cache; the
      // archive has been fully extracted (or abandoned) by now.
      unawaited(_clearPickerCache());
      if (mounted) {
        setState(() {
          _picking = false;
          _extracting = false;
          _extractDone = 0;
          _extractTotal = 0;
        });
      }
    }
  }

  Future<void> _clearPickerCache() async {
    try {
      await FilePicker.platform.clearTemporaryFiles();
    } catch (_) {
      // Not supported on every platform; the OS empties the cache anyway.
    }
  }

  // ------------------------------------------------------------ upload

  /// Classic tokens list their scopes, so we know for sure when `workflow`
  /// is missing. Fine-grained tokens do not, so for them we can only hint.
  bool get _workflowScopeMissing => !widget.user.canPushWorkflows;

  Future<_WorkflowChoice?> _askAboutWorkflows() {
    return showDialog<_WorkflowChoice>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ملفات workflow تحتاج صلاحية إضافية'),
        content: const Text(
          'الأرشيف يحتوي ملفات داخل .github/workflows وتوكنك لا يحمل نطاق '
          'workflow. إن أبقيتها سترفض GitHub الالتزام في آخر خطوة بعد رفع '
          'كل الملفات، وقد تُظهر رسالة 404 مضللة.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('إلغاء'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, _WorkflowChoice.keep),
            child: const Text('متابعة بأي حال'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, _WorkflowChoice.exclude),
            child: const Text('استبعادها ومتابعة'),
          ),
        ],
      ),
    );
  }

  Future<_SecretChoice?> _askAboutSecrets(List<String> paths) {
    const shown = 8;
    final visible = paths.take(shown).toList();
    final more = paths.length - visible.length;
    final scheme = Theme.of(context).colorScheme;
    return showDialog<_SecretChoice>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ملفات قد تحتوي أسرارًا'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.repo.isPrivate
                    ? 'الأرشيف يحوي ملفات تبدو كمفاتيح أو كلمات مرور. '
                        'المستودع خاص، لكن ما يُرفع يبقى في سجل Git حتى لو '
                        'حُذف لاحقًا.'
                    : 'الأرشيف يحوي ملفات تبدو كمفاتيح أو كلمات مرور، '
                        'والمستودع عام: سيقرؤها أي شخص، وتبقى في سجل Git حتى '
                        'لو حُذفت لاحقًا.',
              ),
              const SizedBox(height: 12),
              for (final path in visible)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    path,
                    textDirection: TextDirection.ltr,
                    style: TextStyle(fontSize: 12, color: scheme.error),
                  ),
                ),
              if (more > 0) Text('… و$more ملف آخر'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('إلغاء'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, _SecretChoice.keep),
            child: const Text('رفعها بأي حال'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, _SecretChoice.exclude),
            child: const Text('استبعادها ومتابعة'),
          ),
        ],
      ),
    );
  }

  Future<void> _startUpload() async {
    if (_zip == null || _starting || _uploading || _result != null) return;
    // Set synchronously so a second tap (e.g. while the dialog below is
    // opening) can never start a second upload and a duplicate commit.
    _starting = true;
    try {
      var files = _files;
      var excludedWorkflows = 0;
      var excludedSecrets = 0;

      if (_hasWorkflowFiles && _workflowScopeMissing) {
        final choice = await _askAboutWorkflows();
        if (choice == null || !mounted) return;
        if (choice == _WorkflowChoice.exclude) {
          final before = files.length;
          files = files.where((f) => !f.isWorkflowFile).toList();
          excludedWorkflows = before - files.length;
        }
        if (files.isEmpty) {
          setState(() {
            _error = 'لم يتبقَّ ملفات للرفع بعد استبعاد ملفات workflow';
          });
          return;
        }
      }

      // Last look before anything leaves the phone.
      final secrets = findPotentialSecrets(files.map((f) => f.relativePath));
      if (secrets.isNotEmpty) {
        final choice = await _askAboutSecrets(secrets);
        if (choice == null || !mounted) return;
        if (choice == _SecretChoice.exclude) {
          final drop = secrets.toSet();
          final before = files.length;
          files = files.where((f) => !drop.contains(f.relativePath)).toList();
          excludedSecrets = before - files.length;
        }
        if (files.isEmpty) {
          setState(() {
            _error = 'لم يتبقَّ ملفات للرفع بعد استبعاد الملفات الحساسة';
          });
          return;
        }
      }

      await _runUpload(
        files,
        excludedWorkflows: excludedWorkflows,
        excludedSecrets: excludedSecrets,
      );
    } finally {
      _starting = false;
    }
  }

  Future<void> _runUpload(
    List<ExtractedFile> files, {
    int excludedWorkflows = 0,
    int excludedSecrets = 0,
  }) async {
    final settled = Completer<void>();
    _uploadSettled = settled.future;

    setState(() {
      _uploading = true;
      _cancelRequested = false;
      _cancelled = false;
      _hasRun = true;
      _error = null;
      _result = null;
      _excludedWorkflows = excludedWorkflows;
      _excludedSecrets = excludedSecrets;
      _done = 0;
      _total = files.length;
      _stage = PushStage.preparing;
      _detail = null;
    });
    try {
      final message = _messageController.text.trim();
      final result = await widget.service.pushFiles(
        owner: widget.repo.owner,
        repo: widget.repo.name,
        files: files,
        branch: widget.repo.defaultBranch,
        commitMessage: message.isEmpty ? 'Import project from ZIP' : message,
        onProgress: (progress) {
          if (!mounted) return;
          setState(() {
            _stage = progress.stage;
            _done = progress.done;
            _total = progress.total;
            _detail = progress.detail;
          });
        },
        isCancelled: () => _cancelRequested,
      );
      if (!mounted) return;
      setState(() => _result = result);
    } on PushCancelled {
      // A choice of the user, not a failure: shown neutrally, not as error.
      if (!mounted) return;
      setState(() => _cancelled = true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) {
        setState(() {
          _uploading = false;
          _detail = null;
        });
      }
      settled.complete();
    }
  }

  // ------------------------------------------------------------ deleting

  /// Offered for a repository this app just created, as long as none of the
  /// user's files made it in. It is a button with a confirmation, not an
  /// automatic cleanup: deletion is permanent, needs a token with delete
  /// rights, and retrying in the same repository is often what is wanted.
  Future<void> _deleteRepo() async {
    if (_deleting || _uploading || _result != null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('حذف المستودع؟'),
        content: Text(
          'سيُحذف ${widget.repo.fullName} نهائيًا من GitHub. لم تُرفع إليه '
          'ملفات مشروعك. يحتاج الحذف توكنًا بصلاحية delete_repo (كلاسيكي) '
          'أو Administration: write (Fine-grained).',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('حذف نهائيًا'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _deleting = true;
      _error = null;
    });
    try {
      await widget.service.deleteRepo(widget.repo.owner, widget.repo.name);
      if (!mounted) return;
      // Tells the previous screen what happened.
      Navigator.of(context).pop(true);
    } on GitHubApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = (e.statusCode == 403 || e.statusCode == 404)
            ? 'تعذر حذف المستودع: التوكن يفتقر إلى صلاحية الحذف '
                '(delete_repo أو Administration: write). احذفه يدويًا من '
                'إعدادات المستودع في GitHub.'
            : e.toString();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  // ------------------------------------------------------------ leaving

  Future<void> _confirmLeave() async {
    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('إيقاف الرفع والخروج؟'),
        content: const Text(
          'الرفع ما زال جاريًا. إن خرجت الآن سيتوقف ولن تُضاف ملفاتك إلى '
          'المستودع، ويمكنك المحاولة لاحقًا. قد يستغرق الإيقاف الفعلي بضع '
          'ثوانٍ في الخلفية.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('متابعة الرفع'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('إيقاف والخروج'),
          ),
        ],
      ),
    );
    if (leave != true || !mounted) return;
    _cancelRequested = true;
    // Navigator.pop is not intercepted by PopScope.
    Navigator.of(context).pop();
  }

  // ------------------------------------------------------------ UI

  String _stageLabel(PushStage stage) {
    switch (stage) {
      case PushStage.preparing:
        return 'تجهيز';
      case PushStage.blobs:
        return 'رفع الملفات';
      case PushStage.tree:
        return 'بناء الشجرة';
      case PushStage.commit:
        return 'إنشاء الالتزام';
      case PushStage.ref:
        return 'تحديث الفرع';
      case PushStage.finished:
        return 'اكتمل';
    }
  }

  String get _startLabel {
    if (_result != null) return 'تم الرفع';
    if (_hasRun && (_error != null || _cancelled)) return 'إعادة محاولة الرفع';
    return 'بدء الرفع';
  }

  String get _stripSubtitle {
    final zip = _zip;
    if (zip == null) return 'مفيد عندما يُضغط مجلد واحد داخل الأرشيف';
    final wrapper = zip.wrapperFolder;
    if (wrapper == null) {
      return 'لا يوجد مجلد واحد يضم كل ملفات هذا الأرشيف';
    }
    return 'المجلد المكتشف: $wrapper';
  }

  Widget _buildExtractionProgress() {
    final known = _extractTotal > 0;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(known ? 'فك الضغط — $_extractDone/$_extractTotal' : 'قراءة الأرشيف…'),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: known ? _extractDone / _extractTotal : null,
          ),
        ],
      ),
    );
  }

  List<Widget> _buildSummary(ColorScheme scheme, ZipExtractionResult zip) {
    final wrapper = zip.wrapperFolder;
    final skipped = zip.skipped;
    return [
      const SizedBox(height: 16),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${_files.length} ملف — ${_formatMegabytes(zip.totalBytes)}'),
              if (wrapper != null && _stripRoot) Text('تمت إزالة المجلد: $wrapper'),
              if (wrapper != null && !_stripRoot)
                Text('سيبقى المجلد $wrapper ضمن مسارات المستودع'),
              if (_hasWorkflowFiles && !widget.user.isClassic)
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text(
                    'يحتوي الأرشيف ملفات .github/workflows: يلزم توكن '
                    'بصلاحية Workflows وإلا ستفشل آخر خطوة.',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              if (skipped.isNotEmpty)
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: EdgeInsets.zero,
                  shape: const Border(),
                  collapsedShape: const Border(),
                  title: Text('${skipped.length} عنصر متجاهَل'),
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 260),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: skipped.length,
                        itemBuilder: (context, i) {
                          final entry = skipped[i];
                          return ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              entry.path,
                              textDirection: TextDirection.ltr,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(entry.reason),
                          );
                        },
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
      if (_skippedByCount > 0 || _skippedBySize > 0)
        Card(
          color: scheme.errorContainer,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.warning_amber, color: scheme.onErrorContainer),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'المشروع الذي سيُرفع ناقص',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: scheme.onErrorContainer,
                        ),
                      ),
                    ),
                  ],
                ),
                if (_skippedByCount > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      'تجاوز الأرشيف حد عدد الملفات (${ZipLimits.maxFiles}): '
                      'تُجوهل $_skippedByCount ملف.',
                      style: TextStyle(color: scheme.onErrorContainer),
                    ),
                  ),
                if (_skippedBySize > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      '$_skippedBySize ملف أكبر من '
                      '${ZipLimits.maxFileBytes ~/ (1024 * 1024)} ميغابايت '
                      '(حد GitHub) فتُجوهل.',
                      style: TextStyle(color: scheme.onErrorContainer),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'افتح قائمة العناصر المتجاهَلة أعلاه لمعرفة أسمائها.',
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onErrorContainer,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
    ];
  }

  Widget _buildRunProgress(ColorScheme scheme) {
    final settled = !_uploading;
    final succeeded = settled && _result != null;
    final failed = settled && _error != null;
    final cancelled = settled && _cancelled;

    final String label;
    if (succeeded) {
      label = 'اكتمل الرفع';
    } else if (_uploading && _cancelRequested) {
      label = 'جارٍ الإلغاء…';
    } else if (failed) {
      label = 'توقف الرفع عند: ${_stageLabel(_stage)} — $_done/$_total';
    } else if (cancelled) {
      label = 'أُلغي الرفع عند: ${_stageLabel(_stage)} — $_done/$_total';
    } else {
      label = '${_stageLabel(_stage)} — $_done/$_total';
    }

    // Full only on success: a failed or cancelled run keeps the point it
    // reached instead of pretending it finished.
    final double? value = succeeded
        ? 1.0
        : (_total == 0 ? null : (_done / _total).clamp(0.0, 1.0).toDouble());
    final Color? color = failed
        ? scheme.error
        : cancelled
            ? scheme.outline
            : null;

    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: value, color: color),
          if (_uploading && _detail != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _detail!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final zip = _zip;
    final canStart = zip != null &&
        !_uploading &&
        !_picking &&
        !_starting &&
        !_deleting &&
        _result == null;

    return PopScope(
      // Leaving mid-upload needs an explicit confirmation.
      canPop: !_uploading,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_confirmLeave());
      },
      child: Scaffold(
        appBar: AppBar(title: Text(widget.repo.fullName)),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              if (!widget.isNewRepo)
                Card(
                  margin: const EdgeInsets.only(bottom: 16),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      'مستودع موجود: سيُضاف الرفع كـ commit جديد فوق الفرع '
                      '${widget.repo.defaultBranch}. تُستبدل الملفات التي لها '
                      'المسار نفسه، ولا تُحذف الملفات الأخرى.',
                    ),
                  ),
                ),
              TextField(
                controller: _messageController,
                enabled: !_uploading,
                decoration: const InputDecoration(
                  labelText: 'رسالة الالتزام',
                  border: OutlineInputBorder(),
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('إزالة المجلد الجذري من المسارات'),
                subtitle: Text(_stripSubtitle),
                value: _stripRoot,
                onChanged:
                    (_uploading || _result != null) ? null : _onStripChanged,
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _picking || _uploading ? null : _pickZip,
                icon: _picking
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.folder_zip),
                label: const Text('اختيار ملف ZIP'),
              ),
              if (_extracting) _buildExtractionProgress(),
              if (zip != null) ..._buildSummary(scheme, zip),
              if (_uploading || _hasRun) _buildRunProgress(scheme),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    _error!,
                    style: TextStyle(color: scheme.error),
                  ),
                ),
              if (_cancelled && !_uploading)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Row(
                    children: [
                      Icon(
                        Icons.info_outline,
                        size: 18,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'تم إلغاء الرفع. لم يُنشأ أي commit بملفاتك '
                          'ويمكنك المحاولة مجددًا.',
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                ),
              if (_result != null)
                Card(
                  color: scheme.secondaryContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('تم رفع ${_result!.fileCount} ملف إلى '
                            '${_result!.branch}'),
                        if (_excludedWorkflows > 0)
                          Text('استُبعد $_excludedWorkflows ملف من .github/workflows '
                              '(بسبب نقص صلاحية workflow)'),
                        if (_excludedSecrets > 0)
                          Text('استُبعد $_excludedSecrets ملف يُحتمل أنه '
                              'يحوي أسرارًا'),
                        const SizedBox(height: 8),
                        if (_result!.commitUrl != null)
                          SelectableText(_result!.commitUrl!),
                        const SizedBox(height: 8),
                        TextButton.icon(
                          onPressed: () {
                            final url =
                                _result!.commitUrl ?? widget.repo.htmlUrl;
                            Clipboard.setData(ClipboardData(text: url));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('تم النسخ')),
                            );
                          },
                          icon: const Icon(Icons.copy),
                          label: const Text('نسخ الرابط'),
                        ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: canStart ? _startUpload : null,
                child: Text(_startLabel),
              ),
              if (_uploading) ...[
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _cancelRequested
                      ? null
                      : () => setState(() => _cancelRequested = true),
                  child: Text(_cancelRequested ? 'جارٍ الإلغاء…' : 'إلغاء'),
                ),
              ],
              const SizedBox(height: 12),
              TextButton(
                // Leaving mid-upload goes through the confirmation above.
                onPressed: (_uploading || _deleting)
                    ? null
                    : () => Navigator.of(context).pop(),
                child: const Text('إنشاء مستودع آخر'),
              ),
              if (widget.isNewRepo && _result == null)
                TextButton.icon(
                  onPressed: (_uploading || _picking || _deleting)
                      ? null
                      : _deleteRepo,
                  style: TextButton.styleFrom(foregroundColor: scheme.error),
                  icon: _deleting
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.delete_outline),
                  label: const Text('حذف هذا المستودع'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
