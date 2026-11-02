import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/models.dart';

class ZipLimits {
  /// GitHub rejects blobs above 100 MB. Blobs are streamed from disk, so this
  /// no longer risks exhausting memory.
  static const int maxFileBytes = 100 * 1024 * 1024;

  /// Total size after extraction. Everything is written to the temp
  /// directory (not held in memory), so the real constraint is free storage
  /// plus how long GitHub's rate limits make the upload take.
  static const int maxTotalBytes = 500 * 1024 * 1024;

  /// Small text files are embedded in tree requests, so a large file count is
  /// workable; large/binary files still cost one request each.
  static const int maxFiles = 6000;
}

class ZipFailure implements Exception {
  ZipFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Why an entry was left out. The UI uses it to tell harmless skips (links,
/// odd paths) from the ones that make the uploaded project incomplete.
enum SkipKind { badPath, symlink, gitData, fileTooBig, fileCountLimit }

class SkippedEntry {
  const SkippedEntry(this.path, this.reason, this.kind);
  final String path;
  final String reason;
  final SkipKind kind;
}

class ZipExtractionResult {
  const ZipExtractionResult({
    required this.entries,
    required this.rootDir,
    required this.skipped,
    required this.totalBytes,
    this.wrapperFolder,
  });

  /// Every extracted file; paths are exactly as stored in the archive.
  /// Use [filesFor] to get the list to upload.
  final List<ExtractedFile> entries;
  final Directory rootDir;
  final List<SkippedEntry> skipped;
  final int totalBytes;

  /// The single top-level folder that holds every file (e.g. "myproject-main"),
  /// or null when the archive has no such folder.
  final String? wrapperFolder;

  /// The files as they will appear in the repository. Stripping is a cheap
  /// view over the same files on disk, so flipping the switch in the UI never
  /// needs to extract the archive again.
  List<ExtractedFile> filesFor({required bool stripWrapper}) {
    final wrapper = wrapperFolder;
    if (!stripWrapper || wrapper == null) return entries;
    final cut = wrapper.length + 1; // folder name + '/'
    return [
      for (final f in entries)
        ExtractedFile(
          absPath: f.absPath,
          relativePath: f.relativePath.substring(cut),
          size: f.size,
          executable: f.executable,
        ),
    ];
  }

  int skippedCount(SkipKind kind) =>
      skipped.where((s) => s.kind == kind).length;

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
  /// [tempDirProvider] only exists so tests can point the extraction at their
  /// own folder: `path_provider` has no implementation under `flutter test`.
  /// The app always uses the default (`getTemporaryDirectory`).
  ZipService({Future<Directory> Function()? tempDirProvider})
      : _tempDirProvider = tempDirProvider ?? getTemporaryDirectory;

  final Future<Directory> Function() _tempDirProvider;

  static const _junkNames = {'.DS_Store', 'Thumbs.db', 'desktop.ini'};
  static const _junkDirs = {'__MACOSX'};

  /// Prefix of every extraction directory inside the temp folder.
  static const _workDirPrefix = 'gzp_';

  /// Removes extraction folders left behind by a run that was killed before
  /// it could clean up. Meant to be called once at start-up; folders created
  /// in the last minute are left alone in case an extraction is already
  /// running.
  static Future<void> cleanupStale() async {
    try {
      final root = await getTemporaryDirectory();
      final nowMicros = DateTime.now().microsecondsSinceEpoch;
      await for (final entity in root.list(followLinks: false)) {
        if (entity is! Directory) continue;
        final name = p.basename(entity.path);
        if (!name.startsWith(_workDirPrefix)) continue;
        final created = int.tryParse(name.substring(_workDirPrefix.length));
        if (created != null && nowMicros - created < 60 * 1000 * 1000) {
          continue;
        }
        try {
          await entity.delete(recursive: true);
        } catch (_) {}
      }
    } catch (_) {
      // Best effort only.
    }
  }

  /// Extracts the ZIP at [zipPath] into a fresh temp directory.
  ///
  /// The archive is read from disk as a stream and every entry is written
  /// straight to disk, all on a background isolate: nothing proportional to
  /// the archive size is held in memory and the UI thread stays free.
  ///
  /// Files keep their full archive paths on disk; whether the wrapper folder
  /// is dropped is decided later through [ZipExtractionResult.filesFor].
  Future<ZipExtractionResult> extract(
    String zipPath, {
    void Function(int done, int total)? onProgress,
  }) async {
    final tempRoot = await _tempDirProvider();
    final workDir = Directory(
      p.join(
        tempRoot.path,
        '$_workDirPrefix${DateTime.now().microsecondsSinceEpoch}',
      ),
    );

    final results = ReceivePort();
    final errors = ReceivePort();
    final exits = ReceivePort();
    final completer = Completer<ZipExtractionResult>();

    void fail(String message) {
      if (!completer.isCompleted) completer.completeError(ZipFailure(message));
    }

    results.listen((dynamic message) {
      if (message is! List || message.isEmpty) return;
      switch (message[0]) {
        case 'progress':
          onProgress?.call(message[1] as int, message[2] as int);
        case 'fail':
          fail(message[1] as String);
        case 'done':
          if (completer.isCompleted) return;
          completer.complete(_decodeResult(message, workDir));
      }
    });
    errors.listen((dynamic _) => fail('تعذر فك ضغط الأرشيف'));
    exits.listen((dynamic _) {
      // The result message is sent just before the isolate exits; give it a
      // moment to be delivered before treating the exit as a failure.
      Future<void>.delayed(
        const Duration(milliseconds: 200),
        () => fail('انتهت عملية فك الضغط قبل اكتمالها'),
      );
    });

    final isolate = await Isolate.spawn<List<Object?>>(
      _isolateMain,
      [results.sendPort, zipPath, workDir.path],
      onError: errors.sendPort,
      onExit: exits.sendPort,
    );

    try {
      return await completer.future;
    } catch (_) {
      try {
        if (await workDir.exists()) await workDir.delete(recursive: true);
      } catch (_) {}
      rethrow;
    } finally {
      isolate.kill(priority: Isolate.immediate);
      results.close();
      errors.close();
      exits.close();
    }
  }

  static ZipExtractionResult _decodeResult(List<dynamic> m, Directory workDir) {
    final files = (m[1] as List).map((dynamic e) {
      final f = e as List;
      return ExtractedFile(
        absPath: f[0] as String,
        relativePath: f[1] as String,
        size: f[2] as int,
        executable: f[3] as bool,
      );
    }).toList();
    final skipped = (m[2] as List).map((dynamic e) {
      final s = e as List;
      return SkippedEntry(
        s[0] as String,
        s[1] as String,
        SkipKind.values.byName(s[2] as String),
      );
    }).toList();
    return ZipExtractionResult(
      entries: files,
      rootDir: workDir,
      skipped: skipped,
      totalBytes: m[3] as int,
      wrapperFolder: m[4] as String?,
    );
  }

  // ------------------------------------------------- background isolate

  static void _isolateMain(List<Object?> args) {
    final port = args[0] as SendPort;
    try {
      final result = _extractSync(
        args[1] as String,
        args[2] as String,
        (done, total) => port.send(<Object?>['progress', done, total]),
      );
      port.send(result);
    } on ZipFailure catch (e) {
      port.send(<Object?>['fail', e.message]);
    } catch (e) {
      port.send(<Object?>['fail', 'تعذر فك ضغط الأرشيف (${e.runtimeType})']);
    }
  }

  /// Runs inside the isolate. Returns a message made only of sendable
  /// primitives: `['done', files, skipped, totalBytes, wrapperFolder]`.
  /// Files travel as `[absPath, relativePath, size, executable]` and skipped
  /// entries as `[path, reason, SkipKind.name]`.
  static List<Object?> _extractSync(
    String zipPath,
    String workDirPath,
    void Function(int done, int total) onProgress,
  ) {
    final input = InputFileStream(zipPath);
    final workDir = Directory(workDirPath);
    try {
      final Archive archive;
      try {
        // No `verify:` here on purpose: it would inflate every entry into
        // memory before any size limit is applied. The CRC is checked below,
        // from the bytes that were written to disk.
        archive = ZipDecoder().decodeStream(input);
      } catch (e) {
        throw ZipFailure('تعذر قراءة ملف ZIP — قد يكون تالفًا (${e.runtimeType})');
      }

      final skipped = <List<String>>[];
      final candidates = <ArchiveFile>[];
      final candidatePaths = <String>[];
      final seenPaths = <String>{};
      // `.git` folders are summarised in one line each, not listed file by file.
      final gitCounts = <String, int>{};
      var declaredBytes = 0;

      for (final entry in archive.files) {
        // Directories are skipped: Git does not track empty folders.
        if (!entry.isFile) continue;

        final rawName = entry.name.replaceAll('\\', '/');
        if (rawName.isEmpty) continue;

        // "./src/a.txt" is just another way to write "src/a.txt".
        final segments = rawName.split('/').where((s) => s != '.').toList();
        if (segments.isEmpty) continue;
        if (segments.any((s) => s.isEmpty)) {
          skipped.add([rawName, 'مسار غير طبيعي', SkipKind.badPath.name]);
          continue;
        }
        final path = segments.join('/');
        if (!_isSafePath(path)) {
          skipped.add([
            path,
            'مسار خارج جذر الأرشيف (Zip Slip)',
            SkipKind.badPath.name,
          ]);
          continue;
        }
        if (segments.any(_junkDirs.contains)) {
          continue; // macOS metadata, not worth reporting
        }
        if (_junkNames.contains(segments.last)) {
          continue;
        }

        // Local Git data: huge, useless in a new commit, and it may hold
        // credentials (remote URLs, tokens). GitHub also refuses any path
        // with a `.git` component.
        final gitAt = segments.indexWhere((s) => s.toLowerCase() == '.git');
        if (gitAt >= 0) {
          final prefix = segments.sublist(0, gitAt + 1).join('/');
          gitCounts[prefix] = (gitCounts[prefix] ?? 0) + 1;
          continue;
        }

        if (entry.isSymbolicLink) {
          skipped.add([path, 'رابط رمزي متجاهَل', SkipKind.symlink.name]);
          continue;
        }
        if (!seenPaths.add(path)) {
          skipped.add([
            path,
            'مسار مكرر داخل الأرشيف (أُخذت النسخة الأولى)',
            SkipKind.badPath.name,
          ]);
          continue;
        }
        if (entry.size > ZipLimits.maxFileBytes) {
          skipped.add([
            path,
            'الحجم ${(entry.size / (1024 * 1024)).toStringAsFixed(1)} '
                'ميغابايت يتجاوز الحد',
            SkipKind.fileTooBig.name,
          ]);
          continue;
        }

        // Count limit first: files that are left out must not also eat into
        // the size budget, or a big archive could fail for bytes that would
        // never have been uploaded.
        if (candidates.length >= ZipLimits.maxFiles) {
          skipped.add([
            path,
            'تجاوز حد عدد الملفات (${ZipLimits.maxFiles})',
            SkipKind.fileCountLimit.name,
          ]);
          continue;
        }
        declaredBytes += entry.size;
        if (declaredBytes > ZipLimits.maxTotalBytes) {
          throw ZipFailure(_totalTooBig());
        }

        candidates.add(entry);
        candidatePaths.add(path);
      }

      for (final e in gitCounts.entries) {
        skipped.add([
          '${e.key}/',
          'بيانات Git المحلية — لا تُرفع (${e.value} ملف)',
          SkipKind.gitData.name,
        ]);
      }

      if (candidates.isEmpty) {
        throw ZipFailure('الأرشيف لا يحتوي على ملفات قابلة للرفع');
      }

      final wrapper = wrapperFolderOf(candidatePaths);
      workDir.createSync(recursive: true);

      // Lets the UI leave the "reading archive" phase as soon as the number
      // of files is known, instead of after the first batch is written.
      onProgress(0, candidates.length);

      final files = <List<Object?>>[];
      var writtenBytes = 0;
      var withExecBit = 0;
      for (var i = 0; i < candidates.length; i++) {
        final entry = candidates[i];
        // Full archive path: the wrapper folder is only removed later, in
        // ZipExtractionResult.filesFor.
        final relative = candidatePaths[i];

        final absPath = p.joinAll([workDir.path, ...relative.split('/')]);
        final file = File(absPath);
        file.parent.createSync(recursive: true);

        // Decompress straight to disk, never into a Dart list.
        _writeEntry(entry, absPath, relative);

        // The size declared in the ZIP header can lie; trust the disk.
        final actual = file.lengthSync();
        if (actual > ZipLimits.maxFileBytes) {
          file.deleteSync();
          skipped.add([
            relative,
            'الحجم الفعلي ${(actual / (1024 * 1024)).toStringAsFixed(1)} '
                'ميغابايت يتجاوز الحد',
            SkipKind.fileTooBig.name,
          ]);
          continue;
        }
        writtenBytes += actual;
        if (writtenBytes > ZipLimits.maxTotalBytes) {
          throw ZipFailure(_totalTooBig());
        }

        _verifyCrc(entry, file, relative);

        final hasExecBit = _hasExecBit(entry.mode);
        if (hasExecBit) withExecBit++;
        files.add(<Object?>[
          absPath,
          relative,
          actual,
          // Provisional: the archive's own bit. Reconciled below.
          hasExecBit,
        ]);
        if (i % 20 == 0 || i == candidates.length - 1) {
          onProgress(i + 1, candidates.length);
        }
      }

      if (files.isEmpty) {
        throw ZipFailure('لم يتبقَّ أي ملف بعد استبعاد المسارات غير الصالحة');
      }

      // Zips made from FAT/exFAT storage often mark EVERY file executable.
      // When that is what the archive says, its modes carry no information
      // and only the well-known scripts are treated as executable.
      final modesUnreliable = files.length >= 5 && withExecBit == files.length;
      for (final f in files) {
        final fromArchive = !modesUnreliable && (f[3] as bool);
        f[3] = fromArchive || _looksLikeScript(f[1] as String, f[0] as String);
      }

      return <Object?>['done', files, skipped, writtenBytes, wrapper];
    } catch (_) {
      // Leave no half-extracted directory behind.
      try {
        if (workDir.existsSync()) workDir.deleteSync(recursive: true);
      } catch (_) {}
      rethrow;
    } finally {
      // closeSync: في archive 4.x تعيد close() كائن Future، ولا نريد تركها معلّقة.
      input.closeSync();
    }
  }

  /// Writes one entry to [absPath], turning every low-level failure into a
  /// message that says which file was the problem.
  static void _writeEntry(ArchiveFile entry, String absPath, String relative) {
    try {
      final out = OutputFileStream(absPath);
      try {
        entry.writeContent(out);
      } finally {
        // closeSync وليس close(): الأخيرة غير متزامنة، فكان الملف يُقرأ في
        // _verifyCrc وحجمه يُفحص قبل أن تُفرَّغ الذاكرة المؤقتة إلى القرص.
        out.closeSync();
      }
    } on FileSystemException {
      throw ZipFailure(
        'تعذرت الكتابة على التخزين المؤقت أثناء فك "$relative". '
        'تحقق من أن مساحة التخزين ليست ممتلئة.',
      );
    } catch (e) {
      throw ZipFailure(
        'تعذر فك ضغط "$relative": الأرشيف تالف أو يستخدم تقنية ضغط أو '
        'تشفيرًا غير مدعوم (${e.runtimeType}).',
      );
    }
  }

  /// Compares the CRC-32 recorded in the archive with the one of the bytes
  /// that actually reached the disk, reading the file in chunks.
  ///
  /// A mismatch means the archive is damaged (or password protected): better
  /// to stop than to commit a silently corrupted file. A missing or zero CRC
  /// is treated as "not recorded" and skipped.
  static void _verifyCrc(ArchiveFile entry, File file, String relative) {
    final expected = entry.crc32;
    if (expected == null || expected == 0) return;

    var actual = 0;
    try {
      final raf = file.openSync();
      try {
        var crc = 0;
        while (true) {
          final chunk = raf.readSync(1024 * 1024);
          if (chunk.isEmpty) break;
          crc = getCrc32(chunk, crc);
        }
        actual = crc;
      } finally {
        raf.closeSync();
      }
    } on FileSystemException {
      throw ZipFailure('تعذرت قراءة "$relative" للتحقق من سلامته.');
    }

    if (actual != expected) {
      throw ZipFailure(
        'الملف "$relative" تالف داخل الأرشيف (فشل فحص CRC). '
        'قد يكون الأرشيف ناقصًا أو محميًا بكلمة مرور؛ أعد إنشاءه وجرّب مجددًا.',
      );
    }
  }

  /// Unix permission bits live in the high half of the external attributes.
  /// Like Git, only the owner-execute bit counts, and only for regular files:
  /// archives built on Windows carry no Unix bits at all.
  static bool _hasExecBit(int mode) {
    final type = mode & 0xF000;
    if (type != 0 && type != 0x8000) return false;
    return (mode & 0x40) != 0;
  }

  /// Scripts that must stay runnable even when the archive lost its modes
  /// (zips made on Windows or by many phone archivers).
  static bool _looksLikeScript(String relative, String absPath) {
    final name = relative.split('/').last;
    if (name == 'gradlew' || name == 'mvnw') return true;
    if (!name.endsWith('.sh')) return false;
    try {
      final raf = File(absPath).openSync();
      try {
        final head = raf.readSync(2);
        return head.length == 2 && head[0] == 0x23 && head[1] == 0x21; // "#!"
      } finally {
        raf.closeSync();
      }
    } on FileSystemException {
      return false;
    }
  }

  static String _totalTooBig() =>
      'حجم المحتوى بعد الفك يتجاوز '
      '${ZipLimits.maxTotalBytes ~/ (1024 * 1024)} ميغابايت (الحد الأقصى '
      'للتطبيق). قسّم المشروع أو احذف الملفات الكبيرة من الأرشيف ثم أعد '
      'المحاولة.';

  /// Rejects absolute paths, drive letters and any `..` segment.
  static bool _isSafePath(String path) {
    if (path.startsWith('/')) return false;
    if (RegExp(r'^[A-Za-z]:').hasMatch(path)) return false;
    final segments = path.split('/');
    if (segments.any((s) => s == '..' || s == '.')) return false;
    return true;
  }

  /// Returns the single top-level folder that contains EVERY path, if any.
  ///
  /// Only one level is ever reported. For `app/src/a.dart` and
  /// `app/src/b.dart` the answer is `app`, not `app/src`, so a real `src/`
  /// folder is never swallowed. Archives with files at their root, or with
  /// several top-level folders, have no wrapper.
  static String? wrapperFolderOf(List<String> paths) {
    if (paths.isEmpty) return null;
    final top = paths.first.split('/').first;
    for (final path in paths) {
      final segments = path.split('/');
      if (segments.length < 2 || segments.first != top) return null;
    }
    return top;
  }
}
