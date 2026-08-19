/// The "backend": what a route loader talks to.
///
/// A real app would reach a database here on the server and an HTTP endpoint in
/// the browser. This one keeps the seed list and adds a small delay, which is
/// enough to make the interesting parts real: the delay is why a navigation has
/// a loading state, and why the server handing its results to the client is
/// worth doing at all.
///
/// Nothing here imports reactx. Loaders are plain async functions over your own
/// data layer — that is the whole contract.
library;

import '../models/todo.dart';

/// Stands in for network latency, so `useNavigation()` has something to report.
const _latency = Duration(milliseconds: 120);

/// Thrown when a URL names a todo that does not exist.
///
/// A distinct type rather than a null, because the difference between "no such
/// todo" and "the load failed" is the difference between a 404 and a 500, and
/// the error boundary wants to say something different for each.
class TodoNotFound implements Exception {
  const TodoNotFound(this.id);
  final int id;

  @override
  String toString() => 'No todo with id $id';
}

/// Every todo, as the list page wants them.
Future<List<Todo>> fetchTodos() async {
  await Future<void>.delayed(_latency);
  return seedTodos;
}

/// One todo by id, or [TodoNotFound].
Future<Todo> fetchTodo(String rawId) async {
  await Future<void>.delayed(_latency);
  final id = int.tryParse(rawId);
  for (final todo in seedTodos) {
    if (todo.id == id) return todo;
  }
  throw TodoNotFound(id ?? -1);
}

/// JSON for a todo, so the server's fetch can travel to the browser instead of
/// being repeated there.
Map<String, Object?> encodeTodo(Todo todo) => {
      'id': todo.id,
      'title': todo.title,
      'tag': todo.tag,
      'done': todo.done,
    };

Todo decodeTodo(Map<String, Object?> json) => Todo(
      id: json['id']! as int,
      title: json['title']! as String,
      tag: json['tag']! as String,
      done: json['done']! as bool,
    );
