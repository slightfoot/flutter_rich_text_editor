import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:super_editor/src/core/document.dart';
import 'package:super_editor/src/core/edit_context.dart';
import 'package:super_editor/src/default_editor/attributions.dart';
import 'package:super_editor/src/infrastructure/_logging.dart';
import 'package:super_editor/src/infrastructure/keyboard.dart';
import 'package:super_editor/super_editor.dart';

import 'document_interaction.dart';
import 'multi_node_editing.dart';
import 'paragraph.dart';
import 'text.dart';

final _log = Logger(scope: 'document_keyboard_actions.dart');

ExecutionInstruction doNothingWhenThereIsNoSelection({
  required EditContext editContext,
  required RawKeyEvent keyEvent,
}) {
  if (editContext.composer.selection == null) {
    _log.log('doNothingWhenThereIsNoSelection', ' - no selection. Returning.');
    return ExecutionInstruction.haltExecution;
  } else {
    return ExecutionInstruction.continueExecution;
  }
}

ExecutionInstruction collapseSelectionWhenDirectionalKeyIsPressed({
  required EditContext editContext,
  required RawKeyEvent keyEvent,
}) {
  if (keyEvent.isShiftPressed) {
    return ExecutionInstruction.continueExecution;
  }
  if (keyEvent.isMetaPressed || keyEvent.isControlPressed) {
    return ExecutionInstruction.continueExecution;
  }
  if (editContext.composer.selection == null || editContext.composer.selection!.isCollapsed) {
    return ExecutionInstruction.continueExecution;
  }

  final isDirectionalKey = keyEvent.logicalKey == LogicalKeyboardKey.arrowLeft ||
      keyEvent.logicalKey == LogicalKeyboardKey.arrowRight ||
      keyEvent.logicalKey == LogicalKeyboardKey.arrowUp ||
      keyEvent.logicalKey == LogicalKeyboardKey.arrowDown;
  if (!isDirectionalKey) {
    return ExecutionInstruction.continueExecution;
  }

  _log.log('collapseSelectionWhenDirectionalKeyIsPressed', 'Collapsing editor selection, then returning.');
  editContext.composer.selection = editContext.composer.selection!.collapse();

  return ExecutionInstruction.haltExecution;
}

ExecutionInstruction pasteWhenCmdVIsPressed({
  required EditContext editContext,
  required RawKeyEvent keyEvent,
}) {
  if (!keyEvent.isPrimaryShortcutKeyPressed || keyEvent.character?.toLowerCase() != 'v') {
    return ExecutionInstruction.continueExecution;
  }
  if (editContext.composer.selection == null) {
    return ExecutionInstruction.continueExecution;
  }

  if (kIsWeb) {
    // On web the standard Flutter clipboard behavior requires special
    // browser permissions. We don't want the user to have to grant permissions.
    //
    // Browsers include a built-in paste event system that doesn't require
    // permissions. Therefore, on web we swallow this event and do nothing
    // in this handler, but the editor includes behavior elsewhere to apply
    // the pasted content. Look for the PasteEventHandler.
    return ExecutionInstruction.haltExecution;
  }

  _log.log('pasteWhenCmdVIsPressed', 'Pasting clipboard content...');
  DocumentPosition pastePosition = editContext.composer.selection!.extent;

  // Delete all currently selected content.
  if (!editContext.composer.selection!.isCollapsed) {
    pastePosition = getDocumentPositionAfterDeletion(
      document: editContext.editor.document,
      selection: editContext.composer.selection!,
    );

    // Delete the selected content.
    editContext.editor.executeCommand(
      DeleteSelectionCommand(documentSelection: editContext.composer.selection!),
    );

    editContext.composer.selection = DocumentSelection.collapsed(position: pastePosition);
  }

  // TODO: figure out a general approach for asynchronous behaviors that
  //       need to be carried out in response to user input.
  _paste(
    document: editContext.editor.document,
    editor: editContext.editor,
    composer: editContext.composer,
    pastePosition: pastePosition,
  );

  return ExecutionInstruction.haltExecution;
}

