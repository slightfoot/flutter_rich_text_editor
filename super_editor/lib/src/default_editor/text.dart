import 'dart:collection';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide SelectableText;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:super_editor/src/core/document.dart';
import 'package:super_editor/src/core/document_editor.dart';
import 'package:super_editor/src/core/document_layout.dart';
import 'package:super_editor/src/core/document_selection.dart';
import 'package:super_editor/src/core/edit_context.dart';
import 'package:super_editor/src/default_editor/document_interaction.dart';
import 'package:super_editor/src/infrastructure/_logging.dart';
import 'package:super_editor/src/infrastructure/attributed_spans.dart';
import 'package:super_editor/src/infrastructure/attributed_text.dart';
import 'package:super_editor/src/infrastructure/composable_text.dart';
import 'package:super_editor/src/infrastructure/keyboard.dart';
import 'package:super_editor/src/infrastructure/selectable_text.dart';
import 'package:super_editor/src/infrastructure/text_layout.dart';

import 'multi_node_editing.dart';

final _log = Logger(scope: 'text.dart');

class TextNode with ChangeNotifier implements DocumentNode {
  TextNode({
    required this.id,
    required AttributedText text,
    Map<String, dynamic>? metadata,
  })  : _text = text,
        _metadata = metadata ?? {} {
    _text.addListener(notifyListeners);
  }

  @override
  void dispose() {
    _text.removeListener(notifyListeners);
    super.dispose();
  }

  @override
  final String id;

  AttributedText _text;
  AttributedText get text => _text;
  set text(AttributedText newText) {
    if (newText != _text) {
      _log.log('set text', 'Text changed. Notifying listeners.');

      _text.removeListener(notifyListeners);
      _text = newText;
      _text.addListener(notifyListeners);

      notifyListeners();
    }
  }

  final Map<String, dynamic> _metadata;
  Map<String, dynamic> get metadata => _metadata;

  @override
  TextPosition get beginningPosition => TextPosition(offset: 0);

  @override
  TextPosition get endPosition => TextPosition(offset: text.text.length);

  @override
  TextSelection computeSelection({
    @required dynamic base,
    @required dynamic extent,
  }) {
    assert(base is TextPosition);
    assert(extent is TextPosition);

    return TextSelection(
      baseOffset: (base as TextPosition).offset,
      extentOffset: (extent as TextPosition).offset,
    );
  }

  @override
  String copyContent(dynamic selection) {
    assert(selection is TextSelection);

    return (selection as TextSelection).textInside(text.text);
  }
}

/// Displays text in a document.
///
/// This is the standard component for text display.
class TextComponent extends StatefulWidget {
  const TextComponent({
    Key? key,
    required this.text,
    this.textAlign,
    required this.textStyleBuilder,
    this.metadata = const {},
    this.textSelection,
    this.selectionColor = Colors.lightBlueAccent,
    this.showCaret = false,
    this.caretColor = Colors.black,
    this.highlightWhenEmpty = false,
    this.showDebugPaint = false,
  }) : super(key: key);

  final AttributedText text;
  final TextAlign? textAlign;
  final AttributionStyleBuilder textStyleBuilder;
  final Map<String, dynamic> metadata;
  final TextSelection? textSelection;
  final Color selectionColor;
  final bool showCaret;
  final Color caretColor;
  final bool highlightWhenEmpty;
  final bool showDebugPaint;

  @override
  _TextComponentState createState() => _TextComponentState();
}

class _TextComponentState extends State<TextComponent> with DocumentComponent implements TextComposable {
  final _selectableTextKey = GlobalKey<SelectableTextState>();

  @override
  TextPosition? getPositionAtOffset(Offset localOffset) {
    final textLayout = _selectableTextKey.currentState;
    return textLayout?.getPositionAtOffset(localOffset);
  }

  @override
  Offset getOffsetForPosition(dynamic nodePosition) {
    if (nodePosition is! TextPosition) {
      throw Exception('Expected nodePosition of type TextPosition but received: $nodePosition');
    }
    return _selectableTextKey.currentState!.getOffsetAtPosition(nodePosition);
  }

  @override
  Rect getRectForPosition(dynamic nodePosition) {
    if (nodePosition is! TextPosition) {
      throw Exception('Expected nodePosition of type TextPosition but received: $nodePosition');
    }

    // TODO: factor in line height for position rect
    final offset = getOffsetForPosition(nodePosition);
    return Rect.fromLTWH(offset.dx, offset.dy, 0, 0);
  }

