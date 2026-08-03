import 'package:reactx/reactx.dart';
import 'package:test/test.dart';

void main() {
  group('renderToString', () {
    test('renders nested elements', () {
      final html = renderToString(
        div({'class': 'card'}, [
          h1(null, 'Title'),
          p(null, 'Body'),
        ]),
      );
      expect(html, '<div class="card"><h1>Title</h1><p>Body</p></div>');
    });

    test('escapes text and attributes', () {
      final html = renderToString(
        div({'title': 'a "b" <c>'}, ['1 < 2 & 3']),
      );
      expect(html, '<div title="a &quot;b&quot; &lt;c&gt;">1 &lt; 2 &amp; 3</div>');
    });

    test('void elements self-close and skip children', () {
      expect(renderToString(el('br')), '<br>');
      expect(renderToString(img({'src': 'x.png'})), '<img src="x.png">');
    });

    test('boolean attrs and null values', () {
      expect(
        renderToString(input({'disabled': true, 'value': null, 'name': 'x'})),
        '<input disabled name="x">',
      );
      expect(renderToString(input({'disabled': false})), '<input>');
    });

    test('className / htmlFor map to class / for', () {
      expect(
        renderToString(label({'className': 'lbl', 'htmlFor': 'e'}, 'Name')),
        '<label class="lbl" for="e">Name</label>',
      );
    });

    test('style maps serialize to CSS with kebab-case', () {
      final html = renderToString(
        div({
          'style': {'backgroundColor': 'red', 'fontSize': '12px'},
        }),
      );
      expect(html, '<div style="background-color: red; font-size: 12px;"></div>');
    });

    test('event handlers are not serialized', () {
      final html = renderToString(button({'onClick': () {}}, 'Go'));
      expect(html, '<button>Go</button>');
    });

    test('runs function components with initial hook state', () {
      VNode greeting(Props props) {
        final (name, _) = useState('world');
        final greeting = useMemo(() => 'Hello, $name!', [name]);
        return p(null, greeting);
      }

      expect(renderToString(h(greeting)), '<p>Hello, world!</p>');
    });

    test('context provider value is read by consumers', () {
      final theme = createContext('light');

      VNode consumer(Props props) => span(null, useContext(theme));

      final tree = theme.provider(value: 'dark', children: [h(consumer)]);
      expect(renderToString(tree), '<span>dark</span>');
    });

    test('dangerouslySetInnerHTML injects raw html', () {
      final html = renderToString(
        div({
          'dangerouslySetInnerHTML': {'__html': '<b>raw</b>'},
        }),
      );
      expect(html, '<div><b>raw</b></div>');
    });

    test('renderToDocument wraps a full page', () {
      final doc = renderToDocument(
        h1(null, 'Hi'),
        title: 'T',
        bootstrapScript: 'main.dart.js',
      );
      expect(doc, contains('<!doctype html>'));
      expect(doc, contains('<title>T</title>'));
      expect(doc, contains('<div id="root"><h1>Hi</h1></div>'));
      expect(doc, contains('<script type="module" src="main.dart.js">'));
    });
  });
}