ExecutionInstruction selectAllWhenCmdAIsPressed({
  required EditContext editContext,
  required RawKeyEvent keyEvent,
}) {
  if (!keyEvent.isPrimaryShortcutKeyPressed || keyEvent.character?.toLowerCase() != 'a') {
    return ExecutionInstruction.continueExecution;
  }

  final nodes = editContext.editor.document.nodes;
  if (nodes.isEmpty) {
    return ExecutionInstruction.continueExecution;
  }

  editContext.composer.selection = DocumentSelection(
    base: DocumentPosition(
      nodeId: nodes.first.id,
      nodePosition: nodes.first.beginningPosition,
    ),
    extent: DocumentPosition(
      nodeId: nodes.last.id,
      nodePosition: nodes.last.endPosition,
    ),
  );

  return ExecutionInstruction.haltExecution;
}

Future<void> _paste({
  required Document document,
  required DocumentEditor editor,
  required DocumentComposer composer,
  required DocumentPosition pastePosition,
}) async {
  final content = (await Clipboard.getData('text/plain'))?.text ?? '';
  _log.log('_paste', 'Content from clipboard: $content');

  editor.executeCommand(
    PasteEditorCommand(
      content: content,
      pastePosition: pastePosition,
      composer: composer,
    ),
  );
}

class PasteEditorCommand implements EditorCommand {
  PasteEditorCommand({
    required String content,
    required DocumentPosition pastePosition,
    required DocumentComposer composer,
  })  : _content = content,
        _pastePosition = pastePosition,
        _composer = composer;

  final String _content;
  final DocumentPosition _pastePosition;
  final DocumentComposer _composer;

  @override
  void execute(Document document, DocumentEditorTransaction transaction) {
    final splitContent = _content.split('\n\n');
    _log.log('_PasteEditorCommand', 'Split content:');
    for (final piece in splitContent) {
      _log.log('_PasteEditorCommand', ' - "$piece"');
    }

    final currentNodeWithSelection = document.getNodeById(_pastePosition.nodeId);

    DocumentPosition? newSelectionPosition;

    if (currentNodeWithSelection is TextNode) {
      final textNode = document.getNode(_pastePosition) as TextNode;
      final pasteTextOffset = (_pastePosition.nodePosition as TextPosition).offset;
      final attributionsAtPasteOffset = textNode.text.getAllAttributionsAt(pasteTextOffset);

      if (splitContent.length > 1 && pasteTextOffset < textNode.endPosition.offset) {
        // There is more than 1 node of content being pasted. Therefore,
        // new nodes will need to be added, which means that the currently
        // selected text node will be split at the current text offset.
        // Configure a new node to be added at the end of the pasted content
        // which contains the trailing text from the currently selected
        // node.
        if (currentNodeWithSelection is ParagraphNode) {
          SplitParagraphCommand(
            nodeId: currentNodeWithSelection.id,
            splitPosition: TextPosition(offset: pasteTextOffset),
            newNodeId: DocumentEditor.createNodeId(),
          ).execute(document, transaction);
        } else {
          throw Exception('Can\'t handle pasting text within node of type: $currentNodeWithSelection');
        }
      }

      // Paste the first piece of content into the selected TextNode.
      InsertTextCommand(
        documentPosition: _pastePosition,
        textToInsert: splitContent.first,
        attributions: attributionsAtPasteOffset,
      ).execute(document, transaction);

      // At this point in the paste process, the document selection
      // position is at the end of the text that was just pasted.
      newSelectionPosition = DocumentPosition(
        nodeId: currentNodeWithSelection.id,
        nodePosition: TextPosition(
          offset: pasteTextOffset + splitContent.first.length,
        ),
      );

      // Remove the pasted text from the list of pieces of text
      // to paste.
      splitContent.removeAt(0);
    }

    final newNodes = splitContent
        .map(
          // TODO: create nodes based on content inspection.
          (nodeText) => ParagraphNode(
            id: DocumentEditor.createNodeId(),
            text: AttributedText(
              text: nodeText,
            ),
          ),
        )
        .toList();
    _log.log('_PasteEditorCommand', ' - new nodes: $newNodes');

    int newNodeToMergeIndex = 0;
    DocumentNode mergeAfterNode;

    final nodeWithSelection = document.getNodeById(_pastePosition.nodeId);
    if (nodeWithSelection == null) {
      throw Exception(
          'Failed to complete paste process because the node being pasted into disappeared from the document unexpectedly.');
    }
    mergeAfterNode = nodeWithSelection;

    for (int i = newNodeToMergeIndex; i < newNodes.length; ++i) {
      transaction.insertNodeAfter(
        previousNode: mergeAfterNode,
        newNode: newNodes[i],
      );
      mergeAfterNode = newNodes[i];

      newSelectionPosition = DocumentPosition(
        nodeId: mergeAfterNode.id,
        nodePosition: mergeAfterNode.endPosition,
      );
    }

    _composer.selection = DocumentSelection.collapsed(
      position: newSelectionPosition!,
    );
    _log.log('_PasteEditorCommand', ' - new selection: ${_composer.selection}');

    _log.log('_PasteEditorCommand', 'Done with paste command.');
  }
}