  @override
  Rect getRectForSelection(dynamic baseNodePosition, dynamic extentNodePosition) {
    if (baseNodePosition is! TextPosition) {
      throw Exception('Expected nodePosition of type TextPosition but received: $baseNodePosition');
    }
    if (extentNodePosition is! TextPosition) {
      throw Exception('Expected nodePosition of type TextPosition but received: $extentNodePosition');
    }

    final selection = TextSelection(baseOffset: baseNodePosition.offset, extentOffset: extentNodePosition.offset);
    final boxes = _selectableTextKey.currentState!.getBoxesForSelection(selection);

    Rect boundingBox = boxes.isNotEmpty ? boxes.first.toRect() : Rect.zero;
    for (int i = 1; i < boxes.length; ++i) {
      boundingBox = boundingBox.expandToInclude(boxes[i].toRect());
    }

    return boundingBox;
  }

  @override
  TextPosition getBeginningPosition() {
    return TextPosition(offset: 0);
  }

  @override
  TextPosition getBeginningPositionNearX(double x) {
    return _selectableTextKey.currentState!.getPositionInFirstLineAtX(x);
  }

  @override
  TextPosition? movePositionLeft(dynamic textPosition, [Map<String, dynamic>? movementModifiers]) {
    if (textPosition is! TextPosition) {
      // We don't know how to interpret a non-text position.
      return null;
    }

    if (textPosition.offset > widget.text.text.length) {
      // This text position does not represent a position within our text.
      return null;
    }

    if (textPosition.offset == 0) {
      // Can't move any further left.
      return null;
    }

    if (movementModifiers?['movement_unit'] == 'line') {
      return getPositionAtStartOfLine(
        TextPosition(offset: textPosition.offset),
      );
    }

    if (movementModifiers?['movement_unit'] == 'word') {
      final text = getContiguousTextAt(textPosition);

      int newOffset = textPosition.offset;
      newOffset -= 1; // we always want to jump at least 1 character.
      while (newOffset > 0 && text[newOffset - 1] != ' ') {
        newOffset -= 1;
      }
      return TextPosition(offset: newOffset);
    }

    return TextPosition(offset: textPosition.offset - 1);
  }

  @override
  TextPosition? movePositionRight(dynamic textPosition, [Map<String, dynamic>? movementModifiers]) {
    if (textPosition is! TextPosition) {
      // We don't know how to interpret a non-text position.
      return null;
    }

    if (textPosition.offset >= widget.text.text.length) {
      // Can't move further right.
      return null;
    }

    if (movementModifiers?['movement_unit'] == 'line') {
      final endOfLine = getPositionAtEndOfLine(
        TextPosition(offset: textPosition.offset),
      );
      if (endOfLine == null) {
        _log.log('movePositionRight',
            'Tried to move text position right to end of line but getPositionAtEndOfLine() returned null');
        return null;
      }

      final TextPosition endPosition = getEndPosition();
      final text = getContiguousTextAt(endOfLine);

      // Note: we compare offset values because we don't care if the affinitys are equal
      final isAutoWrapLine = endOfLine.offset != endPosition.offset && (text[endOfLine.offset] != '\n');

      // Note: For lines that auto-wrap, moving the cursor to `offset` causes the
      //       cursor to jump to the next line because the cursor is placed after
      //       the final selected character. We don't want this, so in this case
      //       we `-1`.
      //
      //       However, if the line that is selected ends with an explicit `\n`,
      //       or if the line is the terminal line for the paragraph then we don't
      //       want to `-1` because that would leave a dangling character after the
      //       selection.
      // TODO: this is the concept of text affinity. Implement support for affinity.
      // TODO: with affinity, ensure it works as expected for right-aligned text
      // TODO: this logic fails for justified text - find a solution for that (#55)
      return isAutoWrapLine ? TextPosition(offset: endOfLine.offset - 1) : endOfLine;
    }

    if (movementModifiers?['movement_unit'] == 'word') {
      final text = getContiguousTextAt(textPosition);

      int newOffset = textPosition.offset;
      newOffset += 1; // we always want to jump at least 1 character.
      while (newOffset < text.length && text[newOffset] != ' ') {
        newOffset += 1;
      }
      return TextPosition(offset: newOffset);
    }

    return TextPosition(offset: textPosition.offset + 1);
  }

