class GitHubUser {
  const GitHubUser({
    required this.login,
    this.name,
    this.avatarUrl,
    this.scopes = const [],
  });

  final String login;
  final String? name;
  final String? avatarUrl;

  /// OAuth scopes reported by GitHub. Empty for fine-grained tokens.
  final List<String> scopes;

  factory GitHubUser.fromJson(
    Map<String, dynamic> json, {
    List<String> scopes = const [],
  }) {
    return GitHubUser(
      login: json['login'] as String,
      name: json['name'] as String?,
      avatarUrl: json['avatar_url'] as String?,
      scopes: scopes,
    );
  }
}

class CreatedRepo {
  const CreatedRepo({
    required this.owner,
    required this.name,
    required this.htmlUrl,
    required this.defaultBranch,
  });

  final String owner;
  final String name;
  final String htmlUrl;
  final String defaultBranch;

  String get fullName => '$owner/$name';

  factory CreatedRepo.fromJson(Map<String, dynamic> json) {
    final owner = json['owner'] as Map<String, dynamic>?;
    return CreatedRepo(
      owner: (owner?['login'] as String?) ?? '',
      name: json['name'] as String,
      htmlUrl: json['html_url'] as String,
      defaultBranch: (json['default_branch'] as String?) ?? 'main',
    );
  }
}

/// A single file extracted from the ZIP and written to the temp directory.
class ExtractedFile {
  const ExtractedFile({
    required this.absPath,
    required this.relativePath,
    required this.size,
  });

  final String absPath;

  /// Path inside the repository, always '/' separated, no leading slash.
  final String relativePath;
  final int size;
}

enum PushStage { preparing, blobs, tree, commit, ref, finished }

class PushProgress {
  const PushProgress({
    required this.stage,
    required this.done,
    required this.total,
    this.detail,
  });

  final PushStage stage;
  final int done;
  final int total;
  final String? detail;
}

class PushResult {
  const PushResult({
    required this.commitSha,
    required this.commitUrl,
    required this.branch,
    required this.fileCount,
  });

  final String commitSha;
  final String? commitUrl;
  final String branch;
  final int fileCount;
}

class PushCancelled implements Exception {
  @override
  String toString() => 'تم إلغاء الرفع';
}
