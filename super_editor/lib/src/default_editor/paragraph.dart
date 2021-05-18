import 'package:collection/collection.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:linkify/linkify.dart';
import 'package:super_editor/src/core/document.dart';
import 'package:super_editor/src/core/document_composer.dart';
import 'package:super_editor/src/core/document_editor.dart';
import 'package:super_editor/src/core/document_layout.dart';
import 'package:super_editor/src/core/document_selection.dart';
import 'package:super_editor/src/core/edit_context.dart';
import 'package:super_editor/src/default_editor/attributions.dart';
import 'package:super_editor/src/default_editor/document_interaction.dart';
import 'package:super_editor/src/default_editor/text.dart';
import 'package:super_editor/src/infrastructure/_logging.dart';
import 'package:super_editor/src/infrastructure/attributed_text.dart';
import 'package:super_editor/src/infrastructure/keyboard.dart';

import 'horizontal_rule.dart';
import 'image.dart';
import 'list_items.dart';
import 'styles.dart';

final _log = Logger(scope: 'paragraph.dart');

class ParagraphNode extends TextNode {
  ParagraphNode({
    required String id,
    required AttributedText text,
    Map<String, dynamic>? metadata,
  }) : super(
          id: id,
          text: text,
          metadata: metadata,
        );
}

/// Combines two consecutive `ParagraphNode`s, indicated by `firstNodeId`
/// and `secondNodeId`, respectively.
///
/// If the specified nodes are not sequential, or are sequential
/// in reverse order, the command fizzles.
///
/// If both nodes are not `ParagraphNode`s, the command fizzles.
class CombineParagraphsCommand implements EditorCommand {
  CombineParagraphsCommand({
    required this.firstNodeId,
    required this.secondNodeId,
  }) : assert(firstNodeId != secondNodeId);

  final String firstNodeId;
  final String secondNodeId;

  @override
  void execute(Document document, DocumentEditorTransaction transaction) {
    _log.log('CombineParagraphsCommand', 'Executing CombineParagraphsCommand');
    _log.log('CombineParagraphsCommand', ' - merging "$firstNodeId" <- "$secondNodeId"');
    final secondNode = document.getNodeById(secondNodeId);
    if (secondNode is! TextNode) {
      _log.log('CombineParagraphsCommand', 'WARNING: Cannot merge node of type: $secondNode into node above.');
      return;
    }

    final nodeAbove = document.getNodeBefore(secondNode);
    if (nodeAbove == null) {
      _log.log('CombineParagraphsCommand', 'At top of document. Cannot merge with node above.');
      return;
    }
    if (nodeAbove.id != firstNodeId) {
      _log.log('CombineParagraphsCommand', 'The specified `firstNodeId` is not the node before `secondNodeId`.');
      return;
    }
    if (nodeAbove is! TextNode) {
      _log.log('CombineParagraphsCommand', 'Cannot merge ParagraphNode into node of type: $nodeAbove');
      return;
    }

    // Combine the text and delete the currently selected node.
    nodeAbove.text = nodeAbove.text.copyAndAppend(secondNode.text);
    bool didRemove = transaction.deleteNode(secondNode);
    if (!didRemove) {
      _log.log('CombineParagraphsCommand', 'ERROR: Failed to delete the currently selected node from the document.');
    }
  }
}

/// Splits the `ParagraphNode` affiliated with the given `nodeId` at the
/// given `splitPosition`, placing all text after `splitPosition` in a
/// new `ParagraphNode` with the given `newNodeId`, inserted after the
/// original node.
class SplitParagraphCommand implements EditorCommand {
  SplitParagraphCommand({
    required this.nodeId,
    required this.splitPosition,
    required this.newNodeId,
  });

  final String nodeId;
  final TextPosition splitPosition;
  final String newNodeId;