  @override
  TextPosition? movePositionUp(dynamic textPosition) {
    if (textPosition is! TextPosition) {
      // We don't know how to interpret a non-text position.
      return null;
    }

    if (textPosition.offset < 0 || textPosition.offset > widget.text.text.length) {
      // This text position does not represent a position within our text.
      return null;
    }

    return getPositionOneLineUp(textPosition);
  }

  @override
  TextPosition? movePositionDown(dynamic textPosition) {
    if (textPosition is! TextPosition) {
      // We don't know how to interpret a non-text position.
      return null;
    }

    if (textPosition.offset < 0 || textPosition.offset > widget.text.text.length) {
      // This text position does not represent a position within our text.
      return null;
    }

    return getPositionOneLineDown(textPosition);
  }

  @override
  TextPosition getEndPosition() {
    return TextPosition(offset: widget.text.text.length);
  }

  @override
  TextPosition getEndPositionNearX(double x) {
    return _selectableTextKey.currentState!.getPositionInLastLineAtX(x);
  }

  @override
  TextSelection getSelectionInRange(Offset localBaseOffset, Offset localExtentOffset) {
    return _selectableTextKey.currentState!.getSelectionInRect(localBaseOffset, localExtentOffset);
  }

  @override
  TextSelection? getCollapsedSelectionAt(dynamic textPosition) {
    if (textPosition is! TextPosition) {
      return null;
    }

    return TextSelection.fromPosition(textPosition);
  }

  @override
  TextSelection getSelectionBetween({
    required dynamic basePosition,
    required dynamic extentPosition,
  }) {
    if (basePosition is! TextPosition) {
      throw Exception('Expected a basePosition of type TextPosition but received: $basePosition');
    }
    if (extentPosition is! TextPosition) {
      throw Exception('Expected a extentPosition of type TextPosition but received: $extentPosition');
    }

    return TextSelection(
      baseOffset: basePosition.offset,
      extentOffset: extentPosition.offset,
    );
  }

  @override
  TextSelection getSelectionOfEverything() {
    return TextSelection(
      baseOffset: 0,
      extentOffset: widget.text.text.length,
    );
  }

  @override
  MouseCursor? getDesiredCursorAtOffset(Offset localOffset) {
    return _selectableTextKey.currentState!.isTextAtOffset(localOffset) ? SystemMouseCursors.text : null;
  }

  @override
  TextSelection getWordSelectionAt(dynamic textPosition) {
    if (textPosition is! TextPosition) {
      throw Exception('Expected a node position of type TextPosition but received: $textPosition');
    }

    return _selectableTextKey.currentState!.getWordSelectionAt(textPosition);
  }

  @override
  String getContiguousTextAt(dynamic textPosition) {
    if (textPosition is! TextPosition) {
      throw Exception('Expected a node position of type TextPosition but received: $textPosition');
    }

    // This component only displays a single contiguous span of text.
    // Therefore, all of our text is contiguous regardless of position.
    // TODO: This assumption isn't true in the case that multiline text
    //       is displayed within 1 node, such as when the user presses
    //       shift+enter. Change implementation to find actual contiguous
    //       text. (#54)
    return widget.text.text;
  }

  @override
  TextPosition? getPositionOneLineUp(dynamic textPosition) {
    if (textPosition is! TextPosition) {
      return null;
    }

    return _selectableTextKey.currentState!.getPositionOneLineUp(textPosition);
  }

  @override
  TextPosition? getPositionOneLineDown(dynamic textPosition) {
    if (textPosition is! TextPosition) {
      return null;
    }

    return _selectableTextKey.currentState!.getPositionOneLineDown(textPosition);
  }

  @override
  TextPosition? getPositionAtEndOfLine(dynamic textPosition) {
    if (textPosition is! TextPosition) {
      return null;
    }
    return _selectableTextKey.currentState!.getPositionAtEndOfLine(textPosition);
  }

  @override
  TextPosition? getPositionAtStartOfLine(dynamic textPosition) {
    if (textPosition is! TextPosition) {
      return null;
    }
    return _selectableTextKey.currentState!.getPositionAtStartOfLine(textPosition);
  }

