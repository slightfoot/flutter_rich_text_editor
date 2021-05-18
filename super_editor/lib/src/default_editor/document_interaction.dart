import 'dart:math';
import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' hide SelectableText;
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:super_editor/src/core/document.dart';
import 'package:super_editor/src/core/document_layout.dart';
import 'package:super_editor/src/core/document_selection.dart';
import 'package:super_editor/src/core/edit_context.dart';
import 'package:super_editor/src/infrastructure/_logging.dart';
import 'package:super_editor/src/infrastructure/multi_tap_gesture.dart';
import 'package:super_editor/src/infrastructure/keyboard.dart' show PrimaryShortcutKey;

import 'text_tools.dart';

final _log = Logger(scope: 'document_interaction.dart');

/// Handles all keyboard and gesture input that is used to
/// interact with a given [document].
///
/// [DocumentInteractor] behaviors:
///  - executes [keyboardActions] when the user presses corresponding
///    keyboard keys.
///  - alters document selection on single, double, and triple taps
///  - alters document selection on drag, also account for single,
///    double, or triple taps to drag
///  - sets the cursor style based on hovering over text and other
///    components
///  - automatically scrolls up or down when the user drags near
///    a boundary
class DocumentInteractor extends StatefulWidget {
  const DocumentInteractor({
    Key? key,
    required this.editContext,
    required this.keyboardActions,
    this.scrollController,
    this.focusNode,
    required this.document,
    this.showDebugPaint = false,
  }) : super(key: key);

  /// Service locator for other editing components.
  final EditContext editContext;

  /// All the actions that the user can execute with keyboard keys.
  final List<DocumentKeyboardAction> keyboardActions;

  /// Controls the vertical scrolling of the given [document].
  ///
  /// If no `scrollController` is provided, then one is created
  /// internally.
  final ScrollController? scrollController;

  final FocusNode? focusNode;

  /// The document to display within this [DocumentInteractor].
  final Widget document;

  /// Paints some extra visual ornamentation to help with
  /// debugging, when true.
  final showDebugPaint;

  @override
  _DocumentInteractorState createState() => _DocumentInteractorState();
}

class _DocumentInteractorState extends State<DocumentInteractor> with SingleTickerProviderStateMixin {
  final _dragGutterExtent = 100;
  final _maxDragSpeed = 20;

  final _documentWrapperKey = GlobalKey();

  late FocusNode _focusNode;

  late ScrollController _scrollController;

  // Tracks user drag gestures for selection purposes.
  SelectionType _selectionType = SelectionType.position;
  Offset? _dragStartInViewport;
  Offset? _dragStartInDoc;
  Offset? _dragEndInViewport;
  Offset? _dragEndInDoc;
  Rect? _dragRectInViewport;

  bool _scrollUpOnTick = false;
  bool _scrollDownOnTick = false;
  late Ticker _ticker;

  // Determines the current mouse cursor style displayed on screen.
  final _cursorStyle = ValueNotifier<MouseCursor>(SystemMouseCursors.basic);

  @override
  void initState() {
    super.initState();
    _focusNode = widget.focusNode ?? FocusNode();
    _ticker = createTicker(_onTick);
    _scrollController =
        _scrollController = (widget.scrollController ?? ScrollController())..addListener(_updateDragSelection);

    widget.editContext.composer.addListener(_onSelectionChange);
  }

