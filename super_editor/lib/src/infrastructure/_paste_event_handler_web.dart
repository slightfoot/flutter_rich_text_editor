import 'dart:async';
import 'dart:html' as html;

import 'package:super_editor/src/infrastructure/_paste_event_handler_interface.dart';

class PlatformPasteEventHandler implements PasteEventHandler {
  PlatformPasteEventHandler(PasteDelegate delegate) : _delegate = delegate {
    print('Listening for document paste events');
    _pasteSubscription = html.document.onPaste.listen(_onPaste);
  }

  @override
  void dispose() {
    _pasteSubscription.cancel();
  }

  final PasteDelegate _delegate;
  late StreamSubscription _pasteSubscription;

  void _onPaste(html.ClipboardEvent event) {
    // TODO:
    print('Received paste event: ');
    print(' - event: $event');
    print(' - text: ${event.clipboardData?.getData('text/plain')}');
    final clipboardText = event.clipboardData?.getData('text/plain');
    if (clipboardText == null || clipboardText.isEmpty) {
      return;
    }

    _delegate(clipboardText);
  }
}