  @override
  Widget build(BuildContext context) {
    _log.log('build', 'Building a TextComponent with key: ${widget.key}');

    Attribution? blockType = widget.metadata['blockType'];

    // Surround the text with block level attributions.
    final blockText = widget.text.copyText(0);
    if (blockType != null) {
      blockText.addAttribution(
        blockType,
        TextRange(start: 0, end: widget.text.text.length - 1),
      );
    }
    final richText = blockText.computeTextSpan(widget.textStyleBuilder);

    return SelectableText(
      key: _selectableTextKey,
      textSpan: richText,
      textAlign: widget.textAlign ?? TextAlign.left,
      textSelection: widget.textSelection ?? TextSelection.collapsed(offset: -1),
      textSelectionDecoration: TextSelectionDecoration(selectionColor: widget.selectionColor),
      showCaret: widget.showCaret,
      textCaretFactory: TextCaretFactory(color: widget.caretColor),
      highlightWhenEmpty: widget.highlightWhenEmpty,
    );
  }
}

/// Applies the given `attributions` to the given `documentSelection`,
/// if none of the content in the selection contains any of the
/// given `attributions`. Otherwise, all the given `attributions`
/// are removed from the content within the `documentSelection`.
class ToggleTextAttributionsCommand implements EditorCommand {
  ToggleTextAttributionsCommand({
    required this.documentSelection,
    required this.attributions,
  });

  final DocumentSelection documentSelection;
  final Set<Attribution> attributions;

  @override
  void execute(Document document, DocumentEditorTransaction transaction) {
    _log.log('ToggleTextAttributionsCommand', 'Executing ToggleTextAttributionsCommand');
    final nodes = document.getNodesInside(documentSelection.base, documentSelection.extent);
    if (nodes.isEmpty) {
      _log.log('ToggleTextAttributionsCommand',
          ' - Bad DocumentSelection. Could not get range of nodes. Selection: $documentSelection');
      return;
    }

    // Calculate a DocumentRange so we know which DocumentPosition
    // belongs to the first node, and which belongs to the last node.
    final nodeRange = document.getRangeBetween(documentSelection.base, documentSelection.extent);
    _log.log('ToggleTextAttributionsCommand', ' - node range: $nodeRange');

    final nodesAndSelections = LinkedHashMap<TextNode, TextRange>();
    bool alreadyHasAttributions = false;

    for (final textNode in nodes) {
      if (textNode is! TextNode) {
        continue;
      }

      int startOffset = -1;
      int endOffset = -1;

      if (textNode == nodes.first && textNode == nodes.last) {
        // Handle selection within a single node
        _log.log('ToggleTextAttributionsCommand', ' - the selection is within a single node: ${textNode.id}');
        final baseOffset = (documentSelection.base.nodePosition as TextPosition).offset;
        final extentOffset = (documentSelection.extent.nodePosition as TextPosition).offset;
        startOffset = baseOffset < extentOffset ? baseOffset : extentOffset;
        endOffset = baseOffset < extentOffset ? extentOffset : baseOffset;

        // -1 because TextPosition's offset indexes the character after the
        // selection, not the final character in the selection.
        endOffset -= 1;
      } else if (textNode == nodes.first) {
        // Handle partial node selection in first node.
        _log.log('ToggleTextAttributionsCommand', ' - selecting part of the first node: ${textNode.id}');
        startOffset = (nodeRange.start.nodePosition as TextPosition).offset;
        endOffset = max(textNode.text.text.length - 1, 0);
      } else if (textNode == nodes.last) {
        // Handle partial node selection in last node.
        _log.log('ToggleTextAttributionsCommand', ' - toggling part of the last node: ${textNode.id}');
        startOffset = 0;

        // -1 because TextPosition's offset indexes the character after the
        // selection, not the final character in the selection.
        endOffset = (nodeRange.end.nodePosition as TextPosition).offset - 1;
      } else {
        // Handle full node selection.
        _log.log('ToggleTextAttributionsCommand', ' - toggling full node: ${textNode.id}');
        startOffset = 0;
        endOffset = max(textNode.text.text.length - 1, 0);
      }

      final selectionRange = TextRange(start: startOffset, end: endOffset);

      alreadyHasAttributions = alreadyHasAttributions ||
          textNode.text.hasAttributionsWithin(
            attributions: attributions,
            range: selectionRange,
          );

      nodesAndSelections.putIfAbsent(textNode, () => selectionRange);
    }

    // Toggle attributions.
    for (final entry in nodesAndSelections.entries) {
      for (Attribution attribution in attributions) {
        final node = entry.key;
        final range = entry.value;
        _log.log('ToggleTextAttributionsCommand', ' - toggling attribution: $attribution. Range: $range');
        node.text.toggleAttribution(
          attribution,
          range,
        );
      }
    }

    _log.log('ToggleTextAttributionsCommand', ' - done toggling attributions');
  }
}

