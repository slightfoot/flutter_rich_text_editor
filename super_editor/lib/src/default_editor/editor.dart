import 'package:flutter/material.dart' hide SelectableText;
import 'package:flutter/rendering.dart';
import 'package:super_editor/src/core/document.dart';
import 'package:super_editor/src/core/document_composer.dart';
import 'package:super_editor/src/core/document_editor.dart';
import 'package:super_editor/src/core/document_layout.dart';
import 'package:super_editor/src/core/document_selection.dart';
import 'package:super_editor/src/core/edit_context.dart';
import 'package:super_editor/src/default_editor/attributions.dart';
import 'package:super_editor/src/default_editor/blockquote.dart';
import 'package:super_editor/src/default_editor/horizontal_rule.dart';
import 'package:super_editor/src/default_editor/image.dart';
import 'package:super_editor/src/default_editor/list_items.dart';
import 'package:super_editor/src/infrastructure/_listenable_builder.dart';
import 'package:super_editor/src/infrastructure/_paste_event_handler_interface.dart';
import 'package:super_editor/src/infrastructure/attributed_spans.dart';
import 'package:super_editor/src/infrastructure/attributed_text.dart';

import 'box_component.dart';
import 'document_interaction.dart';
import 'document_keyboard_actions.dart';
import 'layout.dart';
import 'multi_node_editing.dart';
import 'paragraph.dart';
import 'styles.dart';
import 'text.dart';
import 'unknown_component.dart';

/// A text editor for styled text and multi-media elements.
///
/// An `Editor` brings together the key pieces needed
/// to display a user-editable document:
///  * document model
///  * document editor
///  * document layout
///  * document interaction (tapping, dragging, typing, scrolling)
///  * document composer
///
/// An `Editor` determines the visual styling by way of:
///  * `componentBuilders`, which produce individual components
///     within the document layout
///  * `textStyleBuilder`, which vends `TextStyle`s for every
///     combination of text attributions
///  * `selectionStyle`, which dictates the color of the caret
///     and the color of selected text and components
///
/// An `Editor` determines how the keyboard interacts with the
/// document by way of `keyboardActions`.
///
/// All styling artifacts and `keyboardActions` are configurable
/// via the `Editor.custom` constructor.
///
/// ## Deeper explanation of core artifacts:
///
/// The document model is responsible for holding the content of a
/// document in a structured and query-able manner.
///
/// The document editor is responsible for mutating the document
/// structure.
///
/// Document layout is responsible for positioning and rendering the
/// various visual components in the document. It's also responsible
/// for linking logical document nodes to visual document components
/// to facilitate user interactions like tapping and dragging.
///
/// Document interaction is responsible for taking appropriate actions
/// in response to user taps, drags, and key presses.
///
/// Document composer is responsible for owning document
/// selection and the current text entry mode.
class Editor extends StatefulWidget {
  factory Editor.standard({
    Key? key,
    required DocumentEditor editor,
    DocumentComposer? composer,
    ScrollController? scrollController,
    FocusNode? focusNode,
    double maxWidth = 600,
    EdgeInsetsGeometry padding = EdgeInsets.zero,
    GlobalKey? documentLayoutKey,
    bool showDebugPaint = false,
  }) {
    return Editor._(
      key: key,
      editor: editor,
      composer: composer,
      componentBuilders: defaultComponentBuilders,
      textStyleBuilder: defaultStyleBuilder,
      selectionStyle: defaultSelectionStyle,
      keyboardActions: defaultKeyboardActions,
      scrollController: scrollController,
      focusNode: focusNode,
      maxWidth: maxWidth,
      padding: padding,
      documentLayoutKey: documentLayoutKey,
      showDebugPaint: showDebugPaint,
    );
  }

