import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/models.dart';

class ZipLimits {
  /// GitHub rejects blobs above 100 MB.
  static const int maxFileBytes = 100 * 1024 * 1024;
  static const int maxTotalBytes = 900 * 1024 * 1024;
  static const int maxFiles = 6000;
}

class ZipFailure implements Exception {
  ZipFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

class SkippedEntry {
  const SkippedEntry(this.path, this.reason);
  final String path;
  final String reason;
}

class ZipExtractionResult {
  const ZipExtractionResult({
    required this.files,
    required this.rootDir,
    required this.skipped,
    required this.totalBytes,
    this.strippedRoot,
  });

  final List<ExtractedFile> files;
  final Directory rootDir;
  final List<SkippedEntry> skipped;
  final int totalBytes;

  /// Wrapper folder removed from every path, e.g. "myproject-main".
  final String? strippedRoot;

  Future<void> cleanup() async {
    try {
      if (await rootDir.exists()) {
        await rootDir.delete(recursive: true);
      }
    } catch (_) {
      // Best effort: the OS reclaims the temp dir anyway.
    }
  }
}

class ZipService {
  static const _junkNames = {'.DS_Store', 'Thumbs.db', 'desktop.ini'};
  static const _junkDirs = {'__MACOSX'};

  Future<ZipExtractionResult> extract(
    Uint8List zipBytes, {
    bool stripCommonRoot = true,
    void Function(int done, int total)? onProgress,
  }) async {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(zipBytes, verify: false);
    } catch (e) {
      throw ZipFailure('تعذر قراءة ملف ZIP — قد يكون تالفًا (${e.runtimeType})');
    }

    final skipped = <SkippedEntry>[];
    final candidates = <ArchiveFile>[];
    final candidatePaths = <String>[];
    var totalBytes = 0;

    for (final entry in archive.files) {
      // Directories are skipped: Git does not track empty folders.
      if (!entry.isFile) continue;

      final rawName = entry.name.replaceAll('\\', '/');
      if (rawName.isEmpty) continue;

      final segments = rawName.split('/');
      if (segments.any((s) => s.isEmpty)) {
        skipped.add(SkippedEntry(rawName, 'مسار غير طبيعي'));
        continue;
      }
      if (!_isSafePath(rawName)) {
        skipped.add(SkippedEntry(rawName, 'مسار خارج جذر الأرشيف (Zip Slip)'));
        continue;
      }
      if (segments.any(_junkDirs.contains)) {
        continue; // macOS metadata, not worth reporting
      }
      if (_junkNames.contains(segments.last)) {
        continue;
      }
      if (entry.isSymbolicLink) {
        skipped.add(SkippedEntry(rawName, 'رابط رمزي متجاهَل'));
        continue;
      }
      if (entry.size > ZipLimits.maxFileBytes) {
        skipped.add(SkippedEntry(
          rawName,
          'الحجم ${(entry.size / (1024 * 1024)).toStringAsFixed(1)} '
              'ميغابايت يتجاوز الحد',
        ));
        continue;
      }

      totalBytes += entry.size;
      if (totalBytes > ZipLimits.maxTotalBytes) {
        throw ZipFailure(
          'حجم المحتوى بعد الفك يتجاوز '
          '${ZipLimits.maxTotalBytes ~/ (1024 * 1024)} ميغابايت',
        );
      }
      if (candidates.length >= ZipLimits.maxFiles) {
        skipped.add(SkippedEntry(rawName, 'تجاوز حد عدد الملفات'));
        continue;
      }

      candidates.add(entry);
      candidatePaths.add(rawName);
    }

    if (candidates.isEmpty) {
      throw ZipFailure('الأرشيف لا يحتوي على ملفات قابلة للرفع');
    }

    final root = stripCommonRoot ? _commonRoot(candidatePaths) : null;

    final tempRoot = await getTemporaryDirectory();
    final workDir = Directory(
      p.join(tempRoot.path, 'gzp_${DateTime.now().millisecondsSinceEpoch}'),
    );
    await workDir.create(recursive: true);

    final files = <ExtractedFile>[];
    for (var i = 0; i < candidates.length; i++) {
      final entry = candidates[i];
      final full = candidatePaths[i];
      final relative = root == null ? full : full.substring(root.length + 1);
      if (relative.isEmpty) continue;

      final content = entry.content;
      final data = content is Uint8List
          ? content
          : Uint8List.fromList(content as List<int>);

      final absPath = p.join(workDir.path, ...relative.split('/'));
      final file = File(absPath);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(data, flush: false);

      files.add(ExtractedFile(
        absPath: absPath,
        relativePath: relative,
        size: data.length,
      ));
      onProgress?.call(i + 1, candidates.length);
    }

    if (files.isEmpty) {
      await workDir.delete(recursive: true);
      throw ZipFailure('لم يتبقَّ أي ملف بعد استبعاد المسارات غير الصالحة');
    }

    return ZipExtractionResult(
      files: files,
      rootDir: workDir,
      skipped: skipped,
      totalBytes: files.fold<int>(0, (sum, f) => sum + f.size),
      strippedRoot: root,
    );
  }

  /// Rejects absolute paths, drive letters and any `..` segment.
  bool _isSafePath(String path) {
    if (path.startsWith('/')) return false;
    if (RegExp(r'^[A-Za-z]:').hasMatch(path)) return false;
    final segments = path.split('/');
    if (segments.any((s) => s == '..' || s == '.')) return false;
    return true;
  }

  /// Returns the wrapper folder shared by every path, if any.
  String? _commonRoot(List<String> paths) {
    if (paths.isEmpty) return null;
    final first = paths.first.split('/');
    var depth = first.length - 1; // never consume the file name itself
    if (depth == 0) return null;
    for (final path in paths.skip(1)) {
      final segments = path.split('/');
      final limit = segments.length - 1;
      var i = 0;
      while (i < depth && i < limit && segments[i] == first[i]) {
        i++;
      }
      depth = i;
      if (depth == 0) return null;
    }
    return first.sublist(0, depth).join('/');
  }
}
