import 'package:super_editor/src/core/document_composer.dart';
import 'package:super_editor/src/core/document_editor.dart';
import 'package:super_editor/src/infrastructure/_paste_event_handler_interface.dart';

class PlatformPasteEventHandler implements PasteEventHandler {
  PlatformPasteEventHandler(PasteDelegate delegate);

  @override
  void dispose() {}
}