  factory Editor.custom({
    Key? key,
    required DocumentEditor editor,
    DocumentComposer? composer,
    AttributionStyleBuilder? textStyleBuilder,
    SelectionStyle? selectionStyle,
    List<DocumentKeyboardAction>? keyboardActions,
    List<ComponentBuilder>? componentBuilders,
    ScrollController? scrollController,
    FocusNode? focusNode,
    double maxWidth = 600,
    EdgeInsetsGeometry padding = EdgeInsets.zero,
    GlobalKey? documentLayoutKey,
    bool showDebugPaint = false,
  }) {
    return Editor._(
      key: key,
      editor: editor,
      composer: composer,
      componentBuilders: componentBuilders ?? defaultComponentBuilders,
      textStyleBuilder: textStyleBuilder ?? defaultStyleBuilder,
      selectionStyle: selectionStyle ?? defaultSelectionStyle,
      keyboardActions: keyboardActions ?? defaultKeyboardActions,
      scrollController: scrollController,
      focusNode: focusNode,
      maxWidth: maxWidth,
      padding: padding,
      documentLayoutKey: documentLayoutKey,
      showDebugPaint: showDebugPaint,
    );
  }

  const Editor._({
    Key? key,
    required this.editor,
    this.composer,
    required this.componentBuilders,
    required this.textStyleBuilder,
    required this.selectionStyle,
    required this.keyboardActions,
    this.scrollController,
    this.focusNode,
    this.maxWidth = 600,
    this.padding = EdgeInsets.zero,
    this.documentLayoutKey,
    this.showDebugPaint = false,
  }) : super(key: key);

  /// Contains a `Document` and alters that document as desired.
  final DocumentEditor editor;

  final DocumentComposer? composer;

  /// Priority list of widget factories that creates instances of
  /// each visual component displayed in the document layout, e.g.,
  /// paragraph component, image component,
  /// horizontal rule component, etc.
  final List<ComponentBuilder> componentBuilders;

  /// Factory that creates `TextStyle`s based on given
  /// attributions. An attribution can be anything. It is up
  /// to the `textStyleBuilder` to interpret attributions
  /// as desired to produce corresponding styles.
  final AttributionStyleBuilder textStyleBuilder;

  /// Styles to be applied to selected text.
  final SelectionStyle selectionStyle;

  /// All actions that this editor takes in response to key
  /// events, e.g., text entry, newlines, character deletion,
  /// copy, paste, etc.
  final List<DocumentKeyboardAction> keyboardActions;

  final ScrollController? scrollController;

  final GlobalKey? documentLayoutKey;

  final FocusNode? focusNode;

  final double maxWidth;

  final EdgeInsetsGeometry padding;

  /// Paints some extra visual ornamentation to help with
  /// debugging, when true.
  final showDebugPaint;

  @override
  _EditorState createState() => _EditorState();
}

class _EditorState extends State<Editor> {
  // GlobalKey used to access the `DocumentLayoutState` to figure
  // out where in the document the user taps or drags.
  late GlobalKey _docLayoutKey;

  late FocusNode _focusNode;
  late DocumentComposer _composer;

  DocumentPosition? _previousSelectionExtent;

  PasteEventHandler? _webPasteEventHandler;

  @override
  void initState() {
    super.initState();

    _composer = widget.composer ?? DocumentComposer();
    _composer.addListener(_updateComposerPreferencesAtSelection);

    _focusNode = (widget.focusNode ?? FocusNode())..addListener(_onFocusChange);
    if (_focusNode.hasFocus) {
      _startListeningForWebPasteEvents();
    }

    _docLayoutKey = widget.documentLayoutKey ?? GlobalKey();
  }

