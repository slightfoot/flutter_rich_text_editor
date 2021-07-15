import 'package:flutter/material.dart';

class EditTextDemo extends StatefulWidget {
  @override
  _EditTextDemoState createState() => _EditTextDemoState();
}

class _EditTextDemoState extends State<EditTextDemo> {
  final _screenFocusNode = FocusNode();
  final _textController = TextEditingController(
    text: 'This is a regular EditText, which implements TextInputClient internally.',
  );

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
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 48.0),
            child: IntrinsicHeight(
              child: TextField(
                controller: _textController,
                expands: true,
                minLines: null,
                maxLines: null,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