ExecutionInstruction copyWhenCmdVIsPressed({
  required EditContext editContext,
  required RawKeyEvent keyEvent,
}) {
  if (!keyEvent.isPrimaryShortcutKeyPressed || keyEvent.character?.toLowerCase() != 'c') {
    return ExecutionInstruction.continueExecution;
  }
  if (editContext.composer.selection == null) {
    return ExecutionInstruction.continueExecution;
  }
  if (editContext.composer.selection!.isCollapsed) {
    // Nothing to copy, but we technically handled the task.
    return ExecutionInstruction.haltExecution;
  }

  // TODO: figure out a general approach for asynchronous behaviors that
  //       need to be carried out in response to user input.
  _copy(
    document: editContext.editor.document,
    documentSelection: editContext.composer.selection!,
  );

  return ExecutionInstruction.haltExecution;
}

Future<void> _copy({
  required Document document,
  required DocumentSelection documentSelection,
}) async {
  final selectedNodes = document.getNodesInside(
    documentSelection.base,
    documentSelection.extent,
  );

  final buffer = StringBuffer();
  for (int i = 0; i < selectedNodes.length; ++i) {
    final selectedNode = selectedNodes[i];
    dynamic nodeSelection;

    if (i == 0) {
      // This is the first node and it may be partially selected.
      final baseSelectionPosition = selectedNode.id == documentSelection.base.nodeId
          ? documentSelection.base.nodePosition
          : documentSelection.extent.nodePosition;

      final extentSelectionPosition =
          selectedNodes.length > 1 ? selectedNode.endPosition : documentSelection.extent.nodePosition;

      nodeSelection = selectedNode.computeSelection(
        base: baseSelectionPosition,
        extent: extentSelectionPosition,
      );
    } else if (i == selectedNodes.length - 1) {
      // This is the last node and it may be partially selected.
      final nodePosition = selectedNode.id == documentSelection.base.nodeId
          ? documentSelection.base.nodePosition
          : documentSelection.extent.nodePosition;

      nodeSelection = selectedNode.computeSelection(
        base: selectedNode.beginningPosition,
        extent: nodePosition,
      );
    } else {
      // This node is fully selected. Copy the whole thing.
      nodeSelection = selectedNode.computeSelection(
        base: selectedNode.beginningPosition,
        extent: selectedNode.endPosition,
      );
    }

    final nodeContent = selectedNode.copyContent(nodeSelection);
    if (nodeContent != null) {
      buffer.write(nodeContent);
      if (i < selectedNodes.length - 1) {
        buffer.writeln();
      }
    }
  }

  await Clipboard.setData(
    ClipboardData(
      text: buffer.toString(),
    ),
  );
}

ExecutionInstruction applyBoldWhenCmdBIsPressed({
  required EditContext editContext,
  required RawKeyEvent keyEvent,
}) {
  if (!keyEvent.isPrimaryShortcutKeyPressed || keyEvent.character?.toLowerCase() != 'b') {
    return ExecutionInstruction.continueExecution;
  }
  if (editContext.composer.selection == null) {
    return ExecutionInstruction.continueExecution;
  }

  if (editContext.composer.selection!.isCollapsed) {
    editContext.composer.preferences.toggleStyle(boldAttribution);
    return ExecutionInstruction.haltExecution;
  }

  // Toggle the selected content with a bold attribution.
  editContext.editor.executeCommand(
    ToggleTextAttributionsCommand(
      documentSelection: editContext.composer.selection!,
      attributions: {boldAttribution},
    ),
  );

  editContext.composer.notifyListeners();

  return ExecutionInstruction.haltExecution;
}

