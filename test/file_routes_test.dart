/// Tests for the file-system route generator.
///
/// The generator is a pure `Map<String, String> -> String`, so everything here
/// is an assertion about generated *source*. What it produces is checked for
/// real in `test/todo_app_test.dart`, which runs the table it emits.
library;

import 'dart:async';
import 'dart:convert';

import 'dart:io';

import 'package:build/build.dart';
import 'package:glob/glob.dart';
import 'package:reactx/src/builder/routes_builder.dart';
import 'package:reactx/src/routes/file_routes.dart';
import 'package:reactx/src/routes/generate_io.dart';
import 'package:test/test.dart';

/// Runs [builder] over [assets] and returns everything it wrote.
///
/// `package:build_test` would normally do this, but the version that resolves
/// against our `build` constraint no longer compiles; the four members a
/// builder actually touches are cheaper to fake than the constraint is to move.
Future<Map<String, String>> run(
  Builder builder,
  Map<String, String> assets,
) async {
  final step = _Step(assets);
  await builder.build(step);
  return step.written;
}

class _Step implements BuildStep {
  _Step(this.assets);

  final Map<String, String> assets;
  final Map<String, String> written = {};

  @override
  AssetId get inputId => AssetId('a', r'$package$');

  @override
  Stream<AssetId> findAssets(Glob glob, {String? package}) => Stream.fromIterable(
      assets.keys.where(glob.matches).map((path) => AssetId('a', path)));

  @override
  Future<String> readAsString(AssetId id, {Encoding encoding = utf8}) async {
    final source = assets[id.path];
    if (source == null) throw AssetNotFoundException(id);
    return source;
  }

  @override
  Future<void> writeAsString(AssetId id, FutureOr<String> contents,
      {Encoding encoding = utf8}) async {
    written[id.path] = await contents;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName} is not faked');
}

/// A minimal page file declaring a component called [name].
String page(String name, [String extra = '']) =>
    "import 'package:reactx/reactx.dart';\n"
    'Component $name() => <div />;\n'
    '$extra';

