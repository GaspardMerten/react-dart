import 'package:reactx/reactx.dart';
import 'package:test/test.dart';

void main() {
  group('h / normalizeChildren', () {
    test('creates an element node with props and children', () {
      final node = h('div', {'class': 'x'}, ['hello']);
      expect(node, isA<ElementNode>());
      final e = node as ElementNode;
      expect(e.tag, 'div');
      expect(e.props['class'], 'x');
      expect(e.children.single, isA<TextNode>());
      expect((e.children.single as TextNode).text, 'hello');
    });

    test('lifts key out of props', () {
      final node = h('li', {'key': 7, 'class': 'row'}) as ElementNode;
      expect(node.key, 7);
      expect(node.props.containsKey('key'), isFalse);
    });

    test('normalizes mixed / nested / falsy children', () {
      final kids = normalizeChildren([
        'a',
        null,
        false,
        1,
        ['b', h('span')],
        true,
      ]);
      expect(kids.map((c) => c.runtimeType.toString()).toList(), [
        'TextNode',
        'TextNode',
        'TextNode',
        'ElementNode',
      ]);
      expect((kids[0] as TextNode).text, 'a');
      expect((kids[1] as TextNode).text, '1');
      expect((kids[2] as TextNode).text, 'b');
    });

    test('element helpers accept props-or-children in first position', () {
      expect((div('hi') as ElementNode).children.single, isA<TextNode>());
      final withProps = div({'id': 'a'}, ['hi']) as ElementNode;
      expect(withProps.props['id'], 'a');
      expect(withProps.children.length, 1);
    });

    test('component nodes carry the function and props', () {
      VNode comp(Props p) => div(null, p['label']);
      final node = h(comp, {'label': 'X'}) as ComponentNode;
      expect(node.component, comp);
      expect(node.props['label'], 'X');
    });
  });
}