  @override
  void didUpdateWidget(Editor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.composer != oldWidget.composer) {
      _composer.removeListener(_updateComposerPreferencesAtSelection);

      _composer = widget.composer ?? DocumentComposer();
      _composer.addListener(_updateComposerPreferencesAtSelection);
    }
    if (widget.editor != oldWidget.editor) {
      // The content displayed in this Editor was switched
      // out. Remove any content selection from the previous
      // document.
      _composer.selection = null;
    }
    if (widget.focusNode != oldWidget.focusNode) {
      _focusNode.removeListener(_onFocusChange);
      _focusNode = widget.focusNode ?? FocusNode();
    }
    if (widget.documentLayoutKey != oldWidget.documentLayoutKey) {
      _docLayoutKey = widget.documentLayoutKey ?? GlobalKey();
    }
  }

  @override
  void dispose() {
    if (widget.composer == null) {
      _composer.dispose();
    }

    _focusNode.removeListener(_onFocusChange);
    if (widget.focusNode == null) {
      // We are using our own private FocusNode. Dispose it.
      _focusNode.dispose();
    }

    _stopListeningForWebPasteEvents();

    super.dispose();
  }

  void _onFocusChange() {
    print('Editor has focus: ${_focusNode.hasFocus}');
    if (_focusNode.hasFocus) {
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
    if (_composer.selection == null) {
      return;
    }

    DocumentPosition pastePosition = _composer.selection!.extent;

    // Delete all currently selected content.
    if (!_composer.selection!.isCollapsed) {
      pastePosition = getDocumentPositionAfterDeletion(
        document: widget.editor.document,
        selection: _composer.selection!,
      );

      // Delete the selected content.
      widget.editor.executeCommand(
        DeleteSelectionCommand(documentSelection: _composer.selection!),
      );

      _composer.selection = DocumentSelection.collapsed(position: pastePosition);
    }

    widget.editor.executeCommand(
      PasteEditorCommand(
        content: content,
        pastePosition: pastePosition,
        composer: _composer,
      ),
    );
  }

  void _stopListeningForWebPasteEvents() {
    print('Stopping listening for paste events');
    _webPasteEventHandler?.dispose();
  }

  void _updateComposerPreferencesAtSelection() {
    if (_composer.selection?.extent == _previousSelectionExtent) {
      return;
    }
    _previousSelectionExtent = _composer.selection?.extent;

    _composer.preferences.clearStyles();

    if (_composer.selection == null || !_composer.selection!.isCollapsed) {
      return;
    }

    final node = widget.editor.document.getNodeById(_composer.selection!.extent.nodeId);
    if (node is! TextNode) {
      return;
    }

    final textPosition = _composer.selection!.extent.nodePosition as TextPosition;

    if (textPosition.offset == 0) {
      if (node.text.text.isEmpty) {
        return;
      }

      // Inserted text at the very beginning of a text blob assumes the
      // attributions immediately following it.
      final allStyles = node.text.getAllAttributionsAt(textPosition.offset + 1);
      _composer.preferences.addStyles(allStyles);
    } else {
      // Inserted text assumes the attributions immediately preceding it.
      final allStyles = node.text.getAllAttributionsAt(textPosition.offset - 1);
      _composer.preferences.addStyles(allStyles);
    }
  }

  @override
  Widget build(BuildContext context) {
    return DocumentInteractor(
      focusNode: _focusNode,
      scrollController: widget.scrollController,
      editContext: EditContext(
        editor: widget.editor,
        composer: _composer,
        getDocumentLayout: () => _docLayoutKey.currentState as DocumentLayout,
      ),
      keyboardActions: widget.keyboardActions,
      showDebugPaint: widget.showDebugPaint,
      document: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: widget.maxWidth,
        ),
        child: Padding(
          padding: widget.padding,
          child: MultiListenableBuilder(
            listenables: {
              _focusNode,
              _composer,
              widget.editor.document,
            },
            builder: (context) {
              return DefaultDocumentLayout(
                key: _docLayoutKey,
                document: widget.editor.document,
                documentSelection: _composer.selection,
                componentBuilders: widget.componentBuilders,
                showCaret: _focusNode.hasFocus,
                extensions: {
                  textStylesExtensionKey: widget.textStyleBuilder,
                  selectionStylesExtensionKey: widget.selectionStyle,
                },
                showDebugPaint: widget.showDebugPaint,
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Default visual styles related to content selection.
final defaultSelectionStyle = const SelectionStyle(
  textCaretColor: Colors.black,
  selectionColor: Color(0xFFACCEF7),
);

/// Creates `TextStyles` for the standard `Editor`.
TextStyle defaultStyleBuilder(Set<Attribution> attributions) {
  TextStyle newStyle = TextStyle(
    color: Colors.black,
    fontSize: 13,
    height: 1.4,
  );

  for (final attribution in attributions) {
    if (attribution == header1Attribution) {
      newStyle = newStyle.copyWith(
        fontSize: 24,
        fontWeight: FontWeight.bold,
        height: 1.0,
      );
    } else if (attribution == header2Attribution) {
      newStyle = newStyle.copyWith(
        fontSize: 18,
        fontWeight: FontWeight.bold,
        color: const Color(0xFF888888),
        height: 1.0,
      );
    } else if (attribution == blockquoteAttribution) {
      newStyle = newStyle.copyWith(
        fontSize: 20,
        fontWeight: FontWeight.bold,
        height: 1.4,
        color: Colors.grey,
      );
    } else if (attribution == boldAttribution) {
      newStyle = newStyle.copyWith(
        fontWeight: FontWeight.bold,
      );
    } else if (attribution == italicsAttribution) {
      newStyle = newStyle.copyWith(
        fontStyle: FontStyle.italic,
      );
    } else if (attribution == strikethroughAttribution) {
      newStyle = newStyle.copyWith(
        decoration: TextDecoration.lineThrough,
      );
    } else if (attribution is LinkAttribution) {
      newStyle = newStyle.copyWith(
        color: Colors.lightBlue,
        decoration: TextDecoration.underline,
      );
    }
  }
  return newStyle;
}

/// Creates visual components for the standard `Editor`.
///
/// These builders are in priority order. The first builder
/// to return a non-null component is used. The final
/// `unknownComponentBuilder` always returns a component.
final defaultComponentBuilders = <ComponentBuilder>[
  paragraphBuilder,
  unorderedListItemBuilder,
  orderedListItemBuilder,
  blockquoteBuilder,
  imageBuilder,
  horizontalRuleBuilder,
  unknownComponentBuilder,
];

/// Keyboard actions for the standard `Editor`.
final defaultKeyboardActions = <DocumentKeyboardAction>[
  doNothingWhenThereIsNoSelection,
  indentListItemWhenTabIsPressed,
  unindentListItemWhenShiftTabIsPressed,
  unindentListItemWhenBackspaceIsPressed,
  splitListItemWhenEnterPressed,
  convertBlockquoteToParagraphWhenBackspaceIsPressed,
  insertNewlineInBlockquote,
  splitBlockquoteWhenEnterPressed,
  pasteWhenCmdVIsPressed,
  copyWhenCmdVIsPressed,
  selectAllWhenCmdAIsPressed,
  applyBoldWhenCmdBIsPressed,
  applyItalicsWhenCmdIIsPressed,
  collapseSelectionWhenDirectionalKeyIsPressed,
  deleteExpandedSelectionWhenCharacterOrDestructiveKeyPressed,
  deleteBoxWhenBackspaceOrDeleteIsPressed,
  insertNewlineInParagraph,
  splitParagraphWhenEnterPressed,
  deleteCharacterWhenBackspaceIsPressed,
  mergeNodeWithPreviousWhenBackspaceIsPressed,
  deleteEmptyParagraphWhenBackspaceIsPressed,
  moveParagraphSelectionUpWhenBackspaceIsPressed,
  deleteCharacterWhenDeleteIsPressed,
  mergeNodeWithNextWhenDeleteIsPressed,
  moveUpDownLeftAndRightWithArrowKeys,
  insertCharacterInParagraph,
  insertCharacterInTextComposable,
];
