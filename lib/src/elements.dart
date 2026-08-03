/// Ergonomic builders for common HTML elements.
///
/// Each helper takes `(propsOrChildren, [children])`, so both of these work:
///
/// ```dart
/// div({'class': 'card'}, [h1(null, 'Title'), p(null, 'Body')])
/// div('just text')
/// ```
///
/// They are thin wrappers over [h]; anything you can express with `h` you can
/// express here.
library;

import 'vdom.dart';

VNode _el(String tag, Object? a, Object? b) {
  // Two calling conventions:
  //   el(props, children)  -> first arg is a Map (or null for "no props")
  //   el(children)         -> first arg is the children directly
  if (a == null || a is Map) return h(tag, a, b);
  return h(tag, null, a);
}

/// Generic element builder for tags without a dedicated helper.
VNode el(String tag, [Object? a, Object? b]) => _el(tag, a, b);

// Document structure
VNode div([Object? a, Object? b]) => _el('div', a, b);
VNode span([Object? a, Object? b]) => _el('span', a, b);
VNode section([Object? a, Object? b]) => _el('section', a, b);
VNode article([Object? a, Object? b]) => _el('article', a, b);
VNode header([Object? a, Object? b]) => _el('header', a, b);
VNode footer([Object? a, Object? b]) => _el('footer', a, b);
VNode nav([Object? a, Object? b]) => _el('nav', a, b);
VNode main_([Object? a, Object? b]) => _el('main', a, b);
VNode aside([Object? a, Object? b]) => _el('aside', a, b);

// Headings & text
VNode h1([Object? a, Object? b]) => _el('h1', a, b);
VNode h2([Object? a, Object? b]) => _el('h2', a, b);
VNode h3([Object? a, Object? b]) => _el('h3', a, b);
VNode h4([Object? a, Object? b]) => _el('h4', a, b);
VNode h5([Object? a, Object? b]) => _el('h5', a, b);
VNode h6([Object? a, Object? b]) => _el('h6', a, b);
VNode p([Object? a, Object? b]) => _el('p', a, b);
VNode small([Object? a, Object? b]) => _el('small', a, b);
VNode strong([Object? a, Object? b]) => _el('strong', a, b);
VNode em([Object? a, Object? b]) => _el('em', a, b);
VNode code([Object? a, Object? b]) => _el('code', a, b);
VNode pre([Object? a, Object? b]) => _el('pre', a, b);
VNode label([Object? a, Object? b]) => _el('label', a, b);

// Lists
VNode ul([Object? a, Object? b]) => _el('ul', a, b);
VNode ol([Object? a, Object? b]) => _el('ol', a, b);
VNode li([Object? a, Object? b]) => _el('li', a, b);

// Interactive
VNode a([Object? props, Object? children]) => _el('a', props, children);
VNode button([Object? a, Object? b]) => _el('button', a, b);
VNode input([Object? a, Object? b]) => _el('input', a, b);
VNode textarea([Object? a, Object? b]) => _el('textarea', a, b);
VNode select([Object? a, Object? b]) => _el('select', a, b);
VNode option([Object? a, Object? b]) => _el('option', a, b);
VNode form([Object? a, Object? b]) => _el('form', a, b);

// Media & misc
VNode img([Object? a, Object? b]) => _el('img', a, b);
VNode br([Object? a, Object? b]) => _el('br', a, b);
VNode hr([Object? a, Object? b]) => _el('hr', a, b);

// Tables
VNode table([Object? a, Object? b]) => _el('table', a, b);
VNode thead([Object? a, Object? b]) => _el('thead', a, b);
VNode tbody([Object? a, Object? b]) => _el('tbody', a, b);
VNode tr([Object? a, Object? b]) => _el('tr', a, b);
VNode th([Object? a, Object? b]) => _el('th', a, b);
VNode td([Object? a, Object? b]) => _el('td', a, b);
