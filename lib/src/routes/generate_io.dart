/// The file-system half of the route generator.
///
/// [generateRoutes] is deliberately pure — a map in, source out — so the
/// build_runner builder can hand it assets rather than files. This is the same
/// job for a real directory, which is what the dev server needs.
library;

import 'dart:io';

import 'file_routes.dart';

/// Rewrites `<dir>.g.dart` for every directory named `routes` under [root].
///
/// Returns the files that actually changed. A routes directory with no route
/// file in it is left alone rather than replaced with an empty table: an empty
/// directory is far more likely to be a half-finished move than an intent to
/// delete every route.
List<File> generateRoutesUnder(Directory root) {
  final written = <File>[];
  if (!root.existsSync()) return written;

  for (final entity in root.listSync(recursive: true)) {
    if (entity is! Directory) continue;
    if (_nameOf(entity) != 'routes') continue;

    final sources = <String, String>{};
    for (final file in entity.listSync(recursive: true)) {
      if (file is! File) continue;
      final relative = file.path.substring(entity.path.length + 1);
      if (!routeFileNames.contains(_basename(relative))) continue;
      sources[relative.replaceAll(Platform.pathSeparator, '/')] =
          file.readAsStringSync();
    }
    if (sources.isEmpty) continue;

    final out = File('${entity.path}.g.dart');
    final code = generateRoutes(sources, importPrefix: 'routes/');
    // Writing an identical file would wake a watcher for nothing.
    if (!out.existsSync() || out.readAsStringSync() != code) {
      out.writeAsStringSync(code);
      written.add(out);
    }
  }
  return written;
}

String _nameOf(Directory dir) =>
    dir.uri.pathSegments.lastWhere((s) => s.isNotEmpty, orElse: () => '');

String _basename(String path) => path.split(Platform.pathSeparator).last;
