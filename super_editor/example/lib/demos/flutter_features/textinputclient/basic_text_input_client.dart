import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:super_editor/super_editor.dart';

/// Demo that displays a very limited text field, constructed from
/// the ground up, and using [TextInput] for user interaction instead
/// of a [RawKeyboardListener] or similar.
class BasicTextInputClientDemo extends StatefulWidget {
  @override
  _BasicTextInputClientDemoState createState() => _BasicTextInputClientDemoState();
}

class _BasicTextInputClientDemoState extends State<BasicTextInputClientDemo> {
  final _screenFocusNode = FocusNode();

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        print('Removing textfield focus');
        _screenFocusNode.requestFocus();
      },
      behavior: HitTestBehavior.translucent,
      child: Focus(
        focusNode: _screenFocusNode,
        child: Center(
          child: _BareBonesTextFieldWithInputClient(),
        ),
      ),
    );
  }
}

class _BareBonesTextFieldWithInputClient extends StatefulWidget {
  @override
  _BareBonesTextFieldWithInputClientState createState() => _BareBonesTextFieldWithInputClientState();
}

class _BareBonesTextFieldWithInputClientState extends State<_BareBonesTextFieldWithInputClient>
    implements TextInputClient {
  final _textKey = GlobalKey();

  late FocusNode _focusNode;
  String _currentText = '';
  TextSelection _currentSelection = const TextSelection.collapsed(offset: -1);

  TextInputConnection? _textInputConnection;

  Offset? _floatingCursorStartOffset;
  Offset? _floatingCursorCurrentOffset;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode()
      ..unfocus()
      ..addListener(_onFocusChange);
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  TextPosition _getTextPositionAtOffset(Offset localOffset) {
    final superSelectableTextState = _textKey.currentState as SuperSelectableTextState;
    return superSelectableTextState.getPositionAtOffset(localOffset);
  }

  Offset _getOffsetAtTextPosition(TextPosition position) {
    final superSelectableTextState = _textKey.currentState as SuperSelectableTextState;
    return superSelectableTextState.getOffsetAtPosition(position);
  }

  void _onTextFieldTapUp(TapUpDetails details) {
    print('Tapped on text field at ${details.localPosition}');

    // Calculate the position in the text where the user tapped.
    //
    // We show placeholder text when there is no text content. We don't want
    // to place the caret in the placeholder text, so when _currentText is
    // empty, explicitly set the text position to an offset of -1.
    final tapTextPosition =
        _currentText.isNotEmpty ? _getTextPositionAtOffset(details.localPosition) : const TextPosition(offset: -1);

    setState(() {
      print('Tap text position: $tapTextPosition');
      _currentSelection = TextSelection.collapsed(offset: tapTextPosition.offset);

      if (_textInputConnection != null) {
        _textInputConnection!.setEditingState(currentTextEditingValue!);
      }
    });

    _focusNode.requestFocus();
  }

  void _onPanStart(DragStartDetails details) {
    if (_textInputConnection == null) {
      print('WARNING: Tried to start a drag behavior with no text input connection');
      return;
    }

    _currentSelection = TextSelection.collapsed(
      offset: _getTextPositionAtOffset(details.localPosition).offset,
    );

    _textInputConnection!.setEditingState(currentTextEditingValue!);
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (_textInputConnection == null) {
      print('WARNING: Tried to update a drag behavior with no text input connection');
      return;
    }

    setState(() {
      _currentSelection = _currentSelection.copyWith(
        extentOffset: _getTextPositionAtOffset(details.localPosition).offset,
      );
    });

    _textInputConnection!.setEditingState(currentTextEditingValue!);
  }

  void _onFocusChange() {
    print('Textfield focus change - has focus: ${_focusNode.hasFocus}');
    if (_focusNode.hasFocus) {
      // ignore: prefer_conditional_assignment
      if (_textInputConnection == null) {
        print('Attaching TextInputClient to TextInput');
        setState(() {
          _textInputConnection = TextInput.attach(this, const TextInputConfiguration());
          _textInputConnection!
            ..show()
            ..setEditingState(currentTextEditingValue!);
        });
      }
    } else {
      print('Detaching TextInputClient from TextInput');
      setState(() {
        _textInputConnection?.close();
        _textInputConnection = null;
      });
    }
  }

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  TextEditingValue? get currentTextEditingValue => TextEditingValue(
        text: _currentText,
        selection: _currentSelection,
      );

  @override
  void performAction(TextInputAction action) {
    print('My TextInputClient: performAction(): $action');

    // performAction() is called when the "done" button is pressed in
    // various "text configurations". For example, sometimes the "done"
    // button says "Call" or "Next", depending on the current text input
    // configuration. We don't need to worry about this for a barebones
    // implementation.
  }

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {
    print('My TextInputClient: performPrivateCommand() - action: $action, data: $data');

    // performPrivateCommand() provides a representation for unofficial
    // input commands to be executed. This appears to be an extension point
    // or an escape hatch for input functionality that an app needs to support,
    // but which does not exist at the OS/platform level.
  }

  @override
  void showAutocorrectionPromptRect(int start, int end) {
    print('My TextInputClient: showAutocorrectionPromptRect() - start: $start, end: $end');

    // I'm not sure why iOS wants to show an "autocorrection" rectangle
    // when we already have a selection visible.
  }

  @override
  void updateEditingValue(TextEditingValue value) {
    print('My TextInputClient: updateEditingValue(): $value');
    setState(() {
      _currentText = value.text;
      _currentSelection = value.selection;
    });
  }

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {
    print('My TextInputClient: updateFloatingCursor(): ${point.state}, offset: ${point.offset}');

    switch (point.state) {
      case FloatingCursorDragState.Start:
        _floatingCursorStartOffset = _getOffsetAtTextPosition(_currentSelection.extent);
        break;
      case FloatingCursorDragState.Update:
        _floatingCursorCurrentOffset = _floatingCursorStartOffset! + point.offset!;

        _currentSelection = TextSelection.collapsed(
          // Note: push the offset down by a few pixels so that we look up
          // the text position based on the vertical center of the line, not
          // the top of the line. TODO: calculate exactly half the line height.
          offset: _getTextPositionAtOffset(_floatingCursorCurrentOffset! + const Offset(0, 10)).offset,
        );
        _textInputConnection!.setEditingState(currentTextEditingValue!);

        break;
      case FloatingCursorDragState.End:
        _floatingCursorStartOffset = null;
        _floatingCursorCurrentOffset = null;
        break;
    }
  }

  @override
  void connectionClosed() {
    print('My TextInputClient: connectionClosed()');
    _textInputConnection = null;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 48),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.black),
        ),
        child: GestureDetector(
          onTapUp: _onTextFieldTapUp,
          onPanStart: _focusNode.hasFocus ? _onPanStart : null,
          onPanUpdate: _focusNode.hasFocus ? _onPanUpdate : null,
          child: Stack(
            children: [
              SuperSelectableText.plain(
                key: _textKey,
                text: _currentText.isNotEmpty ? _currentText : 'enter text',
                textSelection: _currentSelection,
                showCaret: true,
                style: TextStyle(
                  color: _currentText.isNotEmpty ? Colors.black : Colors.grey,
                  fontSize: 16,
                ),
              ),
              _buildFloatingCaret(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFloatingCaret() {
    if (_floatingCursorCurrentOffset == null) {
      return const SizedBox();
    }

    return Positioned(
      left: _floatingCursorCurrentOffset!.dx,
      top: _floatingCursorCurrentOffset!.dy,
      child: Container(
        width: 2,
        height: 20,
        color: Colors.red,
      ),
    );
  }
}
