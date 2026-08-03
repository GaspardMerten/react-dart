import 'package:reactx/reactx.dart';
import 'package:test/test.dart';

void main() {
  group('jsx', () {
    test('parses a plain element', () {
      expect(renderToString(jsx(r'<div class="a">hi</div>')),
          '<div class="a">hi</div>');
    });

    test('interpolates text slots', () {
      final node = jsx(r'<h1>Hello ${0}!</h1>', ['world']);
      expect(renderToString(node), '<h1>Hello world!</h1>');
    });

    test('interpolates child vnodes and lists', () {
      final node = jsx(r'<ul>${0}</ul>', [
        [li(null, 'a'), li(null, 'b')],
      ]);
      expect(renderToString(node), '<ul><li>a</li><li>b</li></ul>');
    });

    test('passes unquoted attribute slots through unchanged', () {
      var clicked = false;
      final node = jsx(r'<button onClick=${0}>go</button>', [() => clicked = true]);
      final e = node as ElementNode;
      (e.props['onClick'] as void Function())();
      expect(clicked, isTrue);
    });

    test('single quoted slot preserves value type', () {
      final node = jsx(r'<div style="${0}"></div>', [
        {'color': 'red'},
      ]) as ElementNode;
      expect(node.props['style'], {'color': 'red'});
      expect(renderToString(node), '<div style="color: red;"></div>');
    });

    test('concatenates mixed attribute text and slots', () {
      final node =
          jsx(r'<div class="btn ${0}">x</div>', ['primary']) as ElementNode;
      expect(node.props['class'], 'btn primary');
    });

    test('boolean attributes', () {
      final node = jsx(r'<input disabled />') as ElementNode;
      expect(node.props['disabled'], true);
    });

    test('self-closing and nested elements', () {
      expect(renderToString(jsx(r'<div><br/><span>x</span></div>')),
          '<div><br><span>x</span></div>');
    });

    test('fragments', () {
      expect(renderToString(jsx(r'<><span>a</span><span>b</span></>')),
          '<span>a</span><span>b</span>');
    });

    test('component slot in tag position', () {
      VNode card(Props props) =>
          div({'class': 'card'}, [h1(null, props['title']), props['children']]);

      final node = jsx(
        r'<${0} title="Hi">body</${0}>',
        [card],
      );
      expect(renderToString(node), '<div class="card"><h1>Hi</h1>body</div>');
    });

    test('strips structural whitespace but keeps inline spacing', () {
      final node = jsx(r'''
        <p>
          Hello ${0}
        </p>
      ''', ['there']);
      expect(renderToString(node), '<p>Hello there</p>');
    });

    test('comments are ignored', () {
      expect(renderToString(jsx(r'<div><!-- hi -->x</div>')), '<div>x</div>');
    });

    test('caches compiled templates by identity', () {
      const t = r'<div>${0}</div>';
      final a = jsx(t, ['1']);
      final b = jsx(t, ['2']);
      expect(renderToString(a), '<div>1</div>');
      expect(renderToString(b), '<div>2</div>');
    });
  });
}
