/// The store: one reducer and one declaration.
///
/// Every page reads [todoStore], so the header badge on `/`, the numbers on
/// `/stats` and the list itself are three views of a single value. Nothing is
/// threaded through props and nothing wraps the tree — components that need
/// the whole state call `useStore(todoStore)`, components that need one number
/// call `useSelect`, and components that only write call `useDispatch`.
library;

import 'package:reactx/reactx.dart';

import '../models/todo.dart';

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------

sealed class TodoAction {
  const TodoAction();
}

class AddTodo extends TodoAction {
  const AddTodo(this.title, this.tag);

  final String title;
  final String tag;
}

class ToggleTodo extends TodoAction {
  const ToggleTodo(this.id);

  final int id;
}

class RemoveTodo extends TodoAction {
  const RemoveTodo(this.id);

  final int id;
}

class ClearDone extends TodoAction {
  const ClearDone();
}

class SetFilter extends TodoAction {
  const SetFilter(this.filter);

  final Filter filter;
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

/// Everything the app knows, as one immutable value.
///
/// Derived numbers ([remaining], [byTag], …) are getters rather than stored
/// fields: there is exactly one source of truth, so the two pages can never
/// disagree about how many todos are left.
class TodoState {
  const TodoState({
    required this.todos,
    required this.nextId,
    this.filter = Filter.all,
  });

  static const initial =
      TodoState(todos: seedTodos, nextId: seedNextId);

  final List<Todo> todos;
  final Filter filter;
  final int nextId;

  TodoState copyWith({List<Todo>? todos, Filter? filter, int? nextId}) =>
      TodoState(
        todos: todos ?? this.todos,
        filter: filter ?? this.filter,
        nextId: nextId ?? this.nextId,
      );

  /// The todos the current [filter] lets through.
  List<Todo> get visible => todos.where(filter.matches).toList();

  int get remaining => todos.where((t) => !t.done).length;

  int get completed => todos.length - remaining;

  /// Percentage complete, rounded — 0 when there is nothing to do.
  int get percentDone =>
      todos.isEmpty ? 0 : (completed * 100 / todos.length).round();

  /// Done/total per tag, in the order [tags] declares, skipping unused tags.
  Map<String, ({int done, int total})> get byTag {
    final out = <String, ({int done, int total})>{};
    for (final tag in tags) {
      final of = todos.where((t) => t.tag == tag);
      if (of.isEmpty) continue;
      out[tag] = (done: of.where((t) => t.done).length, total: of.length);
    }
    return out;
  }
}

/// The whole app's behaviour, as a pure function. No DOM, no hooks, no async.
TodoState todoReducer(TodoState state, TodoAction action) => switch (action) {
      AddTodo(:final title, :final tag) => state.copyWith(
          todos: [
            ...state.todos,
            Todo(id: state.nextId, title: title, tag: tag),
          ],
          nextId: state.nextId + 1,
        ),
      ToggleTodo(:final id) => state.copyWith(
          todos: [
            for (final t in state.todos)
              if (t.id == id) t.copyWith(done: !t.done) else t,
          ],
        ),
      RemoveTodo(:final id) => state.copyWith(
          todos: [
            for (final t in state.todos)
              if (t.id != id) t,
          ],
        ),
      ClearDone() => state.copyWith(
          todos: [
            for (final t in state.todos)
              if (!t.done) t,
          ],
        ),
      SetFilter(:final filter) => state.copyWith(filter: filter),
    };

// ---------------------------------------------------------------------------
// Wiring
// ---------------------------------------------------------------------------

/// The store. Declared once; the object itself is the identity, so there is no
/// name to mistype and no provider to wrap the tree in.
///
/// Its state lives on whatever is rendering — the client `Root`, or the server
/// renderer for one request — which is why two requests handled at the same
/// time cannot see each other's todos.
final todoStore = defineStore(
  TodoState.initial,
  todoReducer,
  debugLabel: 'todos',
);
