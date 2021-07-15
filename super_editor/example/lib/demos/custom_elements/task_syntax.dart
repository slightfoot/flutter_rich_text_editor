import 'package:example/demos/custom_elements/task_item.dart';
import 'package:example/demos/custom_elements/tasks_repository.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:super_editor/super_editor.dart';

/// Matches `<@ task:abc123 @>` (with optional leading whitespace) where
/// "abc123" will be captured as a group.
final _taskPattern = RegExp(r'^ {0,}<@\s*task:(.*?)\s*@>$');

/// A Markdown syntax that parses custom task tags.
///
/// The syntax looks like this:
///
/// ```
/// <@ task:abc123 @>
/// ```
///
/// where "abc123" will be the unique identifier of the task which will
/// then be added under the key `id` in the `attributes` map of the
/// returned [md.Element].
class TaskSyntax extends md.BlockSyntax {
  @override
  RegExp get pattern => _taskPattern;

  const TaskSyntax();

  @override
  md.Node parse(md.BlockParser parser) {
    final match = pattern.firstMatch(parser.current)!;
    final taskId = match[1]!.trim();
    parser.advance();

    return md.Element.withTag('task')..attributes['id'] = taskId;
  }
}

/// A custom Markdown element visitor that creates [TaskItemNode]s
/// from matching Markdown elements.
///
/// Each [TaskItemNode] will automatically update itself when the
/// underlying [Task] in the [TasksRepository] changes.
CustomMarkdownToDocumentVisitor taskMarkdownToDocumentVisitor(TasksRepository repository) {
  return (md.Element element) {
    if (element.tag == 'task') {
      final taskId = element.attributes['id']!;
      return TaskItemNode(
        id: taskId,
        taskUpdates: repository.watchTaskById(taskId),
        updateTask: repository.updateTask,
      );
    }

    return null;
  };
}