  @override
  void execute(Document document, DocumentEditorTransaction transaction) {
    _log.log('SplitParagraphCommand', 'Executing SplitParagraphCommand');

    final node = document.getNodeById(nodeId);
    if (node is! ParagraphNode) {
      _log.log('SplitParagraphCommand', 'WARNING: Cannot split paragraph for node of type: $node.');
      return;
    }

    final text = node.text;
    final startText = text.copyText(0, splitPosition.offset);
    final endText = text.copyText(splitPosition.offset);
    _log.log('SplitParagraphCommand', 'Splitting paragraph:');
    _log.log('SplitParagraphCommand', ' - start text: "${startText.text}"');
    _log.log('SplitParagraphCommand', ' - end text: "${endText.text}"');

    // Change the current nodes content to just the text before the caret.
    _log.log('SplitParagraphCommand', ' - changing the original paragraph text due to split');
    node.text = startText;

    // Create a new node that will follow the current node. Set its text
    // to the text that was removed from the current node.
    final newNode = ParagraphNode(
      id: newNodeId,
      text: endText,
    );

    // Insert the new node after the current node.
    _log.log('SplitParagraphCommand', ' - inserting new node in document');
    transaction.insertNodeAfter(
      previousNode: node,
      newNode: newNode,
    );

    _log.log('SplitParagraphCommand', ' - inserted new node: ${newNode.id} after old one: ${node.id}');
  }
}

ExecutionInstruction insertCharacterInParagraph({
  required EditContext editContext,
  required RawKeyEvent keyEvent,
}) {
  if (editContext.composer.selection == null) {
    return ExecutionInstruction.continueExecution;
  }

  final node = editContext.editor.document.getNodeById(editContext.composer.selection!.extent.nodeId);
  if (node is! ParagraphNode) {
    return ExecutionInstruction.continueExecution;
  }
  if (keyEvent.character == null ||
      keyEvent.character == '' ||
      webBugBlacklistCharacters.contains(keyEvent.character)) {
    return ExecutionInstruction.continueExecution;
  }
  if (!editContext.composer.selection!.isCollapsed) {
    return ExecutionInstruction.continueExecution;
  }
  print('Inserting character in paragraph');

  // Delegate the action to the standard insert-character behavior.
  insertCharacterInTextComposable(
    editContext: editContext,
    keyEvent: keyEvent,
  );

  if (keyEvent.character == ' ') {
    _convertParagraphIfDesired(
      document: editContext.editor.document,
      composer: editContext.composer,
      node: node,
      editor: editContext.editor,
    );
  }

  return ExecutionInstruction.haltExecution;
}

