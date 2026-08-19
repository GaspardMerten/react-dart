/// A build_runner [Builder] that compiles `.dartx` files to `.dartx.dart`.
///
/// This is dartx's equivalent of the JSX step in a JavaScript toolchain, except
/// there is no bundler to wire it into: `dart run build_runner build` (or
/// `watch`) is the whole pipeline.
library;

import 'package:build/build.dart';

import '../dartx/transpiler.dart';

/// Builder factory referenced from `build.yaml`.
Builder reactxDartxBuilder(BuilderOptions options) => DartxBuilder();

class DartxBuilder implements Builder {
  @override
  Map<String, List<String>> get buildExtensions => const {
        '.dartx': ['.dartx.dart'],
      };

  @override
  Future<void> build(BuildStep buildStep) async {
    final input = buildStep.inputId;
    final source = await buildStep.readAsString(input);
    final result = transpileDartx(source, uri: input.path);

    if (!result.ok) {
      // Reported as a build error with the position in the .dartx file, so the
      // message reads the same here as it does in the editor.
      for (final error in result.errors) {
        log.severe('${error.uri}:${error.line}:${error.column}: '
            '${error.message}');
      }
      throw StateError('dartx: ${input.path} failed to compile — '
          '${result.errors.first.message}');
    }

    await buildStep.writeAsString(
      input.changeExtension('.dartx.dart'),
      result.code!,
    );
  }
}