ExecutionInstruction applyItalicsWhenCmdIIsPressed({
  required EditContext editContext,
  required RawKeyEvent keyEvent,
}) {
  if (!keyEvent.isPrimaryShortcutKeyPressed || keyEvent.character?.toLowerCase() != 'i') {
    return ExecutionInstruction.continueExecution;
  }
  if (editContext.composer.selection == null) {
    return ExecutionInstruction.continueExecution;
  }

  if (editContext.composer.selection!.isCollapsed) {
    editContext.composer.preferences.toggleStyle(italicsAttribution);
    return ExecutionInstruction.haltExecution;
  }

  // Toggle the selected content with a bold attribution.
  editContext.editor.executeCommand(
    ToggleTextAttributionsCommand(
      documentSelection: editContext.composer.selection!,
      attributions: {italicsAttribution},
    ),
  );

  editContext.composer.notifyListeners();

  return ExecutionInstruction.haltExecution;
}

ExecutionInstruction deleteExpandedSelectionWhenCharacterOrDestructiveKeyPressed({
  required EditContext editContext,
  required RawKeyEvent keyEvent,
}) {
  _log.log('deleteExpandedSelectionWhenCharacterOrDestructiveKeyPressed', 'Running...');
  if (editContext.composer.selection == null || editContext.composer.selection!.isCollapsed) {
    return ExecutionInstruction.continueExecution;
  }

  // Specifically exclude situations where shift is pressed because shift
  // needs to alter the selection, not delete content. We have to explicitly
  // look for this because when shift is pressed along with an arrow key,
  // Flutter reports a non-null character.
  final isShiftPressed = keyEvent.isShiftPressed;

  final isDestructiveKey =
      keyEvent.logicalKey == LogicalKeyboardKey.backspace || keyEvent.logicalKey == LogicalKeyboardKey.delete;

  final shouldDeleteSelection = !isShiftPressed &&
      (isDestructiveKey ||
          (keyEvent.character != null &&
              keyEvent.character != '' &&
              !webBugBlacklistCharacters.contains(keyEvent.character)));
  if (!shouldDeleteSelection) {
    return ExecutionInstruction.continueExecution;
  }

  final newSelectionPosition = getDocumentPositionAfterDeletion(
    document: editContext.editor.document,
    selection: editContext.composer.selection!,
  );

  // Delete the selected content.
  editContext.editor.executeCommand(
    DeleteSelectionCommand(documentSelection: editContext.composer.selection!),
  );

  _log.log('deleteExpandedSelectionWhenCharacterOrDestructiveKeyPressed',
      ' - new document selection position: ${newSelectionPosition.nodePosition}');
  editContext.composer.selection = DocumentSelection.collapsed(position: newSelectionPosition);

  return isDestructiveKey ? ExecutionInstruction.haltExecution : ExecutionInstruction.continueExecution;
}

DocumentPosition getDocumentPositionAfterDeletion({
  required Document document,
  required DocumentSelection selection,
}) {
  // Figure out where the caret should appear after the
  // deletion.
  // TODO: This calculation depends upon the first
  //       selected node still existing after the deletion. This
  //       is a fragile expectation and should be revisited.
  final basePosition = selection.base;
  final baseNode = document.getNode(basePosition);
  if (baseNode == null) {
    throw Exception('Failed to _getDocumentPositionAfterDeletion because the base node no longer exists.');
  }
  final baseNodeIndex = document.getNodeIndex(baseNode);

  final extentPosition = selection.extent;
  final extentNode = document.getNode(extentPosition);
  if (extentNode == null) {
    throw Exception('Failed to _getDocumentPositionAfterDeletion because the extent node no longer exists.');
  }
  final extentNodeIndex = document.getNodeIndex(extentNode);
  DocumentPosition newSelectionPosition;

  if (baseNodeIndex != extentNodeIndex) {
    // Place the caret at the current position within the
    // first node in the selection.
    newSelectionPosition = baseNodeIndex <= extentNodeIndex ? selection.base : selection.extent;

    // If it's a binary selection node then that node will
    // be replaced by a ParagraphNode with the same ID.
    if (newSelectionPosition.nodePosition is BinaryPosition) {
      // Assume that the node was replaced with an empty paragraph.
      newSelectionPosition = DocumentPosition(
        nodeId: newSelectionPosition.nodeId,
        nodePosition: TextPosition(offset: 0),
      );
    }
  } else {
    // Selection is within a single node. If it's a binary
    // selection node then that node will be replaced by
    // a ParagraphNode with the same ID. Otherwise, it must
    // be a TextNode, in which case we need to figure out
    // which DocumentPosition contains the earlier TextPosition.
    if (basePosition.nodePosition is BinaryPosition) {
      // Assume that the node was replace with an empty paragraph.
      newSelectionPosition = DocumentPosition(
        nodeId: baseNode.id,
        nodePosition: TextPosition(offset: 0),
      );
    } else if (basePosition.nodePosition is TextPosition) {
      final baseOffset = (basePosition.nodePosition as TextPosition).offset;
      final extentOffset = (extentPosition.nodePosition as TextPosition).offset;

      newSelectionPosition = DocumentPosition(
        nodeId: baseNode.id,
        nodePosition: TextPosition(offset: min(baseOffset, extentOffset)),
      );
    } else {
      throw Exception(
          'Unknown selection position type: $basePosition, for node: $baseNode, within document selection: $selection');
    }
  }

  return newSelectionPosition;
}

