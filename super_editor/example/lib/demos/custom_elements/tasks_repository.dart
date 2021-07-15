import 'dart:async';

import 'package:example/demos/custom_elements/task.dart';

/// A store for [Task]s.
///
/// In a real-world scenario, this would be a wrapper over an SQLite database
/// or maybe a Firestore database.
class TasksRepository {
  final _tasksById = <String, Task>{};
  final _individualTaskControllers = <String, StreamController<Task?>>{};
  final _allTasksController = StreamController<List<Task>>.broadcast();

  /// Saves the [task] and emits that in all of the subscribed Streams.
  Future<void> insert(Task task) async {
    _tasksById[task.id] = task;
    _individualTaskControllers[task.id]?.add(task);
    _allTasksController.add(_tasksById.values.toList());
  }

  /// Saves the [tasks] and emits them in all of the subscribed Streams.
  Future<void> insertAll(Iterable<Task> tasks) async {
    _tasksById.addAll(Map.fromEntries(tasks.map((e) => MapEntry(e.id, e))));
    _allTasksController.add(_tasksById.values.toList());

    for (final task in tasks) {
      _individualTaskControllers[task.id]?.add(task);
    }
  }

  /// Returns a [Stream] that will start by emitting the [Task]
  /// that matches the given [id].
  ///
  /// Whenever the [Task] with the given [id] changes, the [Stream]
  /// will emit a new value that reflects the [Task] in its current state.
  ///
  /// If the emitted value is `null`, it means that the [Task] was deleted.
  Stream<Task?> watchTaskById(String id) {
    _individualTaskControllers.putIfAbsent(id, () => StreamController<Task?>.broadcast());
    return _individualTaskControllers[id]!.stream.transform(_StartWithTransformer(_tasksById[id]));
  }

  /// Returns a [Stream] that will start by emitting a list of all [Task]s.
  ///
  /// Whenever a [Task] is inserted, updated or deleted, the [Stream]
  /// will emit a list of all [Task]s in their current state.
  Stream<List<Task>> watchAllTasks() =>
      _allTasksController.stream.transform(_StartWithTransformer<List<Task>>(_tasksById.values.toList()));

  /// Returns a [Task] that matches the given [id].
  Future<Task?> getTaskById(String id) async => _tasksById[id];

  /// Updates the task matching [Task.id] with the fields in [task] and
  /// emits the updated [Task] in all of the subscribed Streams.
  Future<void> updateTask(Task task) async {
    _tasksById[task.id] = task;
    _individualTaskControllers[task.id]?.add(task);
    _allTasksController.add(_tasksById.values.toList());
  }

  /// Removes the task matching [Task.id].
  ///
  /// Emits `null` in the individual Stream obtained by [watchTaskById],
  /// and the list of all [Task]s with [task] removed in the Stream obtained
  /// with [watchAllTasks].
  Future<void> deleteTask(Task task) async {
    _tasksById.remove(task.id);
    _individualTaskControllers[task.id]?.add(null);
    _allTasksController.add(_tasksById.values.toList());
  }
}

/// A [StreamTransformer] that makes the [Stream] emit [initialValue] when
/// the [Stream] is listened to.
///
/// Only needed for the in-memory implementation of [TasksRepository] - libraries
/// like moor (for SQLite) and Firestore do something similar out of the box.
class _StartWithTransformer<T> extends StreamTransformerBase<T, T> {
  _StartWithTransformer(this.initialValue);
  final T initialValue;

  @override
  Stream<T> bind(Stream<T> stream) {
    return StreamTransformer<T, T>((input, cancelOnError) {
      late final StreamController<T> controller;
      late final StreamSubscription<T> subscription;

      controller = StreamController<T>(
        sync: true,
        onListen: () {
          controller.add(initialValue);
          subscription = input.listen(
            controller.add,
            onDone: () => controller.close(),
          );
        },
        onPause: ([resumeSignal]) => subscription.pause(resumeSignal),
        onResume: () => subscription.resume(),
        onCancel: () => subscription.cancel(),
      );

      return controller.stream.listen(null);
    }).bind(stream);
  }
}