class InsertTextCommand implements EditorCommand {
  InsertTextCommand({
    required this.documentPosition,
    required this.textToInsert,
    required this.attributions,
  }) : assert(documentPosition.nodePosition is TextPosition);

  final DocumentPosition documentPosition;
  final String textToInsert;
  final Set<Attribution> attributions;

  @override
  void execute(Document document, DocumentEditorTransaction transaction) {
    final textNode = document.getNodeById(documentPosition.nodeId);
    if (textNode is! TextNode) {
      _log.log('InsertTextCommand', 'ERROR: can\'t insert text in a node that isn\'t a TextNode: $textNode');
      return;
    }

    final textOffset = (documentPosition.nodePosition as TextPosition).offset;
    textNode.text = textNode.text.insertString(
      textToInsert: textToInsert,
      startOffset: textOffset,
      applyAttributions: attributions,
    );
  }
}

ExecutionInstruction insertCharacterInTextComposable({
  required EditContext editContext,
  required RawKeyEvent keyEvent,
}) {
  if (keyEvent.isMetaPressed || keyEvent.isControlPressed) {
    return ExecutionInstruction.continueExecution;
  }

  if (editContext.composer.selection == null) {
    return ExecutionInstruction.continueExecution;
  }
  if (!editContext.composer.selection!.isCollapsed) {
    return ExecutionInstruction.continueExecution;
  }
  if (!_isTextEntryNode(document: editContext.editor.document, selection: editContext.composer.selection!)) {
    return ExecutionInstruction.continueExecution;
  }
  if (keyEvent.character == null ||
      keyEvent.character == '' ||
      webBugBlacklistCharacters.contains(keyEvent.character)) {
    return ExecutionInstruction.continueExecution;
  }
  print('Inserting character in TextComposable');

  String character = keyEvent.character!;

  // On web, keys like shift and alt are sending their full name
  // as a character, e.g., "Shift" and "Alt". This check prevents
  // those keys from inserting their name into content.
  //
  // This filter is a blacklist, and therefore it will fail to
  // catch any key that isn't explicitly listed. The eventual solution
  // to this is for the web to honor the standard key event contract,
  // but that's out of our control.
  if (kIsWeb && webBugBlacklistCharacters.contains(character)) {
    return ExecutionInstruction.continueExecution;
  }

  // The web reports a tab as "Tab". Intercept it and translate it to a space.
  if (character == 'Tab') {
    character = ' ';
  }

  final textNode = editContext.editor.document.getNode(editContext.composer.selection!.extent) as TextNode;
  final initialTextOffset = (editContext.composer.selection!.extent.nodePosition as TextPosition).offset;

  editContext.editor.executeCommand(
    InsertTextCommand(
      documentPosition: editContext.composer.selection!.extent,
      textToInsert: character,
      attributions: editContext.composer.preferences.currentStyles,
    ),
  );

  editContext.composer.selection = DocumentSelection.collapsed(
    position: DocumentPosition(
      nodeId: textNode.id,
      nodePosition: TextPosition(
        offset: initialTextOffset + character.length,
      ),
    ),
  );

  return ExecutionInstruction.haltExecution;
}