ExecutionInstruction mergeNodeWithPreviousWhenBackspaceIsPressed({
  required EditContext editContext,
  required RawKeyEvent keyEvent,
}) {
  if (keyEvent.logicalKey != LogicalKeyboardKey.backspace) {
    return ExecutionInstruction.continueExecution;
  }

  if (editContext.composer.selection == null) {
    return ExecutionInstruction.continueExecution;
  }

  final node = editContext.editor.document.getNodeById(editContext.composer.selection!.extent.nodeId);
  if (node is! TextNode) {
    _log.log(
        'mergeNodeWithPreviousWhenBackspaceIsPressed', 'WARNING: Cannot merge node of type: $node into node above.');
    return ExecutionInstruction.continueExecution;
  }

  _log.log('mergeNodeWithPreviousWhenBackspaceIsPressed', 'All nodes in order:');
  editContext.editor.document.nodes.forEach((aNode) {
    _log.log('mergeNodeWithPreviousWhenBackspaceIsPressed', ' - node: ${aNode.id}');
  });
  _log.log('mergeNodeWithPreviousWhenBackspaceIsPressed', 'Looking for node above: ${node.id}');
  final nodeAbove = editContext.editor.document.getNodeBefore(node);
  if (nodeAbove == null) {
    _log.log('mergeNodeWithPreviousWhenBackspaceIsPressed', 'At top of document. Cannot merge with node above.');
    return ExecutionInstruction.continueExecution;
  }
  if (nodeAbove is! TextNode) {
    _log.log('mergeNodeWithPreviousWhenBackspaceIsPressed', 'Cannot merge ParagraphNode into node of type: $nodeAbove');
    return ExecutionInstruction.continueExecution;
  }

  final aboveParagraphLength = nodeAbove.text.text.length;

  // Send edit command.
  editContext.editor.executeCommand(
    CombineParagraphsCommand(
      firstNodeId: nodeAbove.id,
      secondNodeId: node.id,
    ),
  );

  // Place the cursor at the point where the text came together.
  editContext.composer.selection = DocumentSelection.collapsed(
    position: DocumentPosition(
      nodeId: nodeAbove.id,
      nodePosition: TextPosition(offset: aboveParagraphLength),
    ),
  );

  return ExecutionInstruction.haltExecution;
}

ExecutionInstruction mergeNodeWithNextWhenDeleteIsPressed({
  required EditContext editContext,
  required RawKeyEvent keyEvent,
}) {
  if (keyEvent.logicalKey != LogicalKeyboardKey.delete) {
    return ExecutionInstruction.continueExecution;
  }

  if (editContext.composer.selection == null) {
    return ExecutionInstruction.continueExecution;
  }

  final node = editContext.editor.document.getNodeById(editContext.composer.selection!.extent.nodeId);
  if (node is! TextNode) {
    _log.log('mergeNodeWithNextWhenDeleteIsPressed', 'WARNING: Cannot combine node of type: $node');
    return ExecutionInstruction.continueExecution;
  }

  final nextNode = editContext.editor.document.getNodeAfter(node);
  if (nextNode == null) {
    _log.log('mergeNodeWithNextWhenDeleteIsPressed', 'At bottom of document. Cannot merge with node above.');
    return ExecutionInstruction.continueExecution;
  }
  if (nextNode is! TextNode) {
    _log.log('mergeNodeWithNextWhenDeleteIsPressed', 'Cannot merge ParagraphNode into node of type: $nextNode');
    return ExecutionInstruction.continueExecution;
  }

  _log.log('mergeNodeWithNextWhenDeleteIsPressed', 'Combining node with next.');
  final currentParagraphLength = node.text.text.length;

  // Send edit command.
  editContext.editor.executeCommand(
    CombineParagraphsCommand(
      firstNodeId: node.id,
      secondNodeId: nextNode.id,
    ),
  );

  // Place the cursor at the point where the text came together.
  editContext.composer.selection = DocumentSelection.collapsed(
    position: DocumentPosition(
      nodeId: node.id,
      nodePosition: TextPosition(offset: currentParagraphLength),
    ),
  );

  return ExecutionInstruction.haltExecution;
}