  @override
  void didUpdateWidget(DocumentInteractor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.editContext.composer != oldWidget.editContext.composer) {
      oldWidget.editContext.composer.removeListener(_onSelectionChange);
      widget.editContext.composer.addListener(_onSelectionChange);
    }
    if (widget.scrollController != oldWidget.scrollController) {
      _scrollController.removeListener(_updateDragSelection);
      if (oldWidget.scrollController == null) {
        _scrollController.dispose();
      }
      _scrollController = (widget.scrollController ?? ScrollController())..addListener(_updateDragSelection);
    }
    if (widget.focusNode != oldWidget.focusNode) {
      _focusNode = widget.focusNode ?? FocusNode();
    }
  }

  @override
  void dispose() {
    widget.editContext.composer.removeListener(_onSelectionChange);
    _ticker.dispose();
    if (widget.scrollController == null) {
      _scrollController.dispose();
    }
    if (widget.focusNode == null) {
      _focusNode.dispose();
    }
    super.dispose();
  }

  // DocumentLayout get _layout => widget.documentLayoutKey.currentState as DocumentLayout;
  DocumentLayout get _layout => widget.editContext.documentLayout;

  void _onSelectionChange() {
    _log.log('_onSelectionChange', 'EditableDocument: _onSelectionChange()');
    setState(() {
      _ensureSelectionExtentIsVisible();
      // Use a post-frame callback to "ensure selection extent is visible"
      // so that any pending visual document changes can happen before
      // attempting to calculate the visual position of the selection extent.
      WidgetsBinding.instance!.addPostFrameCallback((timeStamp) {
        _ensureSelectionExtentIsVisible();
      });
    });
  }

  void _ensureSelectionExtentIsVisible() {
    _log.log('_ensureSelectionExtentIsVisible', 'selection: ${widget.editContext.composer.selection}');
    final selection = widget.editContext.composer.selection;
    if (selection == null) {
      return;
    }

    // The reason that a Rect is used instead of an Offset is
    // because things like Images an Horizontal Rules don't have
    // a clear selection offset. They are either entirely selected,
    // or not selected at all.
    final extentRect = _layout.getRectForPosition(
      selection.extent,
    );
    if (extentRect == null) {
      _log.log('_ensureSelectionExtentIsVisible',
          'Tried to ensure that position ${selection.extent} is visible on screen but no bounding box was returned for that position.');
      return;
    }

    final myBox = context.findRenderObject() as RenderBox;
    final beyondTopExtent = min(extentRect.top - _scrollController.offset - _dragGutterExtent, 0).abs();
    final beyondBottomExtent =
        max(extentRect.bottom - myBox.size.height - _scrollController.offset + _dragGutterExtent, 0);

    _log.log('_ensureSelectionExtentIsVisible', 'Ensuring extent is visible.');
    _log.log('_ensureSelectionExtentIsVisible', ' - interaction size: ${myBox.size}');
    _log.log('_ensureSelectionExtentIsVisible', ' - scroll extent: ${_scrollController.offset}');
    _log.log('_ensureSelectionExtentIsVisible', ' - extent rect: $extentRect');
    _log.log('_ensureSelectionExtentIsVisible', ' - beyond top: $beyondTopExtent');
    _log.log('_ensureSelectionExtentIsVisible', ' - beyond bottom: $beyondBottomExtent');

    if (beyondTopExtent > 0) {
      final newScrollPosition =
          (_scrollController.offset - beyondTopExtent).clamp(0.0, _scrollController.position.maxScrollExtent);

      _scrollController.animateTo(
        newScrollPosition,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOut,
      );
    } else if (beyondBottomExtent > 0) {
      final newScrollPosition =
          (beyondBottomExtent + _scrollController.offset).clamp(0.0, _scrollController.position.maxScrollExtent);

      _scrollController.animateTo(
        newScrollPosition,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOut,
      );
    }
  }

  KeyEventResult _onKeyPressed(RawKeyEvent keyEvent) {
    _log.log('_onKeyPressed', 'keyEvent: ${keyEvent.character}');
    if (keyEvent is! RawKeyDownEvent) {
      _log.log('_onKeyPressed', ' - not a "down" event. Ignoring.');
      return KeyEventResult.handled;
    }

    ExecutionInstruction instruction = ExecutionInstruction.continueExecution;
    int index = 0;
    while (instruction == ExecutionInstruction.continueExecution && index < widget.keyboardActions.length) {
      instruction = widget.keyboardActions[index](
        editContext: widget.editContext,
        keyEvent: keyEvent,
      );
      index += 1;
    }

    return instruction == ExecutionInstruction.haltExecution ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  void _onTapDown(TapDownDetails details) {
    _log.log('_onTapDown', 'EditableDocument: onTapDown()');
    _clearSelection();
    _selectionType = SelectionType.position;

    final docOffset = _getDocOffset(details.localPosition);
    _log.log('_onTapDown', ' - document offset: $docOffset');
    final docPosition = _layout.getDocumentPositionAtOffset(docOffset);
    _log.log('_onTapDown', ' - tapped document position: $docPosition');

    if (docPosition != null) {
      // Place the document selection at the location where the
      // user tapped.
      _selectPosition(docPosition);
    }

    _focusNode.requestFocus();
  }

  void _onDoubleTapDown(TapDownDetails details) {
    _selectionType = SelectionType.word;

    _log.log('_onDoubleTapDown', 'EditableDocument: onDoubleTap()');
    _clearSelection();

    final docOffset = _getDocOffset(details.localPosition);
    final docPosition = _layout.getDocumentPositionAtOffset(docOffset);
    _log.log('_onDoubleTapDown', ' - tapped document position: $docPosition');

    if (docPosition != null) {
      final didSelectWord = _selectWordAt(
        docPosition: docPosition,
        docLayout: _layout,
      );
      if (!didSelectWord) {
        // Place the document selection at the location where the
        // user tapped.
        _selectPosition(docPosition);
      }
    }

    _focusNode.requestFocus();
  }

  void _onDoubleTap() {
    _selectionType = SelectionType.position;
  }

  void _onTripleTapDown(TapDownDetails details) {
    _selectionType = SelectionType.paragraph;

    _log.log('_onTripleTapDown', 'EditableDocument: onTripleTapDown()');
    _clearSelection();

    final docOffset = _getDocOffset(details.localPosition);
    final docPosition = _layout.getDocumentPositionAtOffset(docOffset);
    _log.log('_onTripleTapDown', ' - tapped document position: $docPosition');

    if (docPosition != null) {
      final didSelectParagraph = _selectParagraphAt(
        docPosition: docPosition,
        docLayout: _layout,
      );
      if (!didSelectParagraph) {
        // Place the document selection at the location where the
        // user tapped.
        _selectPosition(docPosition);
      }
    }

    _focusNode.requestFocus();
  }

  void _onTripleTap() {
    _selectionType = SelectionType.position;
  }

  void _onPanStart(DragStartDetails details) {
    _log.log('_onPanStart', '_onPanStart()');
    _dragStartInViewport = details.localPosition;
    _dragStartInDoc = _getDocOffset(_dragStartInViewport!);

    _clearSelection();
    _dragRectInViewport = Rect.fromLTWH(_dragStartInViewport!.dx, _dragStartInViewport!.dy, 1, 1);

    _focusNode.requestFocus();
  }

  void _onPanUpdate(DragUpdateDetails details) {
    _log.log('_onPanUpdate', '_onPanUpdate()');
    setState(() {
      _dragEndInViewport = details.localPosition;
      _dragEndInDoc = _getDocOffset(_dragEndInViewport!);
      _dragRectInViewport = Rect.fromPoints(_dragStartInViewport!, _dragEndInViewport!);
      _log.log('_onPanUpdate', ' - drag rect: $_dragRectInViewport');
      _updateCursorStyle(details.localPosition);
      _updateDragSelection();

      _scrollIfNearBoundary();
    });
  }

  void _onPanEnd(DragEndDetails details) {
    setState(() {
      _dragStartInDoc = null;
      _dragEndInDoc = null;
      _dragRectInViewport = null;
    });

    _stopScrollingUp();
    _stopScrollingDown();
  }

  void _onPanCancel() {
    setState(() {
      _dragStartInDoc = null;
      _dragEndInDoc = null;
      _dragRectInViewport = null;
    });

    _stopScrollingUp();
    _stopScrollingDown();
  }

  void _onMouseMove(PointerEvent pointerEvent) {
    _updateCursorStyle(pointerEvent.localPosition);
  }

  bool _selectWordAt({
    required DocumentPosition docPosition,
    required DocumentLayout docLayout,
  }) {
    final newSelection = getWordSelection(docPosition: docPosition, docLayout: docLayout);
    if (newSelection != null) {
      widget.editContext.composer.selection = newSelection;
      return true;
    } else {
      return false;
    }
  }

  bool _selectParagraphAt({
    required DocumentPosition docPosition,
    required DocumentLayout docLayout,
  }) {
    final newSelection = getParagraphSelection(docPosition: docPosition, docLayout: docLayout);
    if (newSelection != null) {
      widget.editContext.composer.selection = newSelection;
      return true;
    } else {
      return false;
    }
  }

  void _selectPosition(DocumentPosition position) {
    _log.log('_selectPosition', 'Setting document selection to $position');
    widget.editContext.composer.selection = DocumentSelection.collapsed(
      position: position,
    );
  }

  void _updateDragSelection() {
    if (_dragStartInDoc == null) {
      return;
    }

    _dragEndInDoc = _getDocOffset(_dragEndInViewport!);

    _selectRegion(
      documentLayout: _layout,
      baseOffset: _dragStartInDoc!,
      extentOffset: _dragEndInDoc!,
      selectionType: _selectionType,
    );
  }

  void _selectRegion({
    required DocumentLayout documentLayout,
    required Offset baseOffset,
    required Offset extentOffset,
    required SelectionType selectionType,
  }) {
    _log.log('_selectionRegion', 'Composer: selectionRegion(). Mode: $selectionType');
    DocumentSelection? selection = documentLayout.getDocumentSelectionInRegion(baseOffset, extentOffset);
    DocumentPosition? basePosition = selection?.base;
    DocumentPosition? extentPosition = selection?.extent;
    _log.log('_selectionRegion', ' - base: $basePosition, extent: $extentPosition');

    if (basePosition == null || extentPosition == null) {
      widget.editContext.composer.selection = null;
      return;
    }

    if (selectionType == SelectionType.paragraph) {
      final baseParagraphSelection = getParagraphSelection(
        docPosition: basePosition,
        docLayout: documentLayout,
      );
      if (baseParagraphSelection == null) {
        widget.editContext.composer.selection = null;
        return;
      }
      basePosition = baseOffset.dy < extentOffset.dy ? baseParagraphSelection.base : baseParagraphSelection.extent;

      final extentParagraphSelection = getParagraphSelection(
        docPosition: extentPosition,
        docLayout: documentLayout,
      );
      if (extentParagraphSelection == null) {
        widget.editContext.composer.selection = null;
        return;
      }
      extentPosition =
          baseOffset.dy < extentOffset.dy ? extentParagraphSelection.extent : extentParagraphSelection.base;
    } else if (selectionType == SelectionType.word) {
      _log.log('_selectionRegion', ' - selecting a word');
      final baseWordSelection = getWordSelection(
        docPosition: basePosition,
        docLayout: documentLayout,
      );
      if (baseWordSelection == null) {
        widget.editContext.composer.selection = null;
        return;
      }
      basePosition = baseWordSelection.base;

      final extentWordSelection = getWordSelection(
        docPosition: extentPosition,
        docLayout: documentLayout,
      );
      if (extentWordSelection == null) {
        widget.editContext.composer.selection = null;
        return;
      }
      extentPosition = extentWordSelection.extent;
    }

    widget.editContext.composer.selection = (DocumentSelection(
      base: basePosition,
      extent: extentPosition,
    ));
    _log.log('_selectionRegion', 'Region selection: ${widget.editContext.composer.selection}');
  }

  void _clearSelection() {
    widget.editContext.composer.clearSelection();
  }

  void _updateCursorStyle(Offset cursorOffset) {
    final docOffset = _getDocOffset(cursorOffset);
    final desiredCursor = _layout.getDesiredCursorAtOffset(docOffset);

    if (desiredCursor != null && desiredCursor != _cursorStyle.value) {
      _cursorStyle.value = desiredCursor;
    } else if (desiredCursor == null && _cursorStyle.value != SystemMouseCursors.basic) {
      _cursorStyle.value = SystemMouseCursors.basic;
    }
  }

  // Converts the given [offset] from the [DocumentInteractor]'s coordinate
  // space to the [DocumentLayout]'s coordinate space.
  Offset _getDocOffset(Offset offset) {
    return _layout.getDocumentOffsetFromAncestorOffset(offset, context.findRenderObject()!);
  }

  // ------ scrolling -------
  /// We prevent SingleChildScrollView from processing mouse events because
  /// it scrolls by drag by default, which we don't want. However, we do
  /// still want mouse scrolling. This method re-implements a primitive
  /// form of mouse scrolling.
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      final newScrollOffset =
          (_scrollController.offset + event.scrollDelta.dy).clamp(0.0, _scrollController.position.maxScrollExtent);
      _scrollController.jumpTo(newScrollOffset);

      _updateDragSelection();
    }
  }

  // Preconditions:
  // - _dragEndInViewport must be non-null
  void _scrollIfNearBoundary() {
    if (_dragEndInViewport == null) {
      _log.log('_scrollIfNearBoundary', "Can't scroll near boundary because _dragEndInViewport is null");
      assert(_dragEndInViewport != null);
      return;
    }

    final editorBox = context.findRenderObject() as RenderBox;

    if (_dragEndInViewport!.dy < _dragGutterExtent) {
      _startScrollingUp();
    } else {
      _stopScrollingUp();
    }
    if (editorBox.size.height - _dragEndInViewport!.dy < _dragGutterExtent) {
      _startScrollingDown();
    } else {
      _stopScrollingDown();
    }
  }

  void _startScrollingUp() {
    if (_scrollUpOnTick) {
      return;
    }

    _scrollUpOnTick = true;
    _ticker.start();
  }

  void _stopScrollingUp() {
    if (!_scrollUpOnTick) {
      return;
    }

    _scrollUpOnTick = false;
    _ticker.stop();
  }

  void _scrollUp() {
    if (_dragEndInViewport == null) {
      _log.log('_scrollUp', "Can't scroll up because _dragEndInViewport is null");
      assert(_dragEndInViewport != null);
      return;
    }

    if (_scrollController.offset <= 0) {
      return;
    }

    final gutterAmount = _dragEndInViewport!.dy.clamp(0.0, _dragGutterExtent);
    final speedPercent = 1.0 - (gutterAmount / _dragGutterExtent);
    final scrollAmount = lerpDouble(0, _maxDragSpeed, speedPercent);

    _scrollController.position.jumpTo(_scrollController.offset - scrollAmount!);
  }

  void _startScrollingDown() {
    if (_scrollDownOnTick) {
      return;
    }

    _scrollDownOnTick = true;
    _ticker.start();
  }

  void _stopScrollingDown() {
    if (!_scrollDownOnTick) {
      return;
    }

    _scrollDownOnTick = false;
    _ticker.stop();
  }

  void _scrollDown() {
    if (_dragEndInViewport == null) {
      _log.log('_scrollDown', "Can't scroll down because _dragEndInViewport is null");
      assert(_dragEndInViewport != null);
      return;
    }

    if (_scrollController.offset >= _scrollController.position.maxScrollExtent) {
      return;
    }

    final editorBox = context.findRenderObject() as RenderBox;
    final gutterAmount = (editorBox.size.height - _dragEndInViewport!.dy).clamp(0.0, _dragGutterExtent);
    final speedPercent = 1.0 - (gutterAmount / _dragGutterExtent);
    final scrollAmount = lerpDouble(0, _maxDragSpeed, speedPercent);

    _scrollController.position.jumpTo(_scrollController.offset + scrollAmount!);
  }

  void _onTick(elapsedTime) {
    if (_scrollUpOnTick) {
      _scrollUp();
    }
    if (_scrollDownOnTick) {
      _scrollDown();
    }
  }

  @override
  Widget build(BuildContext context) {
    return _buildSuppressUnhandledKeySound(
      child: _buildCursorStyle(
        child: _buildKeyboardAndMouseInput(
          child: SizedBox.expand(
            child: Stack(
              children: [
                _buildDocumentContainer(
                  document: widget.document,
                ),
                Positioned.fill(
                  child: widget.showDebugPaint ? _buildDragSelection() : SizedBox(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Wraps the [child] with a [Focus] node that reports to handle
  /// any and all keys so that no error sound plays on desktop.
  Widget _buildSuppressUnhandledKeySound({
    required Widget child,
  }) {
    return Focus(
      // The cmd+v and cntl+v paste key combos are allowed through this
      // net because on web those keys must be handled by the browser, itself,
      // to avoid a permissions issue with the clipboard.
      onKey: (node, event) => _isPasteCommand(event) ? KeyEventResult.ignored : KeyEventResult.handled,
      child: child,
    );
  }

  bool _isPasteCommand(RawKeyEvent event) {
    return event.isPrimaryShortcutKeyPressed && event.logicalKey == LogicalKeyboardKey.keyV;
  }

  Widget _buildCursorStyle({
    required Widget child,
  }) {
    return AnimatedBuilder(
      animation: _cursorStyle,
      builder: (context, child) {
        return Listener(
          onPointerHover: _onMouseMove,
          child: MouseRegion(
            cursor: _cursorStyle.value,
            child: child,
          ),
        );
      },
      child: child,
    );
  }

  Widget _buildKeyboardAndMouseInput({
    required Widget child,
  }) {
    return Listener(
      onPointerSignal: _onPointerSignal,
      child: RawKeyboardListener(
        focusNode: _focusNode,
        onKey: _onKeyPressed,
        autofocus: true,
        child: RawGestureDetector(
          behavior: HitTestBehavior.translucent,
          gestures: <Type, GestureRecognizerFactory>{
            TapSequenceGestureRecognizer: GestureRecognizerFactoryWithHandlers<TapSequenceGestureRecognizer>(
              () => TapSequenceGestureRecognizer(),
              (TapSequenceGestureRecognizer recognizer) {
                recognizer
                  ..onTapDown = _onTapDown
                  ..onDoubleTapDown = _onDoubleTapDown
                  ..onDoubleTap = _onDoubleTap
                  ..onTripleTapDown = _onTripleTapDown
                  ..onTripleTap = _onTripleTap;
              },
            ),
            PanGestureRecognizer: GestureRecognizerFactoryWithHandlers<PanGestureRecognizer>(
              () => PanGestureRecognizer(),
              (PanGestureRecognizer recognizer) {
                recognizer
                  ..onStart = _onPanStart
                  ..onUpdate = _onPanUpdate
                  ..onEnd = _onPanEnd
                  ..onCancel = _onPanCancel;
              },
            ),
          },
          child: child,
        ),
      ),
    );
  }

  Widget _buildDocumentContainer({
    required Widget document,
  }) {
    return SingleChildScrollView(
      controller: _scrollController,
      physics: NeverScrollableScrollPhysics(),
      child: Center(
        child: SizedBox(
          key: _documentWrapperKey,
          child: document,
        ),
      ),
    );
  }

  Widget _buildDragSelection() {
    return CustomPaint(
      painter: DragRectanglePainter(
        selectionRect: _dragRectInViewport,
      ),
      size: Size.infinite,
    );
  }
}

enum SelectionType {
  position,
  word,
  paragraph,
}

/// Executes this action, if the action wants to run, and returns
/// a desired `ExecutionInstruction` to either continue or halt
/// execution of actions.
///
/// It is possible that an action makes changes and then returns
/// `ExecutionInstruction.continueExecution` to continue execution.
///
/// It is possible that an action does nothing and then returns
/// `ExecutionInstruction.haltExecution` to prevent further execution.
typedef DocumentKeyboardAction = ExecutionInstruction Function({
  required EditContext editContext,
  required RawKeyEvent keyEvent,
});

enum ExecutionInstruction {
  continueExecution,
  haltExecution,
}

/// Paints a rectangle border around the given `selectionRect`.
class DragRectanglePainter extends CustomPainter {
  DragRectanglePainter({
    this.selectionRect,
    Listenable? repaint,
  }) : super(repaint: repaint);

  final Rect? selectionRect;
  final Paint _selectionPaint = Paint()
    ..color = Colors.red
    ..style = PaintingStyle.stroke;

  @override
  void paint(Canvas canvas, Size size) {
    if (selectionRect != null) {
      _log.log('paint', 'Painting drag rect: $selectionRect');
      canvas.drawRect(selectionRect!, _selectionPaint);
    }
  }

  @override
  bool shouldRepaint(DragRectanglePainter oldDelegate) {
    return oldDelegate.selectionRect != selectionRect;
  }
}
