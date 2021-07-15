import 'dart:async';

import 'package:example/demos/custom_elements/task.dart';
import 'package:flutter/material.dart';
import 'package:super_editor/super_editor.dart';

/// A [DocumentNode] representing a [Task] in a [Document].
///
/// This [DocumentNode] is set up to update its state and notify
/// its listeners each time the [taskUpdates] stream emits a [Task].
class TaskItemNode extends TextNode {
  TaskItemNode({
    required String id,
    required Stream<Task?> taskUpdates,
    required ValueSetter<Task> updateTask,
    Map<String, dynamic>? metadata,
  })  : _updateTask = updateTask,
        super(
          id: id,

          // Since we can't set up a StreamSubscription yet, which
          // means we can't know what the text is going to be, we'll
          // start with an empty text.
          text: AttributedText(),
          metadata: metadata,
        ) {
    _subscription = taskUpdates.listen((task) {
      if (_task != null && task == null) {
        _deleted = true;
      }

      if (_task != task) {
        // If the task changed, update the internal state and notify listeners
        // about the change.
        _task = task;
        notifyListeners();
      }
    });
  }

  final ValueSetter<Task> _updateTask;
  late StreamSubscription<Task?> _subscription;

  Task? _task;

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }

  bool get deleted => _deleted;
  bool _deleted = false;

  @override
  AttributedText get text => AttributedText(text: _task?.text ?? '');

  @override
  set text(AttributedText value) {
    final task = _task;
    if (task != null && task.text != value.text) {
      _updateTask(task.copyWith(text: value.text));
    }
  }

  bool get checked => _task?.checked ?? false;
  set checked(bool value) {
    final task = _task;
    if (task != null && task.checked != value) {
      _updateTask(task.copyWith(checked: value));
    }
  }

  @override
  bool hasEquivalentContent(Object other) => other is TaskItemNode && id == other.id;
}

/// The widget that renders a [Task].
class TaskItemComponent extends StatelessWidget {
  const TaskItemComponent({
    Key? key,
    required this.textKey,
    required this.checked,
    required this.deleted,
    required this.text,
    required this.styleBuilder,
    this.textSelection,
    this.selectionColor = Colors.lightBlueAccent,
    this.showCaret = false,
    this.caretColor = Colors.black,
    this.showDebugPaint = false,
    required this.onChanged,
  }) : super(key: key);

  final GlobalKey textKey;
  final bool checked;
  final bool deleted;
  final AttributedText text;
  final AttributionStyleBuilder styleBuilder;
  final TextSelection? textSelection;
  final Color selectionColor;
  final bool showCaret;
  final Color caretColor;
  final bool showDebugPaint;
  final ValueChanged<bool> onChanged;

  void _handleValueChanged(bool? value) {
    if (value != null) {
      onChanged(value);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Checkbox(
          value: checked,
          onChanged: deleted ? null : _handleValueChanged,
        ),
        const SizedBox(width: 4),
        Expanded(
          child: deleted
              ? const Text(
                  '(deleted)',
                  style: TextStyle(color: Colors.black26),
                )
              : TextComponent(
                  key: textKey,
                  text: text,
                  textStyleBuilder: styleBuilder,
                  textSelection: textSelection,
                  selectionColor: selectionColor,
                  showCaret: showCaret,
                  caretColor: caretColor,
                  showDebugPaint: showDebugPaint,
                ),
        ),
      ],
    );
  }
}

/// Creates [TaskItemComponent]s from [TaskItemNode]s.
Widget? taskItemBuilder(ComponentContext componentContext) {
  final node = componentContext.documentNode;
  if (node is! TaskItemNode) {
    return null;
  }

  final textSelection = componentContext.nodeSelection?.nodeSelection as TextSelection?;
  final showCaret = componentContext.showCaret && (componentContext.nodeSelection?.isExtent ?? false);

  return TaskItemComponent(
    textKey: componentContext.componentKey,
    checked: node.checked,
    deleted: node.deleted,
    text: node.text,
    styleBuilder: componentContext.extensions[textStylesExtensionKey],
    onChanged: (value) => node.checked = value,
    textSelection: textSelection,
    selectionColor: (componentContext.extensions[selectionStylesExtensionKey] as SelectionStyle).selectionColor,
    showCaret: showCaret,
    caretColor: (componentContext.extensions[selectionStylesExtensionKey] as SelectionStyle).textCaretColor,
  );
}
