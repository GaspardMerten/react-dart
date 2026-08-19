import 'package:reactx/reactx.dart';
import 'package:reactx/src/builder/emitter.dart';
import 'package:reactx/src/jsx.dart' show parseTemplate;
import 'package:test/test.dart';

// The file the build_runner precompiler generated from the fixture.
import 'fixtures/jsx_fixture.dart';
import 'fixtures/jsx_fixture.reactx.g.dart';

void main() {
  group('jsx precompiler', () {
    test('a precompiled builder in the cache is used by jsx()', () {
      const key = '__reactx_test_template__';
      registerCompiledTemplate(key, (args) => TextNode('precompiled:${args[0]}'));
      expect(renderToString(jsx(key, ['X'])), 'precompiled:X');
    });

    test('emitter produces code equivalent to the runtime interpreter', () {
      // The generated register function fills the cache with emitted builders;
      // rendering through it must match what the runtime parser would produce.
      registerJsxFixtureTemplates();
      final html = renderToString(use(fixtureCounter));
      expect(html, contains('<section class="counter">'));
      expect(html, contains('<p>Value: <strong>0</strong></p>'));
      expect(html, contains('<button>-</button><button>+</button>'));
    });

    test('emitTemplate emits a builder expression', () {
      final code = emitTemplate(parseTemplate(r'<div class="x">${0}</div>'));
      expect(code, startsWith('(List<Object?> args) =>'));
      expect(code, contains("h('div'"));
      expect(code, contains("'class': 'x'"));
      expect(code, contains('args[0]'));
    });
  });
}