// TODO: refactor to make prefix matching extensible (#68)
bool _convertParagraphIfDesired({
  required Document document,
  required DocumentComposer composer,
  required ParagraphNode node,
  required DocumentEditor editor,
}) {
  if (composer.selection == null) {
    // This method shouldn't be invoked if the given node
    // doesn't have the caret, but we check just in case.
    return false;
  }

  final text = node.text;
  final textSelection = composer.selection!.extent.nodePosition as TextPosition;
  final textBeforeCaret = text.text.substring(0, textSelection.offset);

  final unorderedListItemMatch = RegExp(r'^\s*[\*-]\s+$');
  final hasUnorderedListItemMatch = unorderedListItemMatch.hasMatch(textBeforeCaret);

  final orderedListItemMatch = RegExp(r'^\s*[1].*\s+$');
  final hasOrderedListItemMatch = orderedListItemMatch.hasMatch(textBeforeCaret);

  _log.log('_convertParagraphIfDesired', ' - text before caret: "$textBeforeCaret"');
  if (hasUnorderedListItemMatch || hasOrderedListItemMatch) {
    _log.log('_convertParagraphIfDesired', ' - found unordered list item prefix');
    int startOfNewText = textBeforeCaret.length;
    while (startOfNewText < node.text.text.length && node.text.text[startOfNewText] == ' ') {
      startOfNewText += 1;
    }
    // final adjustedText = node.text.text.substring(startOfNewText);
    final adjustedText = node.text.copyText(startOfNewText);
    final newNode = hasUnorderedListItemMatch
        ? ListItemNode.unordered(id: node.id, text: adjustedText)
        : ListItemNode.ordered(id: node.id, text: adjustedText);
    final nodeIndex = document.getNodeIndex(node);

    editor.executeCommand(
      EditorCommandFunction((document, transaction) {
        transaction
          ..deleteNodeAt(nodeIndex)
          ..insertNodeAt(nodeIndex, newNode);
      }),
    );

    // We removed some text at the beginning of the list item.
    // Move the selection back by that same amount.
    final textPosition = composer.selection!.extent.nodePosition as TextPosition;
    composer.selection = DocumentSelection.collapsed(
      position: DocumentPosition(
        nodeId: node.id,
        nodePosition: TextPosition(offset: textPosition.offset - startOfNewText),
      ),
    );

    return true;
  }

  final hrMatch = RegExp(r'^---*\s$');
  final hasHrMatch = hrMatch.hasMatch(textBeforeCaret);
  if (hasHrMatch) {
    _log.log('_convertParagraphIfDesired', 'Paragraph has an HR match');
    // Insert an HR before this paragraph and then clear the
    // paragraph's content.
    final paragraphNodeIndex = document.getNodeIndex(node);

    editor.executeCommand(
      EditorCommandFunction((document, transaction) {
        transaction.insertNodeAt(
          paragraphNodeIndex,
          HorizontalRuleNode(
            id: DocumentEditor.createNodeId(),
          ),
        );
      }),
    );

    node.text = node.text.removeRegion(startOffset: 0, endOffset: hrMatch.firstMatch(textBeforeCaret)!.end);

    composer.selection = DocumentSelection.collapsed(
      position: DocumentPosition(
        nodeId: node.id,
        nodePosition: TextPosition(offset: 0),
      ),
    );

    return true;
  }

  final blockquoteMatch = RegExp(r'^>\s$');
  final hasBlockquoteMatch = blockquoteMatch.hasMatch(textBeforeCaret);
  if (hasBlockquoteMatch) {
    int startOfNewText = textBeforeCaret.length;
    while (startOfNewText < node.text.text.length && node.text.text[startOfNewText] == ' ') {
      startOfNewText += 1;
    }
    final adjustedText = node.text.copyText(startOfNewText);
    final newNode = ParagraphNode(
      id: node.id,
      text: adjustedText,
      metadata: {'blockType': blockquoteAttribution},
    );
    final nodeIndex = document.getNodeIndex(node);

    editor.executeCommand(
      EditorCommandFunction((document, transaction) {
        transaction
          ..deleteNodeAt(nodeIndex)
          ..insertNodeAt(nodeIndex, newNode);
      }),
    );

    // We removed some text at the beginning of the list item.
    // Move the selection back by that same amount.
    final textPosition = composer.selection!.extent.nodePosition as TextPosition;
    composer.selection = DocumentSelection.collapsed(
      position: DocumentPosition(
        nodeId: node.id,
        nodePosition: TextPosition(offset: textPosition.offset - startOfNewText),
      ),
    );

    return true;
  }

  // URL match, e.g., images, social, etc.
  _log.log('_convertParagraphIfDesired', 'Looking for URL match...');
  final extractedLinks = linkify(node.text.text,
      options: LinkifyOptions(
        humanize: false,
      ));
  final int linkCount = extractedLinks.fold(0, (value, element) => element is UrlElement ? value + 1 : value);
  final String nonEmptyText =
      extractedLinks.fold('', (value, element) => element is TextElement ? value + element.text.trim() : value);
  if (linkCount == 1 && nonEmptyText.isEmpty) {
    // This node's text is just a URL, try to interpret it
    // as a known type.
    final link = extractedLinks.firstWhereOrNull((element) => element is UrlElement)!.text;
    _processUrlNode(
      document: document,
      editor: editor,
      nodeId: node.id,
      originalText: node.text.text,
      url: link,
    );
    return true;
  }

  // No pattern match was found
  return false;
}