ExecutionInstruction moveUpDownLeftAndRightWithArrowKeys({
  required EditContext editContext,
  required RawKeyEvent keyEvent,
}) {
  const arrowKeys = [
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown,
  ];
  if (!arrowKeys.contains(keyEvent.logicalKey)) {
    return ExecutionInstruction.continueExecution;
  }
  if (editContext.composer.selection == null) {
    return ExecutionInstruction.continueExecution;
  }

  if (keyEvent.logicalKey == LogicalKeyboardKey.arrowLeft) {
    _log.log('moveUpDownLeftAndRightWithArrowKeys', ' - handling left arrow key');

    final movementModifiers = <String, dynamic>{
      'movement_unit': 'character',
    };
    if (keyEvent.isPrimaryShortcutKeyPressed) {
      movementModifiers['movement_unit'] = 'line';
    } else if (keyEvent.isAltPressed) {
      movementModifiers['movement_unit'] = 'word';
    }

    _moveHorizontally(
      editContext: editContext,
      expandSelection: keyEvent.isShiftPressed,
      moveLeft: true,
      movementModifiers: movementModifiers,
    );
  } else if (keyEvent.logicalKey == LogicalKeyboardKey.arrowRight) {
    _log.log('moveUpDownLeftAndRightWithArrowKeys', ' - handling right arrow key');

    final movementModifiers = <String, dynamic>{
      'movement_unit': 'character',
    };
    if (keyEvent.isPrimaryShortcutKeyPressed) {
      movementModifiers['movement_unit'] = 'line';
    } else if (keyEvent.isAltPressed) {
      movementModifiers['movement_unit'] = 'word';
    }

    _moveHorizontally(
      editContext: editContext,
      expandSelection: keyEvent.isShiftPressed,
      moveLeft: false,
      movementModifiers: movementModifiers,
    );
  } else if (keyEvent.logicalKey == LogicalKeyboardKey.arrowUp) {
    _log.log('moveUpDownLeftAndRightWithArrowKeys', ' - handling up arrow key');
    _moveVertically(
      editContext: editContext,
      expandSelection: keyEvent.isShiftPressed,
      moveUp: true,
    );
  } else if (keyEvent.logicalKey == LogicalKeyboardKey.arrowDown) {
    _log.log('moveUpDownLeftAndRightWithArrowKeys', ' - handling down arrow key');
    _moveVertically(
      editContext: editContext,
      expandSelection: keyEvent.isShiftPressed,
      moveUp: false,
    );
  }

  return ExecutionInstruction.haltExecution;
}

void _moveHorizontally({
  required EditContext editContext,
  required bool expandSelection,
  required bool moveLeft,
  Map<String, dynamic> movementModifiers = const {},
}) {
  if (editContext.composer.selection == null) {
    return;
  }

  final currentExtent = editContext.composer.selection!.extent;
  final nodeId = currentExtent.nodeId;
  final node = editContext.editor.document.getNodeById(nodeId);
  if (node == null) {
    throw Exception('Could not find the node with the current selection extent: $nodeId');
  }
  final extentComponent = editContext.documentLayout.getComponentByNodeId(nodeId);
  if (extentComponent == null) {
    throw Exception('Could not find a component for the document node at "$nodeId"');
  }

  String newExtentNodeId = nodeId;
  dynamic newExtentNodePosition = moveLeft
      ? extentComponent.movePositionLeft(currentExtent.nodePosition, movementModifiers)
      : extentComponent.movePositionRight(currentExtent.nodePosition, movementModifiers);

  if (newExtentNodePosition == null) {
    _log.log('_moveHorizontally', ' - moving to next node');
    // Move to next node
    final nextNode =
        moveLeft ? editContext.editor.document.getNodeBefore(node) : editContext.editor.document.getNodeAfter(node);

    if (nextNode == null) {
      // We're at the beginning/end of the document and can't go
      // anywhere.
      return;
    }

    newExtentNodeId = nextNode.id;
    final nextComponent = editContext.documentLayout.getComponentByNodeId(nextNode.id);
    if (nextComponent == null) {
      throw Exception('Could not find next component to move the selection horizontally. Next node ID: ${nextNode.id}');
    }
    newExtentNodePosition = moveLeft ? nextComponent.getEndPosition() : nextComponent.getBeginningPosition();
  }

  final newExtent = DocumentPosition(
    nodeId: newExtentNodeId,
    nodePosition: newExtentNodePosition,
  );

  if (expandSelection) {
    // Selection should be expanded.
    editContext.composer.selection = editContext.composer.selection!.expandTo(
      newExtent,
    );
  } else {
    // Selection should be replaced by new collapsed position.
    editContext.composer.selection = DocumentSelection.collapsed(
      position: newExtent,
    );
  }
}

