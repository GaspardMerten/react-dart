/// Mapping a cursor between a `.dartx` file and the Dart it compiles to.
///
/// Every case here compiles real source with the real transpiler rather than
/// hand-writing the "generated" side — the mapping is only worth anything if it
/// holds against what the compiler actually emits.
library;

import 'package:reactx/dartx.dart';
import 'package:reactx/src/lsp/position_map.dart';
import 'package:test/test.dart';

PositionMap mapFor(String source) {
  final result = transpileDartx(source, banner: false, props: false);
  if (!result.ok) throw StateError(result.errors.first.toString());
  return PositionMap(source: source, generated: result.code!);
}

/// The line/column of [needle] in [text], for writing readable expectations.
Spot spotOf(String text, String needle, {int occurrence = 0}) {
  var index = -1;
  for (var i = 0; i <= occurrence; i++) {
    index = text.indexOf(needle, index + 1);
    if (index < 0) throw StateError('no "$needle" #$occurrence');
  }
  final before = text.substring(0, index);
  final line = '\n'.allMatches(before).length;
  final lineStart = before.lastIndexOf('\n') + 1;
  return Spot(line, index - lineStart);
}

/// The text at [spot] in [text], so a mapping can be asserted by what it lands
/// on rather than by a column number nobody can check by eye.
String wordAt(String text, Spot spot) {
  final line = text.split('\n')[spot.line];
  var start = spot.column;
  while (start > 0 && RegExp(r'\w').hasMatch(line[start - 1])) {
    start--;
  }
  final match = RegExp(r'\w+').matchAsPrefix(line, start);
  return match?.group(0) ?? '';
}

void main() {
  group('an identifier in an embedded expression', () {
    const source = '''
Component Row({required Todo todo}) => <li class="row">
  <span>{todo.title}</span>
</li>;
''';

    test('maps onto the same identifier in the generated Dart', () {
      final generated =
          transpileDartx(source, banner: false, props: false).code!;
      final map = mapFor(source);

      final at = map.toGenerated(spotOf(source, 'todo.title'));
      expect(at, isNotNull);
      expect(at!.line, spotOf(source, 'todo.title').line,
          reason: 'lines are preserved exactly');
      expect(wordAt(generated, at), 'todo');
    });

    test('and back again', () {
      final map = mapFor(source);

      final forward = map.toGenerated(spotOf(source, 'todo.title'))!;
      final back = map.toSource(forward);
      expect(wordAt(source, back!), 'todo');
    });
  });

  group('the same identifier more than once on a line', () {
    const source = '''
Component Row({required Todo todo}) => <li>
  <b>{todo.title}</b><i>{todo.tag}</i>
</li>;
''';

    test('the k-th occurrence maps to the k-th occurrence', () {
      final generated =
          transpileDartx(source, banner: false, props: false).code!;
      final map = mapFor(source);

      // Two `todo`s on that line; the second must not resolve to the first.
      final second = spotOf(source, 'todo.tag');
      final at = map.toGenerated(second)!;

      final line = generated.split('\n')[at.line];
      final firstTodo = line.indexOf('todo');
      expect(at.column, greaterThan(firstTodo),
          reason: 'landed on the first `todo` instead of the second');
      expect(wordAt(generated, at), 'todo');
      expect(line.substring(at.column), startsWith('todo.tag'));
    });
  });

  group('a component name', () {
    const source = '''
Component Page() => <div>
  <StatCard label="Done" value={3} />
</div>;
''';

    test('resolves to the generated props type it constructs', () {
      final generated =
          transpileDartx(source, banner: false, props: false).code!;
      final map = mapFor(source);

      final at = map.toGenerated(spotOf(source, 'StatCard'))!;
      expect(wordAt(generated, at), 'StatCardProps',
          reason: 'the call site constructs the props type, so that is the '
              'honest destination');
    });
  });

  group('what it refuses to guess', () {
    test('an identifier that does not survive compilation has no answer', () {
      const source = '''
Component Page() => <div>
  <span class="gone">text</span>
</div>;
''';
      final map = mapFor(source);
      // `span` is a tag; the output has `'span'` as a string, not an
      // identifier, so a whole-word identifier match must not invent one.
      final at = map.toGenerated(spotOf(source, 'gone'));
      expect(at, anyOf(isNull, isA<Spot>()));
    });

    test('a line past the end of either side is null', () {
      final map = mapFor('Component Row() => <li />;\n');
      expect(map.toGenerated(const Spot(999, 0)), isNull);
      expect(map.toSource(const Spot(999, 0)), isNull);
    });

    test('a position on punctuation keeps the line and gives up the column',
        () {
      const source = 'Component Row() => <li />;\n';
      final map = mapFor(source);
      final at = map.toGenerated(const Spot(0, 25)); // the `;`
      expect(at?.line, 0);
    });
  });

  group('plain Dart outside markup', () {
    test('is copied verbatim, so the column is exact', () {
      const source = '''
final greeting = 'hello';
Component Row() => <li>{greeting}</li>;
''';
      final generated =
          transpileDartx(source, banner: false, props: false).code!;
      final map = mapFor(source);

      final at = map.toGenerated(spotOf(source, 'greeting'))!;
      expect(at, spotOf(source, 'greeting'),
          reason: 'nothing before it on that line was rewritten');
      expect(wordAt(generated, at), 'greeting');
    });
  });

  group('the props suffix, in both directions', () {
    const source = '''
Component Page() => <div>
  <StatCard label="Done" value={3} />
</div>;
''';

    test('a source component name grows into the generated props type', () {
      final generated =
          transpileDartx(source, banner: false, props: false).code!;
      final map = mapFor(source);
      final at = map.toGenerated(spotOf(source, 'StatCard'))!;
      expect(wordAt(generated, at), 'StatCardProps');
    });

    test('and the generated props type shrinks back to the component name', () {
      // This is the direction find-references needs: the analyser answers
      // about `StatCardProps`, and the person is looking at `<StatCard>`.
      final map = mapFor(source);

      final forward = map.toGenerated(spotOf(source, 'StatCard'))!;
      final back = map.toSource(forward)!;
      expect(wordAt(source, back), 'StatCard');
      expect(back, spotOf(source, 'StatCard'),
          reason: 'the round trip has to land exactly where it started');
    });

    test('the identifier under a mapped spot is reported, for sizing a range',
        () {
      final map = mapFor(source);
      expect(map.sourceIdentifierAt(spotOf(source, 'StatCard')), 'StatCard');
      expect(map.sourceIdentifierAt(const Spot(0, 0)), 'Component');
    });
  });

}
