import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/models.dart';
import '../services/github_service.dart';
import '../services/zip_service.dart';

class PushScreen extends StatefulWidget {
  const PushScreen({super.key, required this.service, required this.repo});

  final GitHubService service;
  final CreatedRepo repo;

  @override
  State<PushScreen> createState() => _PushScreenState();
}

class _PushScreenState extends State<PushScreen> {
  final _messageController = TextEditingController();

  ZipExtractionResult? _zip;
  bool _picking = false;
  bool _uploading = false;
  bool _cancelRequested = false;
  bool _stripRoot = true;

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
    _messageController.dispose();
    // Fire and forget: the OS reclaims the temp dir anyway.
    _zip?.cleanup();
    super.dispose();
  }

  Future<void> _pickZip() async {
    setState(() {
      _picking = true;
      _error = null;
      _result = null;
    });
    try {
      final picked = await FilePicker.platform.pickFiles(withData: false);
      final path = picked?.files.single.path;
      if (path == null) return;
      if (!path.toLowerCase().endsWith('.zip')) {
        setState(() => _error = 'الملف المختار ليس ZIP');
        return;
      }

      await _zip?.cleanup();
      final bytes = await File(path).readAsBytes();
      final result = await ZipService().extract(
        bytes,
        stripCommonRoot: _stripRoot,
        onProgress: (done, total) {
          if (!mounted) return;
          setState(() => _detail = 'فك الضغط $done/$total');
        },
      );
      if (!mounted) return;
      setState(() {
        _zip = result;
        _detail = null;
        _done = 0;
        _total = 0;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _startUpload() async {
    final zip = _zip;
    if (zip == null) return;
    setState(() {
      _uploading = true;
      _cancelRequested = false;
      _error = null;
      _result = null;
      _done = 0;
      _total = zip.files.length;
      _stage = PushStage.preparing;
    });
    try {
      final result = await widget.service.pushFiles(
        owner: widget.repo.owner,
        repo: widget.repo.name,
        files: zip.files,
        branch: widget.repo.defaultBranch,
        commitMessage: _messageController.text.trim().isEmpty
            ? 'Import project from ZIP'
            : _messageController.text.trim(),
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
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

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

  @override
  Widget build(BuildContext context) {
    final zip = _zip;
    final progress = _total == 0 ? 0.0 : _done / _total;

    return Scaffold(
      appBar: AppBar(title: Text(widget.repo.fullName)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
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
              subtitle: const Text('مفيد عندما يُضغط مجلد واحد داخل الأرشيف'),
              value: _stripRoot,
              onChanged: _uploading ? null : (v) => setState(() => _stripRoot = v),
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
            if (zip != null) ...[
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${zip.files.length} ملف — '
                          '${(zip.totalBytes / (1024 * 1024)).toStringAsFixed(2)} ميغابايت'),
                      if (zip.strippedRoot != null)
                        Text('تم إزالة المجلد: ${zip.strippedRoot}'),
                      if (zip.skipped.isNotEmpty)
                        Text('${zip.skipped.length} عنصر متجاهَل'),
                    ],
                  ),
                ),
              ),
            ],
            if (_uploading || _done > 0) ...[
              const SizedBox(height: 20),
              Text('${_stageLabel(_stage)} — $_done/$_total'),
              const SizedBox(height: 8),
              LinearProgressIndicator(value: _uploading ? progress : 1),
              if (_detail != null)
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
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (_result != null)
              Card(
                color: Theme.of(context).colorScheme.secondaryContainer,
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('تم رفع ${_result!.fileCount} ملف إلى '
                          '${_result!.branch}'),
                      const SizedBox(height: 8),
                      if (_result!.commitUrl != null)
                        SelectableText(_result!.commitUrl!),
                      const SizedBox(height: 8),
                      TextButton.icon(
                        onPressed: () {
                          final url = _result!.commitUrl ?? widget.repo.htmlUrl;
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
              onPressed: (_zip == null || _uploading || _picking) ? null : _startUpload,
              child: const Text('بدء الرفع'),
            ),
            if (_uploading) ...[
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => setState(() => _cancelRequested = true),
                child: const Text('إلغاء'),
              ),
            ],
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('إنشاء مستودع آخر'),
            ),
          ],
        ),
      ),
    );
  }
}
