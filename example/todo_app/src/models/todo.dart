/// The domain: what a todo *is*, independent of how it is rendered.
///
/// Nothing here imports reactx. Keeping the model free of the framework is
/// what lets [todoReducer] be unit-tested on the VM with no host, no DOM and
/// no component tree — see `test/todo_app_test.dart`.
library;

/// Which todos the list shows.
enum Filter {
  all('All'),
  active('Active'),
  done('Done');

  const Filter(this.label);

  /// Text on the filter chip.
  final String label;

  bool matches(Todo todo) => switch (this) {
        Filter.all => true,
        Filter.active => !todo.done,
        Filter.done => todo.done,
      };
}

/// A single todo. Immutable — updates produce a new value, which is what makes
/// the reducer easy to reason about and the reconciler's diffing meaningful.
class Todo {
  const Todo({
    required this.id,
    required this.title,
    required this.tag,
    this.done = false,
  });

  final int id;
  final String title;
  final String tag;
  final bool done;

  Todo copyWith({String? title, String? tag, bool? done}) => Todo(
        id: id,
        title: title ?? this.title,
        tag: tag ?? this.tag,
        done: done ?? this.done,
      );
}

/// The tags a todo can carry. Small and fixed, so the form is a `<select>`.
const tags = <String>['home', 'work', 'learn'];

/// What the app starts with.
///
/// The server renders this list and the client hydrates it, so both sides must
/// agree exactly — hence a constant rather than anything generated at startup.
const seedTodos = <Todo>[
  Todo(id: 1, title: 'Read the reactx README', tag: 'learn', done: true),
  Todo(id: 2, title: 'Write a page in dartx', tag: 'learn'),
  Todo(id: 3, title: 'Ship the todo example', tag: 'work'),
  Todo(id: 4, title: 'Water the plants', tag: 'home'),
];

/// The id the next added todo gets. Kept in step with [seedTodos] by hand
/// because `seedTodos.length` is not a constant expression.
const seedNextId = 5;
