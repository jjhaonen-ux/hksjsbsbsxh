/// Finds files that very likely hold credentials, by name only. Contents are
/// never read: the goal is a warning before anything leaves the phone, not a
/// full secret scanner, so false positives are acceptable and false
/// negatives are expected.
library;

/// `.env.example` and friends are templates meant to be committed.
const _templateSuffixes = {
  'example',
  'sample',
  'template',
  'dist',
  'tpl',
  'default',
  'defaults',
};

/// Exact file names (lower case).
const _secretNames = {
  'key.properties',
  'keystore.properties',
  'signing.properties',
  '.netrc',
  '.pgpass',
  'id_rsa',
  'id_dsa',
  'id_ecdsa',
  'id_ed25519',
};

/// Extensions (lower case, with the dot) of key and certificate stores.
const _secretExtensions = {
  '.jks',
  '.keystore',
  '.p12',
  '.pfx',
  '.pem',
};

/// Returns the paths from [relativePaths] that look like secrets, in the
/// order they were given.
List<String> findPotentialSecrets(Iterable<String> relativePaths) {
  return [
    for (final path in relativePaths)
      if (isPotentialSecret(path)) path,
  ];
}

bool isPotentialSecret(String relativePath) {
  final slash = relativePath.lastIndexOf('/');
  final name = (slash < 0 ? relativePath : relativePath.substring(slash + 1))
      .toLowerCase();
  if (name.isEmpty) return false;

  if (_secretNames.contains(name)) return true;

  // `.env`, `.env.local`, `.env.production` … but not `.env.example`.
  if (name == '.env') return true;
  if (name.startsWith('.env.')) {
    final suffix = name.substring('.env.'.length);
    return !_templateSuffixes.contains(suffix);
  }

  final dot = name.lastIndexOf('.');
  if (dot > 0) {
    return _secretExtensions.contains(name.substring(dot));
  }
  return false;
}
