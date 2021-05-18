import 'dart:math';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' hide SelectableText;
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:super_editor/src/default_editor/editor.dart';
import 'package:super_editor/src/infrastructure/_listenable_builder.dart';
import 'package:super_editor/src/infrastructure/_logging.dart';
import 'package:super_editor/src/infrastructure/selectable_text.dart';
import 'package:super_editor/src/infrastructure/text_layout.dart';

import '_paste_event_handler_interface.dart';
import 'attributed_text.dart';
import 'keyboard.dart';
import 'multi_tap_gesture.dart';

final _log = Logger(scope: 'super_textfield.dart');

/// Highly configurable textfield intended for web and desktop uses.
///
/// [SuperTextField] provides two advantages over a typical [TextField].
/// First, [SuperTextField] is based on [AttributedText], which is a far
/// more useful foundation for styled text display than [TextSpan]. Second,
/// [SuperTextField] provides deeper control over various visual properties
/// including selection painting, caret painting, hint display, and keyboard
/// interaction.
///
/// If [SuperTextField] does not provide the desired level of configuration,
/// look at its implementation. Unlike Flutter's [TextField], [SuperTextField]
/// is composed of a few widgets that you can recompose to create your own
/// flavor of a text field.
class SuperTextField extends StatefulWidget {
  const SuperTextField({
    Key? key,
    this.focusNode,
    this.textController,
    this.textStyleBuilder = defaultStyleBuilder,
    this.textAlign = TextAlign.left,
    this.textSelectionDecoration = const TextSelectionDecoration(
      selectionColor: Color(0xFFACCEF7),
    ),
    this.textCaretFactory = const TextCaretFactory(
      color: Colors.black,
      width: 1,
      borderRadius: BorderRadius.zero,
    ),
    this.padding = EdgeInsets.zero,
    this.minLines,
    this.maxLines = 1,
    this.decorationBuilder,
    this.hintBuilder,
    this.hintBehavior = HintBehavior.displayHintUntilFocus,
    this.onRightClick,
    this.keyboardHandlers = defaultTextFieldKeyboardHandlers,
  }) : super(key: key);

  final FocusNode? focusNode;

  final AttributedTextEditingController? textController;

  final AttributionStyleBuilder textStyleBuilder;

  /// The alignment to use for `richText` display.
  final TextAlign textAlign;

  /// The visual decoration to apply to the `textSelection`.
  final TextSelectionDecoration textSelectionDecoration;

  /// Builds the visual representation of the caret in this
  /// `SelectableText` widget.
  final TextCaretFactory textCaretFactory;

  final EdgeInsetsGeometry padding;

  final int? minLines;
  final int? maxLines;

  final DecorationBuilder? decorationBuilder;

  final WidgetBuilder? hintBuilder;
  final HintBehavior hintBehavior;

  final RightClickListener? onRightClick;

  final List<TextFieldKeyboardHandler> keyboardHandlers;

  @override
  SuperTextFieldState createState() => SuperTextFieldState();
}

class SuperTextFieldState extends State<SuperTextField> {
  final _selectableTextKey = GlobalKey<SelectableTextState>();
  final _textScrollKey = GlobalKey<SuperTextFieldScrollviewState>();
  late FocusNode _focusNode;
  bool _hasFocus = false; // cache whether we have focus so we know when it changes

  late AttributedTextEditingController _controller;
  late ScrollController _scrollController;

  double? _viewportHeight;

  PasteEventHandler? _webPasteEventHandler;

  @override
  void initState() {
    super.initState();

    _focusNode = (widget.focusNode ?? FocusNode())..addListener(_onFocusChange);
    _hasFocus = _focusNode.hasFocus;
    if (_hasFocus) {
      _startListeningForWebPasteEvents();
    }

    _controller = (widget.textController ?? AttributedTextEditingController())
      ..addListener(_onSelectionOrContentChange);
    _scrollController = ScrollController();
  }

  @override
  void didUpdateWidget(SuperTextField oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.focusNode != oldWidget.focusNode) {
      _focusNode.removeListener(_onFocusChange);
      if (oldWidget.focusNode == null) {
        _focusNode.dispose();
      }
      _focusNode = (widget.focusNode ?? FocusNode())..addListener(_onFocusChange);
      _hasFocus = _focusNode.hasFocus;
    }

    if (widget.textController != oldWidget.textController) {
      _controller.removeListener(_onSelectionOrContentChange);
      if (oldWidget.textController == null) {
        _controller.dispose();
      }
      _controller = (widget.textController ?? AttributedTextEditingController())
        ..addListener(_onSelectionOrContentChange);
    }

    if (widget.padding != oldWidget.padding ||
        widget.minLines != oldWidget.minLines ||
        widget.maxLines != oldWidget.maxLines) {
      _onSelectionOrContentChange();
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _focusNode.removeListener(_onFocusChange);
    if (widget.focusNode == null) {
      _focusNode.dispose();
    }
    _controller.removeListener(_onSelectionOrContentChange);
    if (widget.textController == null) {
      _controller.dispose();
    }

    super.dispose();
  }

  void _onFocusChange() {
    // If our FocusNode just received focus, automatically set our
    // controller's text position to the end of the available content.
    //
    // This behavior matches Flutter's standard behavior.
    if (_focusNode.hasFocus && !_hasFocus && _controller.selection.extentOffset == -1) {
      _controller.selection = TextSelection.collapsed(offset: _controller.text.text.length);
    }
    _hasFocus = _focusNode.hasFocus;

    if (_hasFocus) {
      _startListeningForWebPasteEvents();
    } else {
      _stopListeningForWebPasteEvents();
    }
  }

  void _startListeningForWebPasteEvents() {
    print('Listening for paste events');
    _webPasteEventHandler = createPlatformPasteEventHandler(_pasteContent);
  }

  void _pasteContent(String content) {
    print('Inserting clipboard text: $content');
    _controller
      ..deleteSelectedText()
      ..insertTextAtCaret(content);
  }

  void _stopListeningForWebPasteEvents() {
    print('Stopping listening for paste events');
    _webPasteEventHandler?.dispose();
  }

  void _onSelectionOrContentChange() {
    // Use a post-frame callback to "ensure selection extent is visible"
    // so that any pending visual content changes can happen before
    // attempting to calculate the visual position of the selection extent.
    WidgetsBinding.instance!.addPostFrameCallback((timeStamp) {
      if (mounted) {
        _updateViewportHeight();
      }
    });
  }

  /// Returns true if the viewport height changed, false otherwise.
  bool _updateViewportHeight() {
    final estimatedLineHeight = _getEstimatedLineHeight();
    final estimatedLinesOfText = _getEstimatedLinesOfText();
    final estimatedContentHeight = estimatedLinesOfText * estimatedLineHeight;
    final minHeight = widget.minLines != null ? widget.minLines! * estimatedLineHeight + widget.padding.vertical : null;
    final maxHeight = widget.maxLines != null ? widget.maxLines! * estimatedLineHeight + widget.padding.vertical : null;
    double? viewportHeight;
    if (maxHeight != null && estimatedContentHeight > maxHeight) {
      viewportHeight = maxHeight;
    } else if (minHeight != null && estimatedContentHeight < minHeight) {
      viewportHeight = minHeight;
    }

    if (viewportHeight == _viewportHeight) {
      // The height of the viewport hasn't changed. Return.
      return false;
    }

    setState(() {
      _viewportHeight = viewportHeight;
    });

    return true;
  }