ExecutionInstruction deleteCharacterWhenBackspaceIsPressed({
  required EditContext editContext,
  required RawKeyEvent keyEvent,
}) {
  if (keyEvent.logicalKey != LogicalKeyboardKey.backspace) {
    return ExecutionInstruction.continueExecution;
  }
  if (editContext.composer.selection == null) {
    return ExecutionInstruction.continueExecution;
  }
  if (!_isTextEntryNode(document: editContext.editor.document, selection: editContext.composer.selection!)) {
    return ExecutionInstruction.continueExecution;
  }
  if (!editContext.composer.selection!.isCollapsed) {
    return ExecutionInstruction.continueExecution;
  }
  if ((editContext.composer.selection!.extent.nodePosition as TextPosition).offset <= 0) {
    return ExecutionInstruction.continueExecution;
  }

  final textNode = editContext.editor.document.getNode(editContext.composer.selection!.extent) as TextNode;
  final currentTextPosition = editContext.composer.selection!.extent.nodePosition as TextPosition;

  final previousCharacterOffset = getCharacterStartBounds(textNode.text.text, currentTextPosition.offset);

  final newSelectionPosition = DocumentPosition(
    nodeId: textNode.id,
    nodePosition: TextPosition(offset: previousCharacterOffset),
  );

  // Delete the selected content.
  editContext.editor.executeCommand(
    DeleteSelectionCommand(
      documentSelection: DocumentSelection(
        base: DocumentPosition(
          nodeId: textNode.id,
          nodePosition: currentTextPosition,
        ),
        extent: DocumentPosition(
          nodeId: textNode.id,
          nodePosition: TextPosition(offset: previousCharacterOffset),
        ),
      ),
    ),
  );

  _log.log('deleteCharacterWhenBackspaceIsPressed',
      ' - new document selection position: ${newSelectionPosition.nodePosition}');
  editContext.composer.selection = DocumentSelection.collapsed(position: newSelectionPosition);

  return ExecutionInstruction.haltExecution;
}

ExecutionInstruction deleteCharacterWhenDeleteIsPressed({
  required EditContext editContext,
  required RawKeyEvent keyEvent,
}) {
  if (keyEvent.logicalKey != LogicalKeyboardKey.delete) {
    return ExecutionInstruction.continueExecution;
  }

  if (editContext.composer.selection == null) {
    return ExecutionInstruction.continueExecution;
  }
  if (!_isTextEntryNode(document: editContext.editor.document, selection: editContext.composer.selection!)) {
    return ExecutionInstruction.continueExecution;
  }
  if (!editContext.composer.selection!.isCollapsed) {
    return ExecutionInstruction.continueExecution;
  }
  final textNode = editContext.editor.document.getNode(editContext.composer.selection!.extent) as TextNode;
  final text = textNode.text;
  final currentTextPosition = (editContext.composer.selection!.extent.nodePosition as TextPosition);
  if (currentTextPosition.offset >= text.text.length) {
    return ExecutionInstruction.continueExecution;
  }

  final nextCharacterOffset = getCharacterEndBounds(text.text, currentTextPosition.offset + 1);

  // Delete the selected content.
  editContext.editor.executeCommand(
    DeleteSelectionCommand(
      documentSelection: DocumentSelection(
        base: DocumentPosition(
          nodeId: textNode.id,
          nodePosition: currentTextPosition,
        ),
        extent: DocumentPosition(
          nodeId: textNode.id,
          nodePosition: TextPosition(offset: nextCharacterOffset),
        ),
      ),
    ),
  );

  return ExecutionInstruction.haltExecution;
}

ExecutionInstruction insertNewlineInParagraph({
  required EditContext editContext,
  required RawKeyEvent keyEvent,
}) {
  if (editContext.composer.selection == null) {
    return ExecutionInstruction.continueExecution;
  }

  if (!_isTextEntryNode(document: editContext.editor.document, selection: editContext.composer.selection!)) {
    return ExecutionInstruction.continueExecution;
  }
  if (keyEvent.logicalKey != LogicalKeyboardKey.enter) {
    return ExecutionInstruction.continueExecution;
  }
  if (!keyEvent.isShiftPressed) {
    return ExecutionInstruction.continueExecution;
  }
  if (!editContext.composer.selection!.isCollapsed) {
    return ExecutionInstruction.continueExecution;
  }

  final textNode = editContext.editor.document.getNode(editContext.composer.selection!.extent) as TextNode;
  final initialTextOffset = (editContext.composer.selection!.extent.nodePosition as TextPosition).offset;

  editContext.editor.executeCommand(
    InsertTextCommand(
      documentPosition: editContext.composer.selection!.extent,
      textToInsert: '\n',
      attributions: editContext.composer.preferences.currentStyles,
    ),
  );

  editContext.composer.selection = DocumentSelection.collapsed(
    position: DocumentPosition(
      nodeId: textNode.id,
      nodePosition: TextPosition(
        offset: initialTextOffset + 1,
      ),
    ),
  );

  return ExecutionInstruction.haltExecution;
}

bool _isTextEntryNode({
  required Document document,
  required DocumentSelection selection,
}) {
  final extentPosition = selection.extent;
  final extentNode = document.getNodeById(extentPosition.nodeId);
  return extentNode is TextNode;
}
