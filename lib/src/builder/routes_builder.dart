/// A build_runner [Builder] that turns a routes directory into a route table.
///
/// One output per package, because a route table is a single file: the builder
/// takes the synthetic `$package$` input, globs the routes directory, and
/// writes the generated table. It reads the `.dartx` *sources* rather than the
/// `.dartx.dart` the dartx builder produces, so the two builders never wait on
/// each other.
///
/// It is off unless a target asks for it, since most packages have no routes
/// directory:
///
/// ```yaml
/// targets:
///   $default:
///     builders:
///       reactx|routes:
///         enabled: true
///         options:
///           routes: example/todo_app/src/routes
///           output: example/todo_app/src/routes.g.dart
/// ```
library;

import 'package:build/build.dart';
import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

import '../routes/file_routes.dart';

/// Builder factory referenced from `build.yaml`.
Builder reactxRoutesBuilder(BuilderOptions options) => RoutesBuilder(
      directory: _option(options, 'routes') ?? 'lib/routes',
      output: _option(options, 'output') ?? 'lib/routes.g.dart',
    );

String? _option(BuilderOptions options, String name) {
  final value = options.config[name];
  if (value == null) return null;
  if (value is! String || value.isEmpty) {
    throw ArgumentError('reactx|routes: "$name" must be a non-empty path');
  }
  return p.url.normalize(value);
}

class RoutesBuilder implements Builder {
  RoutesBuilder({required this.directory, required this.output});

  /// The routes directory, relative to the package root.
  final String directory;

  /// Where the table is written, relative to the package root.
  final String output;

  @override
  Map<String, List<String>> get buildExtensions => {
        r'$package$': [output],
      };

  @override
  Future<void> build(BuildStep buildStep) async {
    final sources = <String, String>{};
    await for (final id in buildStep.findAssets(Glob('$directory/**'))) {
      final relative = p.url.relative(id.path, from: directory);
      final name = p.url.basename(relative);
      // A `.dartx` page and the `.dartx.dart` beside it are the same route.
      // Reading the source is what keeps the generated file from becoming an
      // input to this build.
      if (!routeFileNames.contains(name)) continue;
      sources[relative] = await buildStep.readAsString(id);
    }

    final prefix = p.url.relative(directory, from: p.url.dirname(output));
    await buildStep.writeAsString(
      AssetId(buildStep.inputId.package, output),
      generateRoutes(
        sources,
        importPrefix: prefix == '.' ? '' : '$prefix/',
      ),
    );
  }
}