  int _getEstimatedLinesOfText() {
    if (_controller.text.text.isEmpty) {
      return 0;
    }

    if (_selectableTextKey.currentState == null) {
      return 0;
    }

    final offsetAtEndOfText =
        _selectableTextKey.currentState!.getOffsetAtPosition(TextPosition(offset: _controller.text.text.length));
    int lineCount = (offsetAtEndOfText.dy / _getEstimatedLineHeight()).ceil();

    if (_controller.text.text.endsWith('\n')) {
      lineCount += 1;
    }

    return lineCount;
  }

  double _getEstimatedLineHeight() {
    final defaultStyle = widget.textStyleBuilder({});
    return (defaultStyle.height ?? 1.0) * defaultStyle.fontSize!;
  }

  @override
  Widget build(BuildContext context) {
    if (_selectableTextKey.currentContext == null) {
      // The text hasn't been laid out yet, which means our calculations
      // for text height is probably wrong. Schedule a post frame callback
      // to re-calculate the height after initial layout.
      WidgetsBinding.instance!.addPostFrameCallback((timeStamp) {
        if (mounted) {
          setState(() {
            _updateViewportHeight();
          });
        }
      });
    }

    final isMultiline = widget.minLines != 1 || widget.maxLines != 1;

    return SuperTextFieldKeyboardInteractor(
      focusNode: _focusNode,
      textController: _controller,
      textKey: _selectableTextKey,
      keyboardActions: widget.keyboardHandlers,
      child: SuperTextFieldGestureInteractor(
        focusNode: _focusNode,
        textController: _controller,
        textKey: _selectableTextKey,
        textScrollKey: _textScrollKey,
        isMultiline: isMultiline,
        onRightClick: widget.onRightClick,
        child: MultiListenableBuilder(
          listenables: {
            _focusNode,
            _controller,
          },
          builder: (context) {
            final isTextEmpty = _controller.text.text.isEmpty;
            final showHint = widget.hintBuilder != null &&
                ((isTextEmpty && widget.hintBehavior == HintBehavior.displayHintUntilTextEntered) ||
                    (isTextEmpty && !_focusNode.hasFocus && widget.hintBehavior == HintBehavior.displayHintUntilFocus));

            return _buildDecoration(
              child: SuperTextFieldScrollview(
                key: _textScrollKey,
                textKey: _selectableTextKey,
                textController: _controller,
                scrollController: _scrollController,
                viewportHeight: _viewportHeight,
                estimatedLineHeight: _getEstimatedLineHeight(),
                padding: widget.padding,
                isMultiline: isMultiline,
                child: Stack(
                  children: [
                    if (showHint) widget.hintBuilder!(context),
                    _buildSelectableText(),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildDecoration({
    required Widget child,
  }) {
    return widget.decorationBuilder != null ? widget.decorationBuilder!(context, child) : child;
  }

  Widget _buildSelectableText() {
    return SelectableText(
      key: _selectableTextKey,
      textSpan: _controller.text.computeTextSpan(widget.textStyleBuilder),
      textAlign: widget.textAlign,
      textSelection: _controller.selection,
      textSelectionDecoration: widget.textSelectionDecoration,
      showCaret: _focusNode.hasFocus,
      textCaretFactory: widget.textCaretFactory,
    );
  }
}

typedef DecorationBuilder = Widget Function(BuildContext, Widget child);

enum HintBehavior {
  /// Display a hint when the text field is empty until
  /// the text field receives focus, then hide the hint.
  displayHintUntilFocus,

  /// Display a hint when the text field is empty until
  /// at least 1 character is entered into the text field.
  displayHintUntilTextEntered,

  /// Do not display a hint.
  noHint,
}

/// Handles all user gesture interactions for text entry.
///
/// [SuperTextFieldGestureInteractor] is intended to operate as a piece within
/// a larger composition that behaves as a text field. [SuperTextFieldGestureInteractor]
/// is defined on its own so that it can be replaced with a widget that handles
/// gestures differently.
///
/// The gestures are applied to a [SelectableText] widget that is
/// tied to [textKey].
///
/// A [SuperTextFieldScrollview] must sit between this [SuperTextFieldGestureInteractor]
/// and the underlying [SelectableText]. That [SuperTextFieldScrollview] must
/// be tied to [textScrollKey].
class SuperTextFieldGestureInteractor extends StatefulWidget {
  const SuperTextFieldGestureInteractor({
    Key? key,
    required this.focusNode,
    required this.textController,
    required this.textKey,
    required this.textScrollKey,
    required this.isMultiline,
    this.onRightClick,
    required this.child,
  }) : super(key: key);

  /// [FocusNode] for this text field.
  final FocusNode focusNode;

  /// [TextController] for the text/selection within this text field.
  final AttributedTextEditingController textController;

  /// [GlobalKey] that links this [SuperTextFieldGestureInteractor] to
  /// the [SelectableText] widget that paints the text for this text field.
  final GlobalKey<SelectableTextState> textKey;

  /// [GlobalKey] that links this [SuperTextFieldGestureInteractor] to
  /// the [SuperTextFieldScrollview] that's responsible for scrolling
  /// content that exceeds the available space within this text field.
  final GlobalKey<SuperTextFieldScrollviewState> textScrollKey;

  /// Whether or not this text field supports multiple lines of text.
  final bool isMultiline;

  /// Callback invoked when the user right clicks on this text field.
  final RightClickListener? onRightClick;

  /// The rest of the subtree for this text field.
  final Widget child;

  @override
  _SuperTextFieldGestureInteractorState createState() => _SuperTextFieldGestureInteractorState();
}

class _SuperTextFieldGestureInteractorState extends State<SuperTextFieldGestureInteractor> {
  final _cursorStyle = ValueNotifier<MouseCursor>(SystemMouseCursors.basic);

  _SelectionType _selectionType = _SelectionType.position;
  Offset? _dragStartInViewport;
  Offset? _dragStartInText;
  Offset? _dragEndInViewport;
  Offset? _dragEndInText;
  Rect? _dragRectInViewport;

  final _dragGutterExtent = 24;
  final _maxDragSpeed = 20;

  SelectableTextState get _text => widget.textKey.currentState!;

  SuperTextFieldScrollviewState get _textScroll => widget.textScrollKey.currentState!;

  void _onTapDown(TapDownDetails details) {
    _log.log('_onTapDown', 'EditableDocument: onTapDown()');
    _selectionType = _SelectionType.position;

    final textOffset = _getTextOffset(details.localPosition);
    final tapTextPosition = _getPositionNearestToTextOffset(textOffset);

    final expandSelection = RawKeyboard.instance.keysPressed.contains(LogicalKeyboardKey.shiftLeft) ||
        RawKeyboard.instance.keysPressed.contains(LogicalKeyboardKey.shiftRight) ||
        RawKeyboard.instance.keysPressed.contains(LogicalKeyboardKey.shift);

    setState(() {
      widget.textController.selection = expandSelection
          ? TextSelection(
              baseOffset: widget.textController.selection.baseOffset,
              extentOffset: tapTextPosition.offset,
            )
          : TextSelection.collapsed(offset: tapTextPosition.offset);
    });

    widget.focusNode.requestFocus();
  }

  void _onDoubleTapDown(TapDownDetails details) {
    _selectionType = _SelectionType.word;

    _log.log('_onDoubleTapDown', 'EditableDocument: onDoubleTap()');

    final tapTextPosition = _getPositionAtOffset(details.localPosition);

    if (tapTextPosition != null) {
      setState(() {
        widget.textController.selection = _text.getWordSelectionAt(tapTextPosition);
      });
    } else {
      _clearSelection();
    }

    widget.focusNode.requestFocus();
  }

  void _onDoubleTap() {
    _selectionType = _SelectionType.position;
  }

  void _onTripleTapDown(TapDownDetails details) {
    _selectionType = _SelectionType.paragraph;

    _log.log('_onTripleTapDown', 'EditableDocument: onTripleTapDown()');

    final tapTextPosition = _getPositionAtOffset(details.localPosition);

    if (tapTextPosition != null) {
      setState(() {
        widget.textController.selection = _getParagraphSelectionAt(tapTextPosition, TextAffinity.downstream);
      });
    } else {
      _clearSelection();
    }

    widget.focusNode.requestFocus();
  }

  void _onTripleTap() {
    _selectionType = _SelectionType.position;
  }

  void _onRightClick(TapUpDetails details) {
    widget.onRightClick?.call(context, widget.textController, details.localPosition);
  }

  void _onPanStart(DragStartDetails details) {
    _log.log('_onPanStart', '_onPanStart()');
    _dragStartInViewport = details.localPosition;
    _dragStartInText = _getTextOffset(_dragStartInViewport!);

    _dragRectInViewport = Rect.fromLTWH(_dragStartInViewport!.dx, _dragStartInViewport!.dy, 1, 1);

    widget.focusNode.requestFocus();
  }

  void _onPanUpdate(DragUpdateDetails details) {
    _log.log('_onPanUpdate', '_onPanUpdate()');
    setState(() {
      _dragEndInViewport = details.localPosition;
      _dragEndInText = _getTextOffset(_dragEndInViewport!);
      _dragRectInViewport = Rect.fromPoints(_dragStartInViewport!, _dragEndInViewport!);
      _log.log('_onPanUpdate', ' - drag rect: $_dragRectInViewport');
      _updateCursorStyle(details.localPosition);
      _updateDragSelection();

      _scrollIfNearBoundary();
    });
  }

  void _onPanEnd(DragEndDetails details) {
    setState(() {
      _dragStartInText = null;
      _dragEndInText = null;
      _dragRectInViewport = null;
    });

    _textScroll._stopScrollingToStart();
    _textScroll._stopScrollingToEnd();
  }

  void _onPanCancel() {
    setState(() {
      _dragStartInText = null;
      _dragEndInText = null;
      _dragRectInViewport = null;
    });

    _textScroll._stopScrollingToStart();
    _textScroll._stopScrollingToEnd();
  }

  void _updateDragSelection() {
    if (_dragStartInText == null || _dragEndInText == null) {
      return;
    }

    setState(() {
      final startDragOffset = _getPositionNearestToTextOffset(_dragStartInText!).offset;
      final endDragOffset = _getPositionNearestToTextOffset(_dragEndInText!).offset;
      final affinity = startDragOffset <= endDragOffset ? TextAffinity.downstream : TextAffinity.upstream;

      if (_selectionType == _SelectionType.paragraph) {
        final baseParagraphSelection = _getParagraphSelectionAt(TextPosition(offset: startDragOffset), affinity);
        final extentParagraphSelection = _getParagraphSelectionAt(TextPosition(offset: endDragOffset), affinity);

        widget.textController.selection = _combineSelections(
          baseParagraphSelection,
          extentParagraphSelection,
          affinity,
        );
      } else if (_selectionType == _SelectionType.word) {
        final baseParagraphSelection = _text.getWordSelectionAt(TextPosition(offset: startDragOffset));
        final extentParagraphSelection = _text.getWordSelectionAt(TextPosition(offset: endDragOffset));

        widget.textController.selection = _combineSelections(
          baseParagraphSelection,
          extentParagraphSelection,
          affinity,
        );
      } else {
        widget.textController.selection = TextSelection(
          baseOffset: startDragOffset,
          extentOffset: endDragOffset,
        );
      }
    });
  }

  TextSelection _combineSelections(
    TextSelection selection1,
    TextSelection selection2,
    TextAffinity affinity,
  ) {
    return affinity == TextAffinity.downstream
        ? TextSelection(
            baseOffset: min(selection1.start, selection2.start),
            extentOffset: max(selection1.end, selection2.end),
          )
        : TextSelection(
            baseOffset: max(selection1.end, selection2.end),
            extentOffset: min(selection1.start, selection2.start),
          );
  }

  void _clearSelection() {
    setState(() {
      widget.textController.selection = TextSelection.collapsed(offset: -1);
    });
  }

  void _onMouseMove(PointerEvent pointerEvent) {
    _updateCursorStyle(pointerEvent.localPosition);
  }

  /// We prevent SingleChildScrollView from processing mouse events because
  /// it scrolls by drag by default, which we don't want. However, we do
  /// still want mouse scrolling. This method re-implements a primitive
  /// form of mouse scrolling.
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      // TODO: remove access to _textScroll.widget
      final newScrollOffset = (_textScroll.widget.scrollController.offset + event.scrollDelta.dy)
          .clamp(0.0, _textScroll.widget.scrollController.position.maxScrollExtent);
      _textScroll.widget.scrollController.jumpTo(newScrollOffset);

      _updateDragSelection();
    }
  }

  void _scrollIfNearBoundary() {
    if (_dragEndInViewport == null) {
      _log.log('_scrollIfNearBoundary', "Can't scroll near boundary because _dragEndInViewport is null");
      assert(_dragEndInViewport != null);
      return;
    }

    if (!widget.isMultiline) {
      _scrollIfNearHorizontalBoundary();
    } else {
      _scrollIfNearVerticalBoundary();
    }
  }

  void _scrollIfNearHorizontalBoundary() {
    final editorBox = context.findRenderObject() as RenderBox;

    if (_dragEndInViewport!.dx < _dragGutterExtent) {
      _startScrollingToStart();
    } else {
      _stopScrollingToStart();
    }
    if (editorBox.size.width - _dragEndInViewport!.dx < _dragGutterExtent) {
      _startScrollingToEnd();
    } else {
      _stopScrollingToEnd();
    }
  }

  void _scrollIfNearVerticalBoundary() {
    final editorBox = context.findRenderObject() as RenderBox;

    if (_dragEndInViewport!.dy < _dragGutterExtent) {
      _startScrollingToStart();
    } else {
      _stopScrollingToStart();
    }
    if (editorBox.size.height - _dragEndInViewport!.dy < _dragGutterExtent) {
      _startScrollingToEnd();
    } else {
      _stopScrollingToEnd();
    }
  }

  void _startScrollingToStart() {
    if (_dragEndInViewport == null) {
      _log.log('_scrollUp', "Can't scroll up because _dragEndInViewport is null");
      assert(_dragEndInViewport != null);
      return;
    }

    final gutterAmount = _dragEndInViewport!.dy.clamp(0.0, _dragGutterExtent);
    final speedPercent = 1.0 - (gutterAmount / _dragGutterExtent);
    final scrollAmount = lerpDouble(0, _maxDragSpeed, speedPercent)!;

    _textScroll._startScrollingToStart(amountPerFrame: scrollAmount);
  }

  void _stopScrollingToStart() {
    _textScroll._stopScrollingToStart();
  }

  void _startScrollingToEnd() {
    if (_dragEndInViewport == null) {
      _log.log('_scrollDown', "Can't scroll down because _dragEndInViewport is null");
      assert(_dragEndInViewport != null);
      return;
    }

    final editorBox = context.findRenderObject() as RenderBox;
    final gutterAmount = (editorBox.size.height - _dragEndInViewport!.dy).clamp(0.0, _dragGutterExtent);
    final speedPercent = 1.0 - (gutterAmount / _dragGutterExtent);
    final scrollAmount = lerpDouble(0, _maxDragSpeed, speedPercent)!;

    _textScroll._startScrollingToEnd(amountPerFrame: scrollAmount);
  }

  void _stopScrollingToEnd() {
    _textScroll._stopScrollingToEnd();
  }

  void _updateCursorStyle(Offset cursorOffset) {
    if (_isTextAtOffset(cursorOffset)) {
      _cursorStyle.value = SystemMouseCursors.text;
    } else {
      _cursorStyle.value = SystemMouseCursors.basic;
    }
  }

  TextPosition? _getPositionAtOffset(Offset textFieldOffset) {
    final textOffset = _getTextOffset(textFieldOffset);
    final textBox = widget.textKey.currentContext!.findRenderObject() as RenderBox;

    return textBox.size.contains(textOffset) ? widget.textKey.currentState!.getPositionAtOffset(textOffset) : null;
  }

  TextSelection _getParagraphSelectionAt(TextPosition textPosition, TextAffinity affinity) {
    return _text.expandSelection(textPosition, paragraphExpansionFilter, affinity);
  }

  TextPosition _getPositionNearestToTextOffset(Offset textOffset) {
    return widget.textKey.currentState!.getPositionAtOffset(textOffset);
  }

  bool _isTextAtOffset(Offset textFieldOffset) {
    final textOffset = _getTextOffset(textFieldOffset);
    return widget.textKey.currentState!.isTextAtOffset(textOffset);
  }

  Offset _getTextOffset(Offset textFieldOffset) {
    final textFieldBox = context.findRenderObject() as RenderBox;
    final textBox = widget.textKey.currentContext!.findRenderObject() as RenderBox;
    return textBox.globalToLocal(textFieldOffset, ancestor: textFieldBox);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerSignal: _onPointerSignal,
      onPointerHover: _onMouseMove,
      child: GestureDetector(
        onSecondaryTapUp: _onRightClick,
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
          child: ListenableBuilder(
            listenable: _cursorStyle,
            builder: (context) {
              return MouseRegion(
                cursor: _cursorStyle.value,
                child: widget.child,
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Handles all keyboard interactions for text entry in a text field.
///
/// [SuperTextFieldKeyboardInteractor] is intended to operate as a piece within
/// a larger composition that behaves as a text field. [SuperTextFieldKeyboardInteractor]
/// is defined on its own so that it can be replaced with a widget that handles
/// key events differently.
///
/// The key events are applied to a [SelectableText] widget that is tied to [textKey].
class SuperTextFieldKeyboardInteractor extends StatefulWidget {
  const SuperTextFieldKeyboardInteractor({
    Key? key,
    required this.focusNode,
    required this.textController,
    required this.textKey,
    required this.keyboardActions,
    required this.child,
  }) : super(key: key);

  /// [FocusNode] for this text field.
  final FocusNode focusNode;

  /// [TextController] for the text/selection within this text field.
  final AttributedTextEditingController textController;

  /// [GlobalKey] that links this [SuperTextFieldGestureInteractor] to
  /// the [SelectableText] widget that paints the text for this text field.
  final GlobalKey<SelectableTextState> textKey;

  /// Ordered list of actions that correspond to various key events.
  ///
  /// Each handler in the list may be given a key event from the keyboard. That
  /// handler chooses to take an action, or not. A handler must respond with
  /// a [TextFieldKeyboardHandlerResult], which indicates how the key event was handled,
  /// or not.
  ///
  /// When a handler reports [TextFieldKeyboardHandlerResult.notHandled], the key event
  /// is sent to the next handler.
  ///
  /// As soon as a handler reports [TextFieldKeyboardHandlerResult.handled], no other
  /// handler is executed and the key event is prevented from propagating up
  /// the widget tree.
  ///
  /// When a handler reports [TextFieldKeyboardHandlerResult.blocked], no other
  /// handler is executed, but the key event **continues** to propagate up
  /// the widget tree for other listeners to act upon.
  ///
  /// If all handlers report [TextFieldKeyboardHandlerResult.notHandled], the key
  /// event propagates up the widget tree for other listeners to act upon.
  final List<TextFieldKeyboardHandler> keyboardActions;

  /// The rest of the subtree for this text field.
  final Widget child;

  @override
  _SuperTextFieldKeyboardInteractorState createState() => _SuperTextFieldKeyboardInteractorState();
}

class _SuperTextFieldKeyboardInteractorState extends State<SuperTextFieldKeyboardInteractor> {
  KeyEventResult _onKeyPressed(FocusNode focusNode, RawKeyEvent keyEvent) {
    _log.log('_onKeyPressed', 'keyEvent: ${keyEvent.character}');
    if (keyEvent is! RawKeyDownEvent) {
      _log.log('_onKeyPressed', ' - not a "down" event. Ignoring.');
      return KeyEventResult.ignored;
    }

    TextFieldKeyboardHandlerResult instruction = TextFieldKeyboardHandlerResult.notHandled;
    int index = 0;
    while (instruction == TextFieldKeyboardHandlerResult.notHandled && index < widget.keyboardActions.length) {
      instruction = widget.keyboardActions[index](
        controller: widget.textController,
        selectableTextState: widget.textKey.currentState!,
        keyEvent: keyEvent,
      );
      index += 1;
    }

    return instruction == TextFieldKeyboardHandlerResult.handled ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: widget.focusNode,
      onKey: _onKeyPressed,
      child: widget.child,
    );
  }
}

/// Handles all scrolling behavior for a text field.
///
/// [SuperTextFieldScrollview] is intended to operate as a piece within
/// a larger composition that behaves as a text field. [SuperTextFieldScrollview]
/// is defined on its own so that it can be replaced with a widget that handles
/// scrolling differently.
///
/// [SuperTextFieldScrollview] determines when and where to scroll by working
/// with a corresponding [SelectableText] widget that is tied to [textKey].
class SuperTextFieldScrollview extends StatefulWidget {
  const SuperTextFieldScrollview({
    Key? key,
    required this.textKey,
    required this.textController,
    required this.scrollController,
    required this.padding,
    required this.viewportHeight,
    required this.estimatedLineHeight,
    required this.isMultiline,
    required this.child,
  }) : super(key: key);

  /// [TextController] for the text/selection within this text field.
  final AttributedTextEditingController textController;

  /// [GlobalKey] that links this [SuperTextFieldScrollview] to
  /// the [SelectableText] widget that paints the text for this text field.
  final GlobalKey<SelectableTextState> textKey;

  /// [ScrollController] that controls the scroll offset of this [SuperTextFieldScrollview].
  final ScrollController scrollController;

  /// Padding placed around the text content of this text field, but within the
  /// scrollable viewport.
  final EdgeInsetsGeometry padding;

  /// The height of the viewport for this text field.
  ///
  /// If [null] then the viewport is permitted to grow/shrink to any desired height.
  final double? viewportHeight;

  /// An estimate for the height in pixels of a single line of text within this
  /// text field.
  final double estimatedLineHeight;

  /// Whether or not this text field allows multiple lines of text.
  final bool isMultiline;

  /// The rest of the subtree for this text field.
  final Widget child;

  @override
  SuperTextFieldScrollviewState createState() => SuperTextFieldScrollviewState();
}

class SuperTextFieldScrollviewState extends State<SuperTextFieldScrollview> with SingleTickerProviderStateMixin {
  bool _scrollToStartOnTick = false;
  bool _scrollToEndOnTick = false;
  double _scrollAmountPerFrame = 0;
  late Ticker _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);

    widget.textController.addListener(_onSelectionOrContentChange);
  }

  @override
  void didUpdateWidget(SuperTextFieldScrollview oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.textController != oldWidget.textController) {
      oldWidget.textController.removeListener(_onSelectionOrContentChange);
      widget.textController.addListener(_onSelectionOrContentChange);
    }

    if (widget.viewportHeight != oldWidget.viewportHeight) {
      // After the current layout, ensure that the current text
      // selection is visible.
      WidgetsBinding.instance!.addPostFrameCallback((timeStamp) {
        if (mounted) {
          _ensureSelectionExtentIsVisible();
        }
      });
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  SelectableTextState get _text => widget.textKey.currentState!;

  void _onSelectionOrContentChange() {
    // Use a post-frame callback to "ensure selection extent is visible"
    // so that any pending visual content changes can happen before
    // attempting to calculate the visual position of the selection extent.
    WidgetsBinding.instance!.addPostFrameCallback((timeStamp) {
      if (mounted) {
        _ensureSelectionExtentIsVisible();
      }
    });
  }

  void _ensureSelectionExtentIsVisible() {
    if (!widget.isMultiline) {
      _ensureSelectionExtentIsVisibleInSingleLineTextField();
    } else {
      _ensureSelectionExtentIsVisibleInMultilineTextField();
    }
  }

  void _ensureSelectionExtentIsVisibleInSingleLineTextField() {
    final selection = widget.textController.selection;
    if (selection.extentOffset == -1) {
      return;
    }

    final extentOffset = _text.getOffsetAtPosition(selection.extent);

    final gutterExtent = 0; // _dragGutterExtent

    final myBox = context.findRenderObject() as RenderBox;
    final beyondLeftExtent = min(extentOffset.dx - widget.scrollController.offset - gutterExtent, 0).abs();
    final beyondRightExtent = max(
        extentOffset.dx - myBox.size.width - widget.scrollController.offset + gutterExtent + widget.padding.horizontal,
        0);

    if (beyondLeftExtent > 0) {
      final newScrollPosition = (widget.scrollController.offset - beyondLeftExtent)
          .clamp(0.0, widget.scrollController.position.maxScrollExtent);

      widget.scrollController.animateTo(
        newScrollPosition,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOut,
      );
    } else if (beyondRightExtent > 0) {
      final newScrollPosition = (beyondRightExtent + widget.scrollController.offset)
          .clamp(0.0, widget.scrollController.position.maxScrollExtent);

      widget.scrollController.animateTo(
        newScrollPosition,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOut,
      );
    }
  }

  void _ensureSelectionExtentIsVisibleInMultilineTextField() {
    final selection = widget.textController.selection;
    if (selection.extentOffset == -1) {
      return;
    }

    final extentOffset = _text.getOffsetAtPosition(selection.extent);

    final gutterExtent = 0; // _dragGutterExtent
    final extentLineIndex = (extentOffset.dy / widget.estimatedLineHeight).round();

    final myBox = context.findRenderObject() as RenderBox;
    final beyondTopExtent = min<double>(extentOffset.dy - widget.scrollController.offset - gutterExtent, 0).abs();
    final beyondBottomExtent = max<double>(
        ((extentLineIndex + 1) * widget.estimatedLineHeight) -
            myBox.size.height -
            widget.scrollController.offset +
            gutterExtent +
            (widget.estimatedLineHeight / 2) + // manual adjustment to avoid line getting half cut off
            widget.padding.vertical / 2,
        0);

    _log.log('_ensureSelectionExtentIsVisible', 'Ensuring extent is visible.');
    _log.log('_ensureSelectionExtentIsVisible', ' - interaction size: ${myBox.size}');
    _log.log('_ensureSelectionExtentIsVisible', ' - scroll extent: ${widget.scrollController.offset}');
    _log.log('_ensureSelectionExtentIsVisible', ' - extent rect: $extentOffset');
    _log.log('_ensureSelectionExtentIsVisible', ' - beyond top: $beyondTopExtent');
    _log.log('_ensureSelectionExtentIsVisible', ' - beyond bottom: $beyondBottomExtent');

    if (beyondTopExtent > 0) {
      final newScrollPosition = (widget.scrollController.offset - beyondTopExtent)
          .clamp(0.0, widget.scrollController.position.maxScrollExtent);

      widget.scrollController.animateTo(
        newScrollPosition,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOut,
      );
    } else if (beyondBottomExtent > 0) {
      final newScrollPosition = (beyondBottomExtent + widget.scrollController.offset)
          .clamp(0.0, widget.scrollController.position.maxScrollExtent);

      widget.scrollController.animateTo(
        newScrollPosition,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOut,
      );
    }
  }

  void _startScrollingToStart({required double amountPerFrame}) {
    assert(amountPerFrame > 0);

    if (_scrollToStartOnTick) {
      _scrollAmountPerFrame = amountPerFrame;
      return;
    }

    _scrollToStartOnTick = true;
    _ticker.start();
  }

  void _stopScrollingToStart() {
    if (!_scrollToStartOnTick) {
      return;
    }

    _scrollToStartOnTick = false;
    _scrollAmountPerFrame = 0;
    _ticker.stop();
  }

  void _scrollToStart() {
    if (widget.scrollController.offset <= 0) {
      return;
    }

    widget.scrollController.position.jumpTo(widget.scrollController.offset - _scrollAmountPerFrame);
  }

  void _startScrollingToEnd({required double amountPerFrame}) {
    assert(amountPerFrame > 0);

    if (_scrollToEndOnTick) {
      _scrollAmountPerFrame = amountPerFrame;
      return;
    }

    _scrollToEndOnTick = true;
    _ticker.start();
  }

  void _stopScrollingToEnd() {
    if (!_scrollToEndOnTick) {
      return;
    }

    _scrollToEndOnTick = false;
    _scrollAmountPerFrame = 0;
    _ticker.stop();
  }

  void _scrollToEnd() {
    if (widget.scrollController.offset >= widget.scrollController.position.maxScrollExtent) {
      return;
    }

    widget.scrollController.position.jumpTo(widget.scrollController.offset + _scrollAmountPerFrame);
  }

  void _onTick(elapsedTime) {
    if (_scrollToStartOnTick) {
      _scrollToStart();
    }
    if (_scrollToEndOnTick) {
      _scrollToEnd();
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.viewportHeight,
      child: SingleChildScrollView(
        controller: widget.scrollController,
        physics: NeverScrollableScrollPhysics(),
        scrollDirection: widget.isMultiline ? Axis.vertical : Axis.horizontal,
        child: Padding(
          padding: widget.padding,
          child: widget.child,
        ),
      ),
    );
  }
}

typedef RightClickListener = void Function(
    BuildContext textFieldContext, AttributedTextEditingController textController, Offset textFieldOffset);

enum _SelectionType {
  /// The selection bound is set on a per-character basis.
  ///
  /// This is standard text selection behavior.
  position,

  /// The selection bound expands to include any word that the
  /// cursor touches.
  word,

  /// The selection bound expands to include any paragraph that
  /// the cursor touches.
  paragraph,
}

enum TextFieldKeyboardHandlerResult {
  /// The handler recognized the key event and chose to
  /// take an action.
  ///
  /// No other handler should receive the key event.
  ///
  /// The key event **shouldn't** bubble up the tree.
  handled,

  /// The handler recognized the key event but chose to
  /// take no action.
  ///
  /// No other handler should receive the key event.
  ///
  /// The key event **should** bubble up the tree to
  /// (possibly) be handled by other keyboard/shortcut
  /// listeners.
  blocked,

  /// The handler has no relation to the key event and
  /// took no action.
  ///
  /// Other handlers should be given a chance to act on
  /// the key press.
  notHandled,
}

typedef TextFieldKeyboardHandler = TextFieldKeyboardHandlerResult Function({
  required AttributedTextEditingController controller,
  required SelectableTextState selectableTextState,
  required RawKeyEvent keyEvent,
});

/// The keyboard actions that a [SuperTextField] uses by default.
///
/// It's common for developers to want all of these actions, but also
/// want to add more actions that take priority. To achieve that,
/// add the new actions to the front of the list:
///
/// ```
/// SuperTextField(
///   keyboardActions: [
///     myNewAction1,
///     myNewAction2,
///     ...defaultTextfieldKeyboardActions,
///   ],
/// );
/// ```
const defaultTextFieldKeyboardHandlers = <TextFieldKeyboardHandler>[
  DefaultSuperTextFieldKeyboardHandlers.copyTextWhenCmdCIsPressed,
  DefaultSuperTextFieldKeyboardHandlers.pasteTextWhenCmdVIsPressed,
  DefaultSuperTextFieldKeyboardHandlers.selectAllTextFieldWhenCmdAIsPressed,
  DefaultSuperTextFieldKeyboardHandlers.moveUpDownLeftAndRightWithArrowKeys,
  DefaultSuperTextFieldKeyboardHandlers.deleteTextOnLineBeforeCaretWhenShortcutKeyAndBackspaceIsPressed,
  DefaultSuperTextFieldKeyboardHandlers.deleteTextWhenBackspaceOrDeleteIsPressed,
  DefaultSuperTextFieldKeyboardHandlers.insertNewlineWhenEnterIsPressed,
  DefaultSuperTextFieldKeyboardHandlers.insertCharacterWhenKeyIsPressed,
];

class DefaultSuperTextFieldKeyboardHandlers {
  static TextFieldKeyboardHandlerResult copyTextWhenCmdCIsPressed({
    required AttributedTextEditingController controller,
    SelectableTextState? selectableTextState,
    required RawKeyEvent keyEvent,
  }) {
    if (!keyEvent.isPrimaryShortcutKeyPressed) {
      return TextFieldKeyboardHandlerResult.notHandled;
    }
    if (keyEvent.logicalKey != LogicalKeyboardKey.keyC) {
      return TextFieldKeyboardHandlerResult.notHandled;
    }

    controller.copySelectedTextToClipboard();

    return TextFieldKeyboardHandlerResult.handled;
  }

  static TextFieldKeyboardHandlerResult pasteTextWhenCmdVIsPressed({
    required AttributedTextEditingController controller,
    SelectableTextState? selectableTextState,
    required RawKeyEvent keyEvent,
  }) {
    if (!keyEvent.isPrimaryShortcutKeyPressed) {
      return TextFieldKeyboardHandlerResult.notHandled;
    }
    if (keyEvent.logicalKey != LogicalKeyboardKey.keyV) {
      return TextFieldKeyboardHandlerResult.notHandled;
    }

    if (kIsWeb) {
      // On web the standard Flutter clipboard behavior requires special
      // browser permissions. We don't want the user to have to grant permissions.
      //
      // Browsers include a built-in paste event system that doesn't require
      // permissions. Therefore, on web we swallow this event and do nothing
      // in this handler, but the editor includes behavior elsewhere to apply
      // the pasted content. Look for the PasteEventHandler.
      return TextFieldKeyboardHandlerResult.blocked;
    }

    if (!controller.selection.isCollapsed) {
      controller.deleteSelectedText();
    }

    controller.pasteClipboard();

    return TextFieldKeyboardHandlerResult.handled;
  }

  static TextFieldKeyboardHandlerResult selectAllTextFieldWhenCmdAIsPressed({
    required AttributedTextEditingController controller,
    SelectableTextState? selectableTextState,
    required RawKeyEvent keyEvent,
  }) {
    if (!keyEvent.isPrimaryShortcutKeyPressed) {
      return TextFieldKeyboardHandlerResult.notHandled;
    }
    if (keyEvent.logicalKey != LogicalKeyboardKey.keyA) {
      return TextFieldKeyboardHandlerResult.notHandled;
    }

    controller.selectAll();

    return TextFieldKeyboardHandlerResult.handled;
  }

  static TextFieldKeyboardHandlerResult moveUpDownLeftAndRightWithArrowKeys({
    required AttributedTextEditingController controller,
    required SelectableTextState selectableTextState,
    required RawKeyEvent keyEvent,
  }) {
    const arrowKeys = [
      LogicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.arrowUp,
      LogicalKeyboardKey.arrowDown,
    ];
    if (!arrowKeys.contains(keyEvent.logicalKey)) {
      return TextFieldKeyboardHandlerResult.notHandled;
    }
    if (controller.selection.extentOffset == -1) {
      // The result is reported as "handled" because an arrow
      // key was pressed, but we return early because there is
      // nowhere to move without a selection.
      return TextFieldKeyboardHandlerResult.handled;
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

      controller.moveCaretHorizontally(
        selectableTextState: selectableTextState,
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

      controller.moveCaretHorizontally(
        selectableTextState: selectableTextState,
        expandSelection: keyEvent.isShiftPressed,
        moveLeft: false,
        movementModifiers: movementModifiers,
      );
    } else if (keyEvent.logicalKey == LogicalKeyboardKey.arrowUp) {
      _log.log('moveUpDownLeftAndRightWithArrowKeys', ' - handling up arrow key');
      controller.moveCaretVertically(
        selectableTextState: selectableTextState,
        expandSelection: keyEvent.isShiftPressed,
        moveUp: true,
      );
    } else if (keyEvent.logicalKey == LogicalKeyboardKey.arrowDown) {
      _log.log('moveUpDownLeftAndRightWithArrowKeys', ' - handling down arrow key');
      controller.moveCaretVertically(
        selectableTextState: selectableTextState,
        expandSelection: keyEvent.isShiftPressed,
        moveUp: false,
      );
    }

    return TextFieldKeyboardHandlerResult.handled;
  }

  static TextFieldKeyboardHandlerResult insertCharacterWhenKeyIsPressed({
    required AttributedTextEditingController controller,
    SelectableTextState? selectableTextState,
    required RawKeyEvent keyEvent,
  }) {
    if (keyEvent.isMetaPressed || keyEvent.isControlPressed) {
      return TextFieldKeyboardHandlerResult.notHandled;
    }

    if (keyEvent.character == null || keyEvent.character == '') {
      return TextFieldKeyboardHandlerResult.notHandled;
    }
    if (LogicalKeyboardKey.isControlCharacter(keyEvent.character!)) {
      return TextFieldKeyboardHandlerResult.notHandled;
    }

    // On web, keys like shift and alt are sending their full name
    // as a character, e.g., "Shift" and "Alt". This check prevents
    // those keys from inserting their name into content.
    //
    // This filter is a blacklist, and therefore it will fail to
    // catch any key that isn't explicitly listed. The eventual solution
    // to this is for the web to honor the standard key event contract,
    // but that's out of our control.
    if (kIsWeb && webBugBlacklistCharacters.contains(keyEvent.character)) {
      return TextFieldKeyboardHandlerResult.notHandled;
    }

    controller.insertCharacter(keyEvent.character!);

    return TextFieldKeyboardHandlerResult.handled;
  }

  static TextFieldKeyboardHandlerResult deleteTextOnLineBeforeCaretWhenShortcutKeyAndBackspaceIsPressed({
    required AttributedTextEditingController controller,
    required SelectableTextState selectableTextState,
    required RawKeyEvent keyEvent,
  }) {
    if (!keyEvent.isPrimaryShortcutKeyPressed || keyEvent.logicalKey != LogicalKeyboardKey.backspace) {
      return TextFieldKeyboardHandlerResult.notHandled;
    }
    if (!controller.selection.isCollapsed) {
      return TextFieldKeyboardHandlerResult.notHandled;
    }
    if (controller.selection.extentOffset < 0) {
      return TextFieldKeyboardHandlerResult.notHandled;
    }
    if (selectableTextState.getPositionAtStartOfLine(controller.selection.extent).offset ==
        controller.selection.extentOffset) {
      return TextFieldKeyboardHandlerResult.notHandled;
    }

    controller.deleteTextOnLineBeforeCaret(selectableTextState: selectableTextState);

    return TextFieldKeyboardHandlerResult.handled;
  }

  static TextFieldKeyboardHandlerResult deleteTextWhenBackspaceOrDeleteIsPressed({
    required AttributedTextEditingController controller,
    SelectableTextState? selectableTextState,
    required RawKeyEvent keyEvent,
  }) {
    final isBackspace = keyEvent.logicalKey == LogicalKeyboardKey.backspace;
    final isDelete = keyEvent.logicalKey == LogicalKeyboardKey.delete;
    if (!isBackspace && !isDelete) {
      return TextFieldKeyboardHandlerResult.notHandled;
    }
    if (controller.selection.extentOffset < 0) {
      return TextFieldKeyboardHandlerResult.notHandled;
    }

    if (controller.selection.isCollapsed) {
      controller.deleteCharacter(isBackspace ? TextAffinity.upstream : TextAffinity.downstream);
    } else {
      controller.deleteSelectedText();
    }

    return TextFieldKeyboardHandlerResult.handled;
  }

  static TextFieldKeyboardHandlerResult insertNewlineWhenEnterIsPressed({
    required AttributedTextEditingController controller,
    SelectableTextState? selectableTextState,
    required RawKeyEvent keyEvent,
  }) {
    if (keyEvent.logicalKey != LogicalKeyboardKey.enter) {
      return TextFieldKeyboardHandlerResult.notHandled;
    }
    if (!controller.selection.isCollapsed) {
      return TextFieldKeyboardHandlerResult.notHandled;
    }

    controller.insertNewline();

    return TextFieldKeyboardHandlerResult.handled;
  }
}

class AttributedTextEditingController with ChangeNotifier {
  AttributedTextEditingController({
    AttributedText? text,
    TextSelection? selection,
  })  : _text = text ?? AttributedText(),
        _selection = selection ?? TextSelection.collapsed(offset: -1);

  void updateTextAndSelection({
    required AttributedText text,
    required TextSelection selection,
  }) {
    this.text = text;
    this.selection = selection;
  }

  AttributedText _text;
  AttributedText get text => _text;
  set text(AttributedText newValue) {
    if (newValue != _text) {
      _text.removeListener(notifyListeners);
      _text = newValue;
      _text.addListener(notifyListeners);

      // Ensure that the existing selection does not overshoot
      // the end of the new text value
      if (_selection.end > _text.text.length) {
        _selection = _selection.copyWith(
          baseOffset: _selection.affinity == TextAffinity.downstream ? _selection.baseOffset : _text.text.length,
          extentOffset: _selection.affinity == TextAffinity.downstream ? _text.text.length : _selection.extentOffset,
        );
      }

      notifyListeners();
    }
  }

  TextSelection _selection;
  TextSelection get selection => _selection;
  set selection(TextSelection newValue) {
    if (newValue != _selection) {
      _selection = newValue;
      notifyListeners();
    }
  }

  bool isSelectionWithinTextBounds(TextSelection selection) {
    return selection.start <= text.text.length && selection.end <= text.text.length;
  }

  TextSpan buildTextSpan(AttributionStyleBuilder styleBuilder) {
    return text.computeTextSpan(styleBuilder);
  }

  void clear() {
    _text = AttributedText();
    _selection = TextSelection.collapsed(offset: -1);
  }
}

extension DefaultSuperTextFieldActions on AttributedTextEditingController {
  void copySelectedTextToClipboard() {
    if (selection.extentOffset == -1) {
      // Nothing selected to copy.
      return;
    }

    Clipboard.setData(ClipboardData(
      text: selection.textInside(text.text),
    ));
  }

  Future<void> pasteClipboard() async {
    final clipboardData = await Clipboard.getData('text/plain');

    if (clipboardData != null && clipboardData.text != null) {
      final textToPaste = clipboardData.text!;

      insertTextAtCaret(textToPaste);
    }
  }

  void insertTextAtCaret(String textToInsert) {
    final insertionOffset = selection.extentOffset;

    text = text.insertString(
      textToInsert: textToInsert,
      startOffset: insertionOffset,
    );

    selection = TextSelection.collapsed(
      offset: insertionOffset + textToInsert.length,
    );
  }

  void selectAll() {
    selection = TextSelection(
      baseOffset: 0,
      extentOffset: text.text.length,
    );
  }

  void moveCaretHorizontally({
    required SelectableTextState selectableTextState,
    required bool expandSelection,
    required bool moveLeft,
    Map<String, dynamic> movementModifiers = const {},
  }) {
    int newExtent;

    if (moveLeft) {
      if (selection.extentOffset <= 0 && selection.isCollapsed) {
        // Can't move further left.
        return;
      }

      if (!selection.isCollapsed && !expandSelection) {
        // The selection isn't collapsed and the user doesn't
        // want to continue expanding the selection. Move the
        // extent to the left side of the selection.
        newExtent = selection.start;
      } else if (movementModifiers['movement_unit'] == 'line') {
        newExtent = selectableTextState.getPositionAtStartOfLine(TextPosition(offset: selection.extentOffset)).offset;
      } else if (movementModifiers['movement_unit'] == 'word') {
        final plainText = text.text;

        newExtent = selection.extentOffset;
        newExtent -= 1; // we always want to jump at least 1 character.
        while (newExtent > 0 && plainText[newExtent - 1] != ' ' && plainText[newExtent - 1] != '\n') {
          newExtent -= 1;
        }
      } else {
        newExtent = max(selection.extentOffset - 1, 0);
      }
    } else {
      if (selection.extentOffset >= text.text.length && selection.isCollapsed) {
        // Can't move further right.
        return;
      }

      if (!selection.isCollapsed && !expandSelection) {
        // The selection isn't collapsed and the user doesn't
        // want to continue expanding the selection. Move the
        // extent to the left side of the selection.
        newExtent = selection.end;
      } else if (movementModifiers['movement_unit'] == 'line') {
        final endOfLine = selectableTextState.getPositionAtEndOfLine(TextPosition(offset: selection.extentOffset));

        final endPosition = TextPosition(offset: text.text.length);
        final plainText = text.text;

        // Note: we compare offset values because we don't care if the affinitys are equal
        final isAutoWrapLine = endOfLine.offset != endPosition.offset && (plainText[endOfLine.offset] != '\n');

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
        newExtent = isAutoWrapLine ? endOfLine.offset - 1 : endOfLine.offset;
      } else if (movementModifiers['movement_unit'] == 'word') {
        final extentPosition = selection.extent;
        final plainText = text.text;

        newExtent = extentPosition.offset;
        newExtent += 1; // we always want to jump at least 1 character.
        while (newExtent < plainText.length && plainText[newExtent] != ' ' && plainText[newExtent] != '\n') {
          newExtent += 1;
        }
      } else {
        newExtent = min(selection.extentOffset + 1, text.text.length);
      }
    }

    selection = TextSelection(
      baseOffset: expandSelection ? selection.baseOffset : newExtent,
      extentOffset: newExtent,
    );
  }

  void moveCaretVertically({
    required SelectableTextState selectableTextState,
    required bool expandSelection,
    required bool moveUp,
  }) {
    int? newExtent;

    if (moveUp) {
      newExtent = selectableTextState.getPositionOneLineUp(selection.extent)?.offset;

      // If there is no line above the current selection, move selection
      // to the beginning of the available text.
      newExtent ??= 0;
    } else {
      newExtent = selectableTextState.getPositionOneLineDown(selection.extent)?.offset;

      // If there is no line below the current selection, move selection
      // to the end of the available text.
      newExtent ??= text.text.length;
    }

    selection = TextSelection(
      baseOffset: expandSelection ? selection.baseOffset : newExtent,
      extentOffset: newExtent,
    );
  }

  void insertCharacter(String character) {
    final initialTextOffset = selection.start;

    final existingAttributions = text.getAllAttributionsAt(initialTextOffset);

    if (!selection.isCollapsed) {
      text = text.removeRegion(startOffset: selection.start, endOffset: selection.end);
      selection = TextSelection.collapsed(offset: selection.start);
    }

    text = text.insertString(
      textToInsert: character,
      startOffset: initialTextOffset,
      applyAttributions: existingAttributions,
    );

    selection = TextSelection.collapsed(offset: initialTextOffset + 1);
  }

  void deleteCharacter(TextAffinity direction) {
    assert(selection.isCollapsed);

    int deleteStartIndex;
    int deleteEndIndex;

    if (direction == TextAffinity.upstream) {
      // Delete the character before the caret
      deleteEndIndex = selection.extentOffset;
      deleteStartIndex = getCharacterStartBounds(text.text, deleteEndIndex);
    } else {
      // Delete the character after the caret
      deleteStartIndex = selection.extentOffset;
      deleteEndIndex = getCharacterEndBounds(text.text, deleteStartIndex);
    }

    text = text.removeRegion(
      startOffset: deleteStartIndex,
      endOffset: deleteEndIndex,
    );
    selection = TextSelection.collapsed(offset: deleteStartIndex);
  }

  void deleteTextOnLineBeforeCaret({
    required SelectableTextState selectableTextState,
  }) {
    assert(selection.isCollapsed);

    final startOfLinePosition = selectableTextState.getPositionAtStartOfLine(selection.extent);
    selection = TextSelection(
      baseOffset: selection.extentOffset,
      extentOffset: startOfLinePosition.offset,
    );

    if (!selection.isCollapsed) {
      deleteSelectedText();
    }
  }

  void deleteSelectedText() {
    if (selection.isCollapsed) {
      // Nothing is selected. Nothing to delete. Returning.
      return;
    }

    final deleteStartIndex = selection.start;
    final deleteEndIndex = selection.end;

    text = text.removeRegion(
      startOffset: deleteStartIndex,
      endOffset: deleteEndIndex,
    );
    selection = TextSelection.collapsed(offset: deleteStartIndex);
  }

  void insertNewline() {
    final currentSelectionExtent = selection.extent;

    text = text.insertString(
      textToInsert: '\n',
      startOffset: currentSelectionExtent.offset,
    );
    selection = TextSelection.collapsed(offset: currentSelectionExtent.offset + 1);
  }
}
