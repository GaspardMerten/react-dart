/// Scoped styles: a stylesheet that can only reach its own component's markup.
///
/// The mechanism is the one Vue uses — an attribute on every element the file
/// renders, and the same attribute required by every selector — because a class
/// in dartx is often an expression, and renaming classes cannot follow
/// `class={done ? 'todo is-done' : 'todo'}`.
library;

import 'package:reactx/dartx.dart';
import 'package:reactx/reactx.dart';
import 'package:reactx/src/dartx/css.dart';
import 'package:test/test.dart';

String compile(String source, {String uri = 'lib/card.dartx'}) {
  final result = transpileDartx(source, uri: uri, banner: false);
  if (!result.ok) throw StateError(result.errors.first.toString());
  return result.code!;
}

const _card = r'''
import 'package:reactx/reactx.dart';

@scoped
const styles = """
.card { padding: 1rem; }
.card .title:hover { color: red; }
@media (max-width: 30rem) { .card { padding: 0; } }
@keyframes spin { from { opacity: 0; } }
""";

Component Card({required String title}) => <div class="card">
  <span class="title">{title}</span>
</div>;
''';

void main() {
  group('rewriting the stylesheet', () {
    test('a selector is confined to elements carrying the scope', () {
      expect(scopeCss('.card { padding: 1rem; }', 'data-rx-ab12'),
          '.card[data-rx-ab12] { padding: 1rem; }');
    });

    test('the attribute goes before a pseudo, not after it', () {
      // `.card:hover[data-…]` is valid CSS that matches nothing useful.
      expect(scopeCss('.card:hover { }', 'x'), startsWith('.card[x]:hover'));
      expect(scopeCss('.card::before { }', 'x'), startsWith('.card[x]::before'));
    });

    test('only the element a selector finally selects is scoped', () {
      // Scoping every step would demand the attribute on ancestors too, which
      // breaks the moment a component renders inside another one's markup.
      expect(scopeCss('.card .title { }', 'x'), '.card .title[x] { }');
      expect(scopeCss('.a > .b { }', 'x'), '.a > .b[x] { }');
    });

    test('each selector in a list is scoped', () {
      expect(scopeCss('.a, .b { }', 'x'), '.a[x], .b[x] { }');
    });

    test('a conditional group is scoped inside, not outside', () {
      expect(scopeCss('@media (min-width: 10px) { .a { } }', 'x'),
          '@media (min-width: 10px) { .a[x] { } }');
    });

    test('keyframes are left alone, because those are not selectors', () {
      // `from[x]` would silently stop the animation from having any steps.
      final scoped = scopeCss('@keyframes spin { from { } to { } }', 'x');
      expect(scoped, isNot(contains('from[x]')));
      expect(scoped, isNot(contains('to[x]')));
    });

    test('comments and string values are not selectors either', () {
      expect(scopeCss('/* .a { } */ .b { }', 'x'),
          '/* .a { } */ .b[x] { }');
      expect(scopeCss('.a::after { content: "} .b {"; }', 'x'),
          contains('.a[x]::after'));
    });

    test('an existing attribute selector is kept', () {
      expect(scopeCss('input[type="text"] { }', 'x'),
          'input[type="text"][x] { }');
    });
  });

  group('compiling a file that has one', () {
    test('every host element it renders carries the scope', () {
      final code = compile(_card);
      final scope = RegExp(r"'(data-rx-[0-9a-f]{6})'").firstMatch(code)!.group(1)!;

      final stamped = RegExp.escape("'$scope': ''");
      expect(RegExp(stamped).allMatches(code).length, 2,
          reason: 'the div and the span it contains');
    });

    test('the stylesheet is rewritten to match, and hung off the component', () {
      final code = compile(_card);
      final scope = RegExp(r"'(data-rx-[0-9a-f]{6})'").firstMatch(code)!.group(1)!;

      expect(code, contains('.card[$scope] { padding: 1rem; }'));
      expect(code, contains('.card .title[$scope]:hover'));
      expect(code, contains(r'String? get styles => _$dartxStyles;'));
    });

    test("the author's own constant is left exactly as written", () {
      // They wrote plain CSS; that is what they should still see in their file.
      expect(compile(_card), contains('.card { padding: 1rem; }'));
    });

    test('the scope is stable across contents but differs across files', () {
      final a = compile(_card, uri: 'lib/a.dartx');
      final b = compile(_card, uri: 'lib/b.dartx');
      String scopeOf(String code) =>
          RegExp(r'data-rx-([0-9a-f]{6})').firstMatch(code)!.group(1)!;

      expect(scopeOf(a), isNot(scopeOf(b)));
      expect(scopeOf(compile('$_card\n// a comment', uri: 'lib/a.dartx')),
          scopeOf(a),
          reason: 'editing a file should not restyle every cached page');
    });

    test('a file without a stylesheet is untouched', () {
      final plain = compile('''
import 'package:reactx/reactx.dart';

Component Bare() => <div class="bare" />;
''');
      expect(plain, isNot(contains('data-rx-')));
      expect(plain, isNot(contains(r'_$dartxStyles')));
    });
  });

  group('reaching the page', () {
    test('only the components that rendered contribute their styles', () {
      final html = renderToDocument(const _StyledProps(), title: 't');
      expect(html, contains('<style>'));
      expect(html, contains('.styled[data-rx-test01]'));
      expect(html, isNot(contains('.unused')),
          reason: 'a component nobody rendered sends nothing');
    });

    test('a stylesheet is sent once however often the component appears', () {
      final html = renderToDocument(
          h('div', null, const [_StyledProps(), _StyledProps()]));
      expect('.styled'.allMatches(html).length, 1);
    });

    test('a page whose components have no styles gets no style element', () {
      expect(renderToDocument(h('p', null, 'plain')), isNot(contains('<style>')));
    });
  });
}

/// Stands in for what the builder generates, so the runtime half can be tested
/// without a build step.
final class _StyledProps extends ComponentProps {
  const _StyledProps();

  @override
  String get name => 'Styled';

  @override
  String? get styles => '.styled[data-rx-test01] { color: red; }';

  @override
  VNode build() => h('div', {'data-rx-test01': '', 'class': 'styled'}, 'hi');
}
