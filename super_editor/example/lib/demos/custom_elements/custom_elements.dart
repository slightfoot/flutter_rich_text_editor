import 'package:example/demos/custom_elements/task.dart';
import 'package:example/demos/custom_elements/task_item.dart';
import 'package:example/demos/custom_elements/task_syntax.dart';
import 'package:example/demos/custom_elements/tasks_repository.dart';
import 'package:flutter/material.dart';
import 'package:super_editor/super_editor.dart';

/// The Markdown that will be parsed into [DocumentNode]s representing
/// the initial document.
const _initialDocument = '''
# Custom elements demo

Let's imagine we're building _a task management app_ that allows embedding tasks inside rich text content.

Our app could store the tasks in an SQLite database. The tasks can be embedded as a part of the rich text document, but 
at the same time, they can also be edited in some other page in our app.

When editing a given task in the rich text editor, the changes should propagate to elsewhere in our app, and vice versa.

This is an example of just that.

<@ task:aaa111 @>
<@ task:bbb222 @>
<@ task:ccc333 @>

The tasks in the document are referenced by their id using a custom Markdown syntax.

---

More **rich text content** here.
''';

/// The in-memory implementation of a store that holds Task objects.
///
/// All of the inserted tasks are referenced by their id's in the
/// Markdown with a special syntax and will eventually have their
/// own [DocumentNode] representing them in the [Document].
final _tasksRepository = TasksRepository()
  ..insertAll(
    const [
      Task(id: 'aaa111', checked: false, text: 'First task.'),
      Task(id: 'bbb222', checked: true, text: 'Second task.'),
      Task(id: 'ccc333', checked: false, text: 'Third task.'),
    ],
  );

/// Showcases how to embed custom components in the editor.
///
/// In this case, we have [Task] objects in a [TasksRepository]. We need
/// a way to reference [Task]s with a custom Markdown syntax and keep them
/// in sync in the [TasksRepository] every time there are changes.
///
/// Any change in the [TasksRepository] should also be immediately reflected
/// in the editor.
///
/// Since a [Task] can be created outside of the editor, we use a custom Markdown
/// syntax to embed an existing [Task] object by looking it up by its id.
class CustomElementsExampleEditor extends StatefulWidget {
  const CustomElementsExampleEditor();

  @override
  _CustomElementsExampleEditorState createState() => _CustomElementsExampleEditorState();
}

class _CustomElementsExampleEditorState extends State<CustomElementsExampleEditor> {
  late final Document _doc;
  late final DocumentEditor _docEditor;
  late final DocumentComposer _composer;

  @override
  void initState() {
    super.initState();
    _doc = deserializeMarkdownToDocument(
      _initialDocument,
      customBlockSyntaxes: [const TaskSyntax()],
      customMarkdownToDocumentVisitor: taskMarkdownToDocumentVisitor(_tasksRepository),
    );

    _docEditor = DocumentEditor(document: _doc as MutableDocument);
    _composer = DocumentComposer();
  }

  @override
  void dispose() {
    _composer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: SuperEditor.custom(
            editor: _docEditor,
            composer: _composer,
            maxWidth: 600, // arbitrary choice for maximum width
            padding: const EdgeInsets.symmetric(vertical: 56, horizontal: 24),
            componentBuilders: [
              taskItemBuilder,
              ...defaultComponentBuilders,
            ],
          ),
        ),
        const Expanded(child: _TasksList()),
      ],
    );
  }
}

class _TasksList extends StatelessWidget {
  const _TasksList({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      height: double.infinity,
      color: Colors.blue,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('This simulates another page in the app/updating tasks from the background.'),
            const SizedBox(height: 8),
            const Text('See how the tasks stay in sync when making changes to them.'),
            const SizedBox(height: 32),
            Expanded(
              child: StreamBuilder<List<Task>>(
                initialData: const [],
                stream: _tasksRepository.watchAllTasks(),
                builder: (context, snapshot) {
                  final tasks = snapshot.data!;

                  if (tasks.isEmpty) {
                    return const Center(
                      child: Text('No tasks here!'),
                    );
                  }

                  return ListView.builder(
                    padding: const EdgeInsets.only(bottom: 92),
                    itemCount: tasks.length,
                    itemBuilder: (context, index) => _TaskListTile(task: tasks[index]),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TaskListTile extends StatefulWidget {
  const _TaskListTile({required this.task});
  final Task task;

  @override
  _TaskListTileState createState() => _TaskListTileState();
}

class _TaskListTileState extends State<_TaskListTile> {
  late final TextEditingController _controller;
  String? _lastTextValue;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.task.text);
    _lastTextValue = widget.task.text;
  }

  @override
  void didUpdateWidget(covariant _TaskListTile oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.task.text != widget.task.text && widget.task.text != _lastTextValue) {
      _controller.text = widget.task.text;
      _lastTextValue = widget.task.text;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onTextChanged(String value) {
    _lastTextValue = value;
    _tasksRepository.updateTask(widget.task.copyWith(text: value));
  }

  void _onCheckedStateChanged(bool? value) {
    _tasksRepository.updateTask(widget.task.copyWith(checked: value));
  }

  void _deleteTask() {
    _tasksRepository.deleteTask(widget.task);
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      key: ValueKey(widget.task.id),
      title: TextField(
        controller: _controller,
        onChanged: _onTextChanged,
      ),
      leading: Checkbox(
        value: widget.task.checked,
        onChanged: _onCheckedStateChanged,
      ),
      trailing: IconButton(
        onPressed: _deleteTask,
        icon: const Icon(Icons.delete),
      ),
    );
  }
}
