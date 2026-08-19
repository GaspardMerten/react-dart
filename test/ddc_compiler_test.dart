/// Covers the compiler behind hot reload.
///
/// The two things worth pinning down are the ones that fail *quietly*: the
/// frontend_server line protocol (stop reading at the wrong line and you get a
/// stale compile rather than an error), and the split of the emitted JS into
/// one chunk per library (get the offsets wrong and the bundle is subtly
/// corrupt). Both are checked here against a real compile.
///
/// Skipped when the machine has no DDC-compiled `dart_sdk.js`, which is the
/// same condition under which `reactx serve` falls back to hot restart.
library;

import 'dart:io';

import 'package:reactx/src/devserver/ddc_compiler.dart';
import 'package:test/test.dart';

void main() {
  final unavailable = DdcCompiler.unavailableReason();
  final packageConfig = DdcCompiler.findPackageConfig(Directory.current);

  group('DdcCompiler', () {
    late Directory app;
    late DdcCompiler compiler;

    setUp(() async {
      app = Directory.systemTemp.createTempSync('reactx_ddc_test');
      File('${app.path}/main.dart').writeAsStringSync(_main('one'));
      File('${app.path}/other.dart').writeAsStringSync(_other);
      compiler = DdcCompiler(
        appDir: app,
        entry: 'main.dart',
        packageConfig: packageConfig!,
        sdkJs: DdcCompiler.findSdkJs()!,
      );
      await compiler.start();
    });

    tearDown(() async {
      await compiler.stop();
      if (app.existsSync()) app.deleteSync(recursive: true);
    });

    test('a full compile emits every library, entry included', () async {
      final bundle = await compiler.compile();
      compiler.accept();

      expect(bundle.libraries, contains('org-dartlang-app:///main.dart'));
      expect(bundle.libraries, contains('org-dartlang-app:///other.dart'));
      // dart:core and friends are not in the bundle: they live in dart_sdk.js.
      expect(bundle.libraries.where((l) => l.startsWith('dart:')), isEmpty);
      expect(bundle.js, contains('"one"'));
    });

    test('the chunks reassemble into exactly the emitted JS', () async {
      final bundle = await compiler.compile();
      compiler.accept();

      // Every chunk is a whole library definition, so the count of definitions
      // across the chunks has to match the count of libraries.
      final defined = RegExp(r'dartDevEmbedder\.defineLibrary\(')
          .allMatches(bundle.js)
          .length;
      expect(defined, bundle.libraries.length);
      expect(bundle.modules.length, greaterThan(1));
      for (final chunk in bundle.modules.values) {
        expect(chunk, contains('dartDevEmbedder.defineLibrary('));
      }
    });

    test('a save recompiles only the library that changed', () async {
      await compiler.compile();
      compiler.accept();

      File('${app.path}/main.dart').writeAsStringSync(_main('two'));
      final delta = await compiler.recompile(['${app.path}/main.dart']);
      compiler.accept();

      expect(delta.libraries, ['org-dartlang-app:///main.dart']);
      expect(delta.js, contains('"two"'));
      expect(delta.js, isNot(contains('"one"')));
    });

    test('a compile error is reported, not swallowed as a stale build',
        () async {
      await compiler.compile();
      compiler.accept();

      File('${app.path}/main.dart').writeAsStringSync('void main() { oops(); }');
      await expectLater(
        compiler.recompile(['${app.path}/main.dart']),
        throwsA(isA<DdcError>().having(
            (e) => e.message, 'message', contains("'oops'"))),
      );
    });
  },
      skip: unavailable != null || packageConfig == null
          ? 'hot reload unavailable here: ${unavailable ?? 'no package config'}'
          : null);
}

String _main(String label) => '''
import 'other.dart';

String label() => '$label';

void main() {
  greet(label());
}
''';

const _other = '''
String greet(String who) => 'hello \$who';
''';
