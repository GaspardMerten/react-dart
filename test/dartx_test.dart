/// Tests for the dartx transpiler: `.dartx` source in, Dart out.
library;

import 'package:reactx/dartx.dart';
import 'package:test/test.dart';

/// Transpiles [source], failing the test on any diagnostic.
String compile(String source) {
  final result = transpileDartx(source, banner: false, uri: 'test.dartx');
  if (!result.ok) fail('unexpected dartx error: ${result.errors.first}');
  return result.code!;
}

/// Transpiles [source], expecting it to fail, and returns the first error.
DartxError compileError(String source) {
  final result = transpileDartx(source, banner: false, uri: 'test.dartx');
  expect(result.ok, isFalse, reason: 'expected a compile error');
  return result.errors.first;
}

void main() {
  group('Dart passthrough', () {
    test('leaves a file without markup byte-for-byte identical', () {
      const source = '''
import 'dart:math';

/// Doc comment with <angle> brackets.
class Foo<T extends num> {
  final List<T> values;
  Foo(this.values);
  bool get sorted => values.isEmpty || values.first < values.last;
}
''';
      expect(compile(source), source);
    });

    test('ignores markup-looking text inside strings and comments', () {
      const source = r'''
final a = '<div>not markup</div>';
final b = "also <span> not";
final c = r'<raw>';
final d = """<triple>""";
// <div>comment</div>
/* <nested /* block */ comment> */
final e = 'interpolated ${1 + 1} <p>';
''';
      expect(compile(source), source);
    });
  });

  group("Dart's own angle brackets", () {
    test('typed literals are not elements', () {
      expect(compile('final a = <String>[];'), 'final a = <String>[];');
      expect(compile('final b = <String, Object?>{};'),
          'final b = <String, Object?>{};');
      expect(compile('final c = <int>{1};'), 'final c = <int>{1};');
    });

    test('comparisons and shifts are not elements', () {
      expect(compile('final a = x < y;'), 'final a = x < y;');
      expect(compile('final b = x<<y;'), 'final b = x<<y;');
      expect(compile('final c = x <= y && y >= z;'), 'final c = x <= y && y >= z;');
      expect(compile('if (a < b) print(1);'), 'if (a < b) print(1);');
    });

    test('generics are not elements', () {
      expect(compile('Map<String, List<int>> m = {};'),
          'Map<String, List<int>> m = {};');
      expect(compile('final v = decode<Model>(json);'),
          'final v = decode<Model>(json);');
    });

    test('a lowercase tag before a bracket is still markup', () {
      // `<span>[…]` is markup; `<String>[…]` is a typed literal. The name
      // decides, because host tags are lowercase and types are not.
      expect(compile('final v = <span>[a]</span>;'),
          contains("h('span', const <String, Object?>{}, <Object?>['[a]'])"));
    });
  });

  group('elements', () {
    test('host element with attributes and text', () {
      expect(
        compile('final v = <div class="card">Hello</div>;'),
        'final v = '
        "h('div', <String, Object?>{'class': 'card'}, <Object?>['Hello']);",
      );
    });

    test('capitalised names construct their props type, not a tag string', () {
      // The generated constructor is ordinary Dart, so a misspelled attribute
      // or a wrongly typed value is a compile error where you wrote it.
      expect(compile('final v = <Counter start={1} />;'),
          contains('CounterProps(start: (1))'));
      expect(compile('final v = <widgets.Card />;'),
          contains('widgets.CardProps()'));
    });

    test('an attribute that is a Dart keyword takes its conventional name', () {
      expect(compile('final v = <Chip class="on" />;'),
          contains("ChipProps(className: 'on')"));
      expect(compile('final v = <Field for="name" />;'),
          contains("FieldProps(htmlFor: 'name')"));
      expect(compile('final v = <Icon aria-label="close" />;'),
          contains("IconProps(ariaLabel: 'close')"));
    });

    test('a spread on a component is refused, with a reason', () {
      final result = transpileDartx('final v = <Card {...rest} />;');
      expect(result.ok, isFalse);
      expect(result.errors.single.message, contains('spread'));
      expect(result.errors.single.message, contains('named arguments'));
    });

    test('children reach a component as a typed list', () {
      expect(compile('final v = <Modal>ok</Modal>;'),
          contains("ModalProps(children: normalizeChildren(<Object?>['ok']))"));
    });

    test('bare attributes mean true', () {
      expect(compile('final v = <input disabled />;'),
          contains("'disabled': true"));
    });

    test('expression attributes pass through unchanged', () {
      expect(
        compile('final v = <button onClick={() => go(1)} />;'),
        contains("'onClick': (() => go(1))"),
      );
    });

    test('spread attributes become a map spread', () {
      expect(compile('final v = <div {...props} id="x" />;'),
          contains("<String, Object?>{...props, 'id': 'x'}"));
    });

    test('self-closing and void elements need no children', () {
      expect(compile('final v = <br />;'),
          'final v = h(\'br\', const <String, Object?>{}, const <Object?>[]);');
      // HTML void elements may omit the slash, unlike JSX.
      expect(compile('final v = <img src="a.png">;'),
          contains("h('img', <String, Object?>{'src': 'a.png'}"));
    });

    test('fragments become FragmentNode', () {
      expect(
        compile('final v = <><p>a</p><p>b</p></>;'),
        startsWith('final v = FragmentNode(normalizeChildren(<Object?>['),
      );
    });

    test('nested markup inside an expression child', () {
      final out = compile(
          'final v = <ul>{items.map((i) => <li key={i}>{i}</li>)}</ul>;');
      expect(out, contains("h('ul',"));
      expect(out, contains("h('li', <String, Object?>{'key': i}"));
    });

    test('markup nested in an attribute expression', () {
      expect(
        compile('final v = <Modal footer={<b>ok</b>} />;'),
        contains("footer: (h('b', const <String, Object?>{}, "
            "<Object?>['ok']))"),
      );
    });
  });

  group('text', () {
    test('collapses structural whitespace the way JSX does', () {
      final out = compile('''
final v = <p>
  hello
  world
</p>;
''');
      expect(out, contains("<Object?>['hello world']"));
    });

    test('decodes HTML entities in text and quoted attributes', () {
      expect(compile('final v = <p title="a &amp; b">5 &lt; 6</p>;'),
          contains("<String, Object?>{'title': 'a & b'}, <Object?>['5 < 6']"));
    });

    test('escapes quotes and dollars in emitted literals', () {
      expect(compile(r"final v = <p>it's $5</p>;"),
          contains(r"'it\'s \$5'"));
    });

    test('drops comments', () {
      expect(compile('final v = <p><!-- gone -->{/* also gone */}kept</p>;'),
          contains("<Object?>['kept']"));
    });
  });

  group('expression position', () {
    const positions = {
      'return': 'VNode f() => f2(); VNode f2() { return <p />; }',
      'arrow': 'VNode f() => <p />;',
      'argument': 'final v = wrap(<p />);',
      'list': 'final v = [<p />, <b />];',
      'ternary': 'final v = c ? <p /> : <b />;',
      'and': 'final v = c && <p />;',
      'assignment': 'final v = <p />;',
      'map value': "final v = {'a': <p />};",
      'collection for': 'final v = [for (final x in xs) <p />];',
      'collection if': 'final v = [if (ok) <p />];',
    };
    for (final entry in positions.entries) {
      test('markup is recognised after ${entry.key}', () {
        expect(compile(entry.value), contains("h('p'"));
      });
    }
  });

  group('line fidelity', () {
    test('generated code has the same number of lines as the source', () {
      const source = '''
VNode app(Props props) {
  return (
    <div class="app">
      <h1>Title</h1>
      <p>
        Body text
      </p>
    </div>
  );
}
''';
      expect('\n'.allMatches(compile(source)).length,
          '\n'.allMatches(source).length);
    });

    test('each element lands on the line it was written on', () {
      const source = '''
final v = <div>
  <span>one</span>
  <em>two</em>
</div>;
''';
      final lines = compile(source).split('\n');
      expect(lines[1], contains("h('span'"));
      expect(lines[2], contains("h('em'"));
    });

    test('code after the markup keeps its line number', () {
      const source = '''
final v = <div>
  <p>x</p>
</div>;
final marker = 1;
''';
      expect(compile(source).split('\n')[3], 'final marker = 1;');
    });
  });

  group('errors', () {
    test('mismatched closing tag', () {
      final error = compileError('final v = <div>text</span>;');
      expect(error.message, contains('does not match'));
      expect(error.line, 1);
      expect(error.uri, 'test.dartx');
    });

    test('unclosed element points at the opening tag', () {
      final error = compileError('final v = <div>\n  <p>text</p>\n;');
      expect(error.message, contains('unclosed `<div>`'));
      expect(error.line, 1);
    });

    test('unterminated expression', () {
      final error = compileError('final v = <p>{1 + </p>;');
      expect(error.message, contains('unterminated'));
    });

    test('empty attribute value', () {
      final error = compileError('final v = <p id={} />;');
      expect(error.message, contains('is empty'));
    });

    test('bare braces are not an attribute', () {
      final error = compileError('final v = <p {props} />;');
      expect(error.message, contains('spread'));
    });

    test('unquoted attribute value', () {
      final error = compileError('final v = <p id=x />;');
      expect(error.message, contains('quoted string or `{expression}`'));
    });
  });

  test('the banner goes at the end so line numbers survive', () {
    final code = transpileDartx('final v = <p />;', uri: 'a.dartx').code!;
    expect(code.split('\n').first, startsWith('final v ='));
    expect(code, contains('GENERATED by dartx from a.dartx'));
  });

  // -------------------------------------------------------------------------
  group('telling Dart and markup apart', () {
    // Every case here was once decided the wrong way. The first two produced
    // invalid Dart with no diagnostic at all, which is the worst failure a
    // preprocessor can have.
    test('a component whose first child is an expression is markup', () {
      expect(compile('final a = <Card>{count}</Card>;'),
          contains('CardProps(children:'));
      expect(compile('final b = <Card>[1]</Card>;'), contains('CardProps('));
      expect(compile('final c = <Card>(x)</Card>;'), contains('CardProps('));
    });

    test('the same shape with no closing tag is still a type argument', () {
      // `<Card>[c1]` is a list of Cards; only a closing tag makes it markup.
      expect(compile('final w = <Card>[c1];'), 'final w = <Card>[c1];');
    });

    test('a function type in a type-argument list is Dart', () {
      expect(compile('final x = <void Function()>[];'),
          'final x = <void Function()>[];');
      expect(compile('final y = <int Function(int)>[];'),
          'final y = <int Function(int)>[];');
    });

    test('an apostrophe in markup nested in an expression is text', () {
      // The `{}` scanner used to read `'` as a Dart string and swallow the
      // rest of the file.
      final out =
          compile("final a = <div>{c ? <p>don't</p> : <p>no</p>}</div>;");
      expect(out, contains(r"don\'t"));
      expect(out, contains("'no'"));
    });

    test('markup inside a string interpolation is compiled', () {
      expect(compile(r"final t = 'x ${<div/>} y';"),
          contains(r"${h('div'"));
    });

    test('a raw string is left entirely alone', () {
      expect(compile(r"final v = r'x ${<div/>} y';"),
          r"final v = r'x ${<div/>} y';");
    });
  });

  // -------------------------------------------------------------------------
  group('inputs that used to crash or pass silently', () {
    test('an out-of-range numeric entity is left as written', () {
      expect(compile('final f = <div>&#99999999;</div>;'),
          contains(r'&#99999999;'));
      expect(compile('final g = <div>&#xD800;</div>;'), contains(r'&#xD800;'));
    });

    test('a real entity still decodes', () {
      expect(compile('final h = <div>&amp;&#65;</div>;'), contains(r"'&A'"));
    });

    test('the same attribute twice is refused', () {
      final result = transpileDartx('final c = <div class="a" class="b"/>;');
      expect(result.ok, isFalse);
      expect(result.errors.single.message, contains('set twice'));
    });
  });

}