Future<void> _processUrlNode({
  required Document document,
  required DocumentEditor editor,
  required String nodeId,
  required String originalText,
  required String url,
}) async {
  final response = await http.get(Uri.parse(url));

  if (response.statusCode < 200 || response.statusCode >= 300) {
    _log.log('_processUrlNode', 'Failed to load URL: ${response.statusCode} - ${response.reasonPhrase}');
    return;
  }

  final contentType = response.headers['content-type'];
  if (contentType == null) {
    _log.log('_processUrlNode', 'Failed to determine URL content type.');
    return;
  }
  if (!contentType.startsWith('image/')) {
    _log.log('_processUrlNode', 'URL is not an image. Ignoring');
    return;
  }

  // The URL is an image. Convert the node.
  _log.log('_processUrlNode', 'The URL is an image. Converting the ParagraphNode to an ImageNode.');
  final node = document.getNodeById(nodeId);
  if (node is! ParagraphNode) {
    _log.log(
        '_processUrlNode', 'The node has become something other than a ParagraphNode ($node). Can\'t convert ndoe.');
    return;
  }
  final currentText = node.text.text;
  if (currentText.trim() != originalText.trim()) {
    _log.log('_processUrlNode', 'The node content changed in a non-trivial way. Aborting node conversion.');
    return;
  }

  final imageNode = ImageNode(
    id: node.id,
    imageUrl: url,
  );
  final nodeIndex = document.getNodeIndex(node);

  editor.executeCommand(
    EditorCommandFunction((document, transaction) {
      transaction
        ..deleteNodeAt(nodeIndex)
        ..insertNodeAt(nodeIndex, imageNode);
    }),
  );
}

class DeleteParagraphsCommand implements EditorCommand {
  DeleteParagraphsCommand({
    required this.nodeId,
  });

  final String nodeId;

  @override
  void execute(Document document, DocumentEditorTransaction transaction) {
    _log.log('DeleteParagraphsCommand', 'Executing DeleteParagraphsCommand');
    _log.log('DeleteParagraphsCommand', ' - deleting "$nodeId"');
    final node = document.getNodeById(nodeId);
    if (node is! TextNode) {
      _log.log('DeleteParagraphsCommand', 'WARNING: Cannot delete node of type: $node.');
      return;
    }

    bool didRemove = transaction.deleteNode(node);
    if (!didRemove) {
      _log.log('DeleteParagraphsCommand', 'ERROR: Failed to delete node "$node" from the document.');
    }
  }
}

ExecutionInstruction splitParagraphWhenEnterPressed({
  required EditContext editContext,
  required RawKeyEvent keyEvent,
}) {
  if (keyEvent.logicalKey != LogicalKeyboardKey.enter) {
    return ExecutionInstruction.continueExecution;
  }
  if (editContext.composer.selection == null) {
    return ExecutionInstruction.continueExecution;
  }
  if (!editContext.composer.selection!.isCollapsed) {
    return ExecutionInstruction.continueExecution;
  }

  final node = editContext.editor.document.getNodeById(editContext.composer.selection!.extent.nodeId);
  if (node is! ParagraphNode) {
    return ExecutionInstruction.continueExecution;
  }

  final newNodeId = DocumentEditor.createNodeId();

  editContext.editor.executeCommand(
    SplitParagraphCommand(
      nodeId: node.id,
      splitPosition: editContext.composer.selection!.extent.nodePosition as TextPosition,
      newNodeId: newNodeId,
    ),
  );

  // Place the caret at the beginning of the new paragraph node.
  editContext.composer.selection = DocumentSelection.collapsed(
    position: DocumentPosition(
      nodeId: newNodeId,
      nodePosition: TextPosition(offset: 0),
    ),
  );

  return ExecutionInstruction.haltExecution;
}

ExecutionInstruction deleteEmptyParagraphWhenBackspaceIsPressed({
  required EditContext editContext,
  required RawKeyEvent keyEvent,
}) {
  if (keyEvent.logicalKey != LogicalKeyboardKey.backspace) {
    return ExecutionInstruction.continueExecution;
  }
  if (editContext.composer.selection == null) {
    return ExecutionInstruction.continueExecution;
  }
  if (!editContext.composer.selection!.isCollapsed) {
    return ExecutionInstruction.continueExecution;
  }

  final node = editContext.editor.document.getNodeById(editContext.composer.selection!.extent.nodeId);
  if (node is! ParagraphNode) {
    return ExecutionInstruction.continueExecution;
  }

  if (node.text.text.isNotEmpty) {
    return ExecutionInstruction.continueExecution;
  }

  final nodeAbove = editContext.editor.document.getNodeBefore(node);
  if (nodeAbove == null) {
    return ExecutionInstruction.continueExecution;
  }
  final newDocumentPosition = DocumentPosition(
    nodeId: nodeAbove.id,
    nodePosition: nodeAbove.endPosition,
  );

  editContext.editor.executeCommand(
    DeleteParagraphsCommand(nodeId: node.id),
  );

  editContext.composer.selection = DocumentSelection.collapsed(
    position: newDocumentPosition,
  );

  return ExecutionInstruction.haltExecution;
}