void main() {
  group('readRouteFile', () {
    test('recognises the three file names, in either extension', () {
      expect(readRouteFile('page.dartx', page('Home'))!.kind,
          RouteFileKind.page);
      expect(readRouteFile('layout.dart', page('Shell'))!.kind,
          RouteFileKind.layout);
      expect(readRouteFile('a/error.dartx', page('Boom'))!.kind,
          RouteFileKind.error);
    });

    test('ignores a file the conventions do not name', () {
      expect(readRouteFile('helpers.dartx', page('Helper')), isNull);
      expect(readRouteFile('todo/list.dart', page('List')), isNull);
    });

    test('ignores a page with no component in it', () {
      expect(readRouteFile('page.dartx', 'const x = 1;'), isNull);
    });

    test('reports the directory, not the file', () {
      expect(readRouteFile('todo/[id]/page.dartx', page('Todo'))!.path,
          'todo/[id]');
      expect(readRouteFile('page.dartx', page('Home'))!.path, '');
    });

    test('picks up the optional top-level declarations by name', () {
      final file = readRouteFile(
        'page.dartx',
        page(
          'Todo',
          'Future<Object?> loader(LoaderContext c) => f();\n'
          'const middleware = [guard];\n'
          "String title = 'Todo';\n",
        ),
      )!;
      expect(file.declares, {'loader', 'middleware', 'title'});
    });

    test('does not mistake a nested mention for a declaration', () {
      final file = readRouteFile(
        'page.dartx',
        page('Todo', 'void main() {\n  final loader = 1;\n}\n'),
      )!;
      expect(file.declares, isEmpty);
    });
  });

  group('generateRoutes', () {
    test('an empty directory still produces a table', () {
      final out = generateRoutes(const {});
      expect(out, contains('final routes = <Route>[]'));
    });

    test('a lone page becomes the index route', () {
      final out = generateRoutes({'page.dartx': page('Home')});
      expect(out, contains("import 'page.dartx.dart' as _page;"));
      expect(out, contains('final indexRoute = Route(\n  index: true,'));
      expect(out, contains('element: const _page.HomeProps()'));
      expect(out, contains('  indexRoute,'));
    });

    test('a folder becomes a path segment', () {
      final out = generateRoutes({'stats/page.dartx': page('Stats')});
      expect(out, contains("path: 'stats'"));
      expect(out, contains('final statsRoute = Route('));
    });

    test('[id] becomes :id and [...rest] becomes the catch-all', () {
      final out = generateRoutes({
        'todo/[id]/page.dartx': page('Todo'),
        '[...rest]/page.dartx': page('NotFound'),
      });
      expect(out, contains("path: 'todo/:id'"));
      expect(out, contains('final todoIdRoute = Route('));
      expect(out, contains("path: '*'"));
      expect(out, contains('final catchAllRoute = Route('));
    });

    test("TanStack's own \$id and \$ spellings work too", () {
      final out = generateRoutes({
        r'todo/$id/page.dartx': page('Todo'),
        r'$/page.dartx': page('NotFound'),
      });
      expect(out, contains("path: 'todo/:id'"));
      expect(out, contains("path: '*'"));
      // A `$` in the URI would otherwise be read as an interpolation.
      expect(out, contains(r"import r'todo/$id/page.dartx.dart'"));
    });

    test('a (group) folder adds no path segment', () {
      final out = generateRoutes({
        '(marketing)/about/page.dartx': page('About'),
      });
      expect(out, contains("path: 'about'"));
      expect(out, isNot(contains('marketing/')));
    });

    test('a layout wraps its directory, and its sibling page is the index', () {
      final out = generateRoutes({
        'layout.dartx': page('Shell'),
        'page.dartx': page('Home'),
        'stats/page.dartx': page('Stats'),
      });
      expect(out, contains('final rootRoute = Route('));
      expect(
        out,
        contains('  children: [\n'
            '    indexRoute,\n'
            '    statsRoute,\n'
            '  ],'),
      );
      // The layout owns the table; the pages are reached through it.
      expect(out, contains('final routes = <Route>[\n  rootRoute,\n];'));
    });

    test('a nested layout keeps the path relative to its own parent', () {
      final out = generateRoutes({
        'layout.dartx': page('Shell'),
        'todo/layout.dartx': page('TodoShell'),
        'todo/[id]/page.dartx': page('Todo'),
      });
      expect(out, contains("final todoLayoutRoute = Route(\n  path: 'todo'"));
      // Relative to `todo/`, not repeated.
      expect(out, contains("path: ':id'"));
    });

    test('loader, middleware, encode, decode and title are wired through', () {
      final out = generateRoutes({
        'todo/page.dartx': page(
          'Todo',
          'Future<Object?> loader(LoaderContext c) => f();\n'
          'const middleware = [guard];\n'
          'Object? encode(Object? d) => d;\n'
          'Object? decode(Object? j) => j;\n'
          "const title = 'Todo';\n",
        ),
      });
      for (final name in ['loader', 'middleware', 'encode', 'decode', 'title']) {
        expect(out, contains('$name: _todo_page.$name'));
      }
    });

    test('error.dartx beside a page becomes its errorElement', () {
      final out = generateRoutes({
        'todo/page.dartx': page('Todo'),
        'todo/error.dartx': page('TodoError'),
      });
      expect(
        out,
        contains('errorElement: const _todo_error.TodoErrorProps()'),
      );
    });

    test('a child route nests under the page above it', () {
      final out = generateRoutes({
        'todo/[id]/page.dartx': page('Todo'),
        'todo/[id]/edit/page.dartx': page('Edit'),
      });
      expect(out, contains('final todoIdEditRoute = Route('));
      expect(out, contains('  children: [\n    todoIdEditRoute,\n  ],'));
    });

    test('two same-named folders under different parents do not collide', () {
      final out = generateRoutes({
        'todo/[id]/edit/page.dartx': page('TodoEdit'),
        'user/[id]/edit/page.dartx': page('UserEdit'),
      });
      expect(out, contains('final todoIdEditRoute = Route('));
      expect(out, contains('final userIdEditRoute = Route('));
    });

    test('identical reduced names get a numbered suffix rather than clash', () {
      final out = generateRoutes({
        'to-do/page.dartx': page('A'),
        'to_do/page.dartx': page('B'),
      });
      expect(out, contains('final toDoRoute = Route('));
      expect(out, contains('final toDoRoute2 = Route('));
    });

    test('imports are aliased, so two pages may both declare a loader', () {
      final out = generateRoutes({
        'a/page.dartx': page('A', 'Future<Object?> loader(LoaderContext c) => f();\n'),
        'b/page.dartx': page('B', 'Future<Object?> loader(LoaderContext c) => f();\n'),
      });
      expect(out, contains('loader: _a_page.loader'));
      expect(out, contains('loader: _b_page.loader'));
    });

    test('importPrefix is prepended to every import', () {
      final out =
          generateRoutes({'page.dartx': page('Home')}, importPrefix: 'src/routes/');
      expect(out, contains("import 'src/routes/page.dartx.dart' as _page;"));
    });

    test('a .dart page is imported as itself, a .dartx page as its output', () {
      final out = generateRoutes({
        'page.dartx': page('Home'),
        'plain/page.dart': "Component Plain() => h('div', null);",
      });
      expect(out, contains("import 'page.dartx.dart'"));
      expect(out, contains("import 'plain/page.dart'"));
    });
  });

  group('RoutesBuilder', () {
    test('globs the routes directory and writes one table', () async {
      final written = await run(
        RoutesBuilder(directory: 'lib/routes', output: 'lib/routes.g.dart'),
        {
          'lib/routes/layout.dartx': page('Shell'),
          'lib/routes/page.dartx': page('Home'),
          'lib/routes/stats/page.dartx': page('Stats'),
          // Neither of these is a route file, and neither may be read.
          'lib/routes/components/card.dartx': page('Card'),
          'lib/main.dart': 'void main() {}',
        },
      );
      final out = written['lib/routes.g.dart']!;
      expect(out, contains("import 'routes/layout.dartx.dart' as _layout;"));
      expect(out, contains("import 'routes/stats/page.dartx.dart' as _stats_page;"));
      expect(out, contains('final rootRoute = Route('));
      expect(out, isNot(contains('CardProps')));
    });

    test('reads the .dartx source, never the .dartx.dart beside it', () async {
      final written = await run(
        RoutesBuilder(directory: 'lib/routes', output: 'lib/routes.g.dart'),
        {
          'lib/routes/page.dartx': page('Home'),
          'lib/routes/page.dartx.dart': 'Component Home() => stale;',
        },
      );
      final out = written['lib/routes.g.dart']!;
      expect(out, contains("import 'routes/page.dartx.dart' as _page;"));
      // One import, not two: the source and its output are one route.
      expect('import '.allMatches(out).length, 2); // the router, and the page
    });

    test('an output beside the routes directory needs no import prefix',
        () async {
      final written = await run(
        RoutesBuilder(directory: 'lib/routes', output: 'lib/routes/all.g.dart'),
        {'lib/routes/page.dartx': page('Home')},
      );
      expect(written['lib/routes/all.g.dart'],
          contains("import 'page.dartx.dart' as _page;"));
    });

    test('a missing routes directory still produces a table', () async {
      final written = await run(
        RoutesBuilder(directory: 'lib/routes', output: 'lib/routes.g.dart'),
        {'lib/main.dart': 'void main() {}'},
      );
      expect(written['lib/routes.g.dart'],
          contains('final routes = <Route>[];'));
    });

    test('the factory rejects an empty configured path', () {
      expect(
        () => reactxRoutesBuilder(const BuilderOptions({'routes': ''})),
        throwsArgumentError,
      );
    });
  });

  group('generateRoutesUnder', () {
    late Directory root;

    setUp(() => root = Directory.systemTemp.createTempSync('reactx_routes'));
    tearDown(() => root.deleteSync(recursive: true));

    void write(String path, String contents) {
      final file = File('${root.path}/$path')
        ..parent.createSync(recursive: true);
      file.writeAsStringSync(contents);
    }

    test('writes one table per routes directory', () {
      write('src/routes/page.dartx', page('Home'));
      write('src/routes/stats/page.dartx', page('Stats'));

      final written = generateRoutesUnder(root);
      expect(written.map((f) => f.path.substring(root.path.length + 1)),
          ['src/routes.g.dart']);
      final code = File('${root.path}/src/routes.g.dart').readAsStringSync();
      expect(code, contains("import 'routes/stats/page.dartx.dart'"));
      expect(code, contains('final statsRoute = Route('));
    });

    test('rewrites nothing when nothing changed', () {
      write('src/routes/page.dartx', page('Home'));
      expect(generateRoutesUnder(root), hasLength(1));
      // An identical rewrite would wake the watcher for nothing.
      expect(generateRoutesUnder(root), isEmpty);
    });

    test('a routes directory with no route file is left alone', () {
      write('src/routes/components/card.dartx', page('Card'));
      write('src/routes.g.dart', '// mine');
      expect(generateRoutesUnder(root), isEmpty);
      expect(File('${root.path}/src/routes.g.dart').readAsStringSync(), '// mine');
    });

    test('a missing directory is not an error', () {
      expect(generateRoutesUnder(Directory('${root.path}/nope')), isEmpty);
    });
  });
}