void _moveVertically({
  required EditContext editContext,
  required bool expandSelection,
  required bool moveUp,
}) {
  if (editContext.composer.selection == null) {
    return null;
  }

  final currentExtent = editContext.composer.selection!.extent;
  final nodeId = currentExtent.nodeId;
  final node = editContext.editor.document.getNodeById(nodeId);
  if (node == null) {
    throw Exception('Could not find the node with the current selection extent: $nodeId');
  }
  final extentComponent = editContext.documentLayout.getComponentByNodeId(nodeId);
  if (extentComponent == null) {
    throw Exception('Could not find a component for the document node at "$nodeId"');
  }

  String newExtentNodeId = nodeId;
  dynamic newExtentNodePosition = moveUp
      ? extentComponent.movePositionUp(currentExtent.nodePosition)
      : extentComponent.movePositionDown(currentExtent.nodePosition);

  if (newExtentNodePosition == null) {
    _log.log('_moveVertically', ' - moving to next node');
    // Move to next node
    final nextNode =
        moveUp ? editContext.editor.document.getNodeBefore(node) : editContext.editor.document.getNodeAfter(node);
    if (nextNode != null) {
      _log.log('_moveVertically',
          ' - next node is at offset ${editContext.editor.document.getNodeIndex(nextNode)}, id: ${nextNode.id}');
      newExtentNodeId = nextNode.id;
      final nextComponent = editContext.documentLayout.getComponentByNodeId(nextNode.id);
      if (nextComponent == null) {
        throw Exception('Could not find next component to move the selection vertically. Next node ID: ${nextNode.id}');
      }
      final offsetToMatch = extentComponent.getOffsetForPosition(currentExtent.nodePosition);
      _log.log('_moveVertically', ' - offset to match');

      if (offsetToMatch == null) {
        // No (x,y) offset was provided. Place the selection at the
        // beginning or end of the node, depending on direction.
        newExtentNodePosition = moveUp ? nextComponent.getEndPosition() : nextComponent.getBeginningPosition();
      } else {
        // An (x,y) offset was provided. Place the selection as close
        // to the given x-value as possible within the node.
        newExtentNodePosition = moveUp
            ? nextComponent.getEndPositionNearX(offsetToMatch.dx)
            : nextComponent.getBeginningPositionNearX(offsetToMatch.dx);
      }
    } else {
      _log.log('_moveVertically', ' - there is no next node. Ignoring.');
      // We're at the top/bottom of the document. Move the cursor to the
      // beginning/end of the current node.
      newExtentNodePosition = moveUp ? extentComponent.getBeginningPosition() : extentComponent.getEndPosition();
    }
  }

  final newExtent = DocumentPosition(
    nodeId: newExtentNodeId,
    nodePosition: newExtentNodePosition,
  );

  if (expandSelection) {
    // Selection should be expanded.
    editContext.composer.selection = editContext.composer.selection!.expandTo(
      newExtent,
    );
  } else {
    // Selection should be replaced by new collapsed position.
    editContext.composer.selection = DocumentSelection.collapsed(
      position: newExtent,
    );
  }
}

TextSelection moveSelectionToEnd({
  required String text,
  TextSelection? previousSelection,
  bool expandSelection = false,
}) {
  if (previousSelection != null && expandSelection) {
    return TextSelection(
      baseOffset: expandSelection ? previousSelection.baseOffset : text.length,
      extentOffset: text.length,
    );
  } else {
    return TextSelection.collapsed(
      offset: text.length,
    );
  }
}