ExecutionInstruction moveParagraphSelectionUpWhenBackspaceIsPressed({
  required EditContext editContext,
  required RawKeyEvent keyEvent,
}) {
  if (keyEvent.logicalKey != LogicalKeyboardKey.backspace) {
    return ExecutionInstruction.continueExecution;
  }
  if (editContext.composer.selection == null) {
    return ExecutionInstruction.continueExecution;
  }
  if (!editContext.composer.selection!.isCollapsed) {
    return ExecutionInstruction.continueExecution;
  }

  final node = editContext.editor.document.getNodeById(editContext.composer.selection!.extent.nodeId);
  if (node is! ParagraphNode) {
    return ExecutionInstruction.continueExecution;
  }

  if (node.text.text.isEmpty) {
    return ExecutionInstruction.continueExecution;
  }

  final nodeAbove = editContext.editor.document.getNodeBefore(node);
  if (nodeAbove == null) {
    return ExecutionInstruction.continueExecution;
  }
  final newDocumentPosition = DocumentPosition(
    nodeId: nodeAbove.id,
    nodePosition: nodeAbove.endPosition,
  );

  editContext.composer.selection = DocumentSelection.collapsed(
    position: newDocumentPosition,
  );

  return ExecutionInstruction.haltExecution;
}

Widget? paragraphBuilder(ComponentContext componentContext) {
  if (componentContext.documentNode is! ParagraphNode) {
    return null;
  }

  final textSelection =
      componentContext.nodeSelection == null || componentContext.nodeSelection!.nodeSelection is! TextSelection
          ? null
          : componentContext.nodeSelection!.nodeSelection as TextSelection;
  if (componentContext.nodeSelection != null && componentContext.nodeSelection!.nodeSelection is! TextSelection) {
    _log.log('paragraphBuilder',
        'ERROR: Building a paragraph component but the selection is not a TextSelection: ${componentContext.documentNode.id}');
  }
  final showCaret = componentContext.showCaret && componentContext.nodeSelection != null
      ? componentContext.nodeSelection!.isExtent
      : false;
  final highlightWhenEmpty =
      componentContext.nodeSelection == null ? false : componentContext.nodeSelection!.highlightWhenEmpty;

  _log.log('paragraphBuilder', ' - ${componentContext.documentNode.id}: ${componentContext.nodeSelection}');
  if (showCaret) {
    _log.log('paragraphBuilder', '   - ^ showing caret');
  }

  _log.log('paragraphBuilder', ' - building a paragraph with selection:');
  _log.log('paragraphBuilder', '   - base: ${textSelection?.base}');
  _log.log('paragraphBuilder', '   - extent: ${textSelection?.extent}');

  TextAlign textAlign = TextAlign.left;
  final textAlignName = (componentContext.documentNode as TextNode).metadata['textAlign'];
  switch (textAlignName) {
    case 'left':
      textAlign = TextAlign.left;
      break;
    case 'center':
      textAlign = TextAlign.center;
      break;
    case 'right':
      textAlign = TextAlign.right;
      break;
    case 'justify':
      textAlign = TextAlign.justify;
      break;
  }

  return TextComponent(
    key: componentContext.componentKey,
    text: (componentContext.documentNode as TextNode).text,
    textStyleBuilder: componentContext.extensions[textStylesExtensionKey],
    metadata: (componentContext.documentNode as TextNode).metadata,
    textAlign: textAlign,
    textSelection: textSelection,
    selectionColor: (componentContext.extensions[selectionStylesExtensionKey] as SelectionStyle).selectionColor,
    showCaret: showCaret,
    caretColor: (componentContext.extensions[selectionStylesExtensionKey] as SelectionStyle).textCaretColor,
    highlightWhenEmpty: highlightWhenEmpty,
  );
}
