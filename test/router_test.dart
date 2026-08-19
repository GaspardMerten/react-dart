/// Tests for `package:reactx/router.dart`.
///
/// The history API is a no-op on the VM, so what is covered here is everything
/// *except* the address bar: matching, the provided value, `Link`'s markup, and
/// the fact that a click swaps the page. The browser half is exercised in
/// `test/todo_app_browser_test.dart`.
library;

import 'package:reactx/reactx.dart';
import 'package:reactx/router.dart';
import 'package:reactx/testing.dart';
import 'package:test/test.dart';

VNode page(Props props) => h('h1', null, useRoutePath());

VNode shell(Props props) => RouterScopeProps(
      path: props['path'] as String?,
      children: [
        h('nav', null, [
          const LinkProps(
              href: '/',
              className: 'nav',
              activeClass: 'on',
              children: [TextNode('Home')]),
          const LinkProps(
              href: '/stats',
              className: 'nav',
              activeClass: 'on',
              children: [TextNode('Stats')]),
        ]),
        use(page),
      ],
    );

void main() {
  group('normalizePath', () {
    test('strips the query, the fragment and trailing slashes', () {
      expect(normalizePath('/stats'), '/stats');
      expect(normalizePath('/stats/'), '/stats');
      expect(normalizePath('/stats?from=nav'), '/stats');
      expect(normalizePath('/stats#top'), '/stats');
      expect(normalizePath('stats'), '/stats');
      expect(normalizePath('/'), '/');
      expect(normalizePath(''), '/');
    });
  });

  group('matchPath', () {
    test('captures named segments', () {
      expect(matchPath('/todo/:id', '/todo/42'), {'id': '42'});
      expect(matchPath('/t/:a/:b', '/t/x/y'), {'a': 'x', 'b': 'y'});
    });

    test('a static pattern matches only itself', () {
      expect(matchPath('/stats', '/stats'), isEmpty);
      expect(matchPath('/stats', '/stats/extra'), isNull);
      expect(matchPath('/stats', '/other'), isNull);
    });

    test('length must line up', () {
      expect(matchPath('/todo/:id', '/todo'), isNull);
      expect(matchPath('/todo/:id', '/todo/1/2'), isNull);
      expect(matchPath('/todo/:id', '/todo/'), isNull);
    });

    test('parameters are URL-decoded', () {
      expect(matchPath('/tag/:name', '/tag/two%20words'), {'name': 'two words'});
    });

    test('a trailing * captures the rest', () {
      expect(matchPath('/docs/*', '/docs/a/b'), {'rest': 'a/b'});
      expect(matchPath('/docs/*', '/docs'), {'rest': ''});
    });

    test('normalization applies to both sides', () {
      expect(matchPath('/todo/:id/', '/todo/7?x=1'), {'id': '7'});
    });
  });

  group('RouterScope', () {
    test('renders the path it was seeded with', () {
      expect(mountApp(use(shell, {'path': '/stats'})).tree.byTag('h1').textContent,
          '/stats');
      expect(mountApp(use(shell, {'path': '/stats/?a=1'})).tree.byTag('h1')
          .textContent, '/stats');
    });

    test('falls back to "/" when given nothing', () {
      expect(mountApp(shell).tree.byTag('h1').textContent, '/');
    });
  });

  group('Link', () {
    test('renders a real anchor with the normalized href', () {
      final app = mountApp(use(shell, {'path': '/'}));
      final home = app.tree.allByTag('a').first;
      expect(home.tag, 'a');
      expect(home.attributes['href'], '/');
      expect(home.textContent, 'Home');
    });

    test('marks the current link for CSS and assistive tech', () {
      final app = mountApp(use(shell, {'path': '/stats'}));
      final [home, stats] = app.tree.allByTag('a');

      expect(stats.attributes['class'], 'nav on');
      expect(stats.attributes['aria-current'], 'page');
      expect(home.attributes['class'], 'nav');
      expect(home.attributes.containsKey('aria-current'), isFalse);
    });

    test('clicking navigates without reloading', () {
      final app = mountApp(use(shell, {'path': '/'}));
      app.act(() => app.tree.allByTag('a')[1].click());

      expect(app.tree.byTag('h1').textContent, '/stats');
      expect(app.tree.allByTag('a')[1].attributes['class'], 'nav on');
    });

    test('`attributes` passes anything else through to the anchor', () {
      // The escape hatch is explicit now: a link's own arguments are declared,
      // and everything else goes in one map you can see.
      const one = RouterScopeProps(path: '/', children: [
        LinkProps(
          href: '/x',
          attributes: {'title': 'go', 'data-test': '1'},
          children: [TextNode('x')],
        ),
      ]);

      final a = mountApp(one).tree.byTag('a');
      expect(a.attributes['title'], 'go');
      expect(a.attributes['data-test'], '1');
    });

    test('exact: false also matches paths below href', () {
      const section = RouterScopeProps(path: '/docs/intro', children: [
        LinkProps(
            href: '/docs',
            activeClass: 'on',
            exact: false,
            children: [TextNode('Docs')]),
        LinkProps(
            href: '/docs', activeClass: 'on', children: [TextNode('Exact')]),
      ]);

      final [loose, strict] = mountApp(section).tree.allByTag('a');
      expect(loose.attributes['class'], 'on');
      expect(strict.attributes.containsKey('class'), isFalse);
    });
  });

  group('useParams', () {
    test('reads the parameters of the current path', () {
      VNode detail(Props props) =>
          h('p', null, '${useParams('/todo/:id')?['id']}');

      final app = mountApp(RouterScopeProps(path: '/todo/9', children: [use(detail)]));
      expect(app.tree.byTag('p').textContent, '9');
    });

    test('is null when the pattern does not match', () {
      VNode detail(Props props) =>
          h('p', null, useParams('/todo/:id') == null ? 'no' : 'yes');

      final app = mountApp(RouterScopeProps(path: '/about', children: [use(detail)]));
      expect(app.tree.byTag('p').textContent, 'no');
    });
  });
}
