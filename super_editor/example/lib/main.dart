import 'package:example/demos/custom_elements/custom_elements.dart';
import 'package:example/demos/demo_RTL.dart';
import 'package:example/demos/demo_markdown_serialization.dart';
import 'package:example/demos/demo_paragraphs.dart';
import 'package:example/demos/demo_selectable_text.dart';
import 'package:example/demos/example_editor/example_editor.dart';
import 'package:example/demos/sliver_example_editor.dart';
import 'package:example/demos/supertextfield/demo_textfield.dart';
import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'demos/demo_attributed_text.dart';
import 'demos/demo_document_loses_focus.dart';
import 'demos/demo_switch_document_content.dart';

/// Demo of a basic text editor, as well as various widgets that
/// are available in this package.
Future<void> main() async {
  runApp(SuperEditorDemoApp());
}

class SuperEditorDemoApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Super Editor Demo App',
      theme: ThemeData(
        primarySwatch: Colors.red,
      ),
      home: HomeScreen(),
      supportedLocales: const [
        Locale('en', ''),
        Locale('es', ''),
      ],
      localizationsDelegates: const [
        ...AppLocalizations.localizationsDelegates,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      debugShowCheckedModeBanner: false,
    );
  }
}

/// Displays various demos that are selected from a list of
/// options in a drawer.
class HomeScreen extends StatefulWidget {
  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  _MenuItem? _selectedMenuItem;

  @override
  void initState() {
    super.initState();

    _selectedMenuItem = _menu[0].items[0];
  }

  void _toggleDrawer() {
    if (_scaffoldKey.currentState!.isDrawerOpen) {
      Navigator.of(context).pop();
    } else {
      _scaffoldKey.currentState!.openDrawer();
    }
  }

  void _closeDrawer() {
    if (_scaffoldKey.currentState!.isDrawerOpen) {
      Navigator.of(context).pop();
    }
  }

  void _selectMenuItem(_MenuItem item) {
    setState(() {
      _selectedMenuItem = item;
      _closeDrawer();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      appBar: _buildAppBar(context),
      extendBodyBehindAppBar: true,
      body: _selectedMenuItem!.pageBuilder(context),
      drawer: _buildDrawer(),
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    return AppBar(
      backgroundColor: Colors.transparent,
      elevation: 0,
      leading: IconButton(
        icon: const Icon(Icons.menu),
        color: Theme.of(context).colorScheme.onSurface,
        splashRadius: 24,
        onPressed: _toggleDrawer,
      ),
    );
  }

  Widget _buildDrawer() {
    return Drawer(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 48),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final group in _menu) ...[
                if (group.title != null) _DrawerHeader(title: group.title),
                for (final item in group.items) ...[
                  _DrawerButton(
                    icon: item.icon,
                    title: item.title,
                    isSelected: item == _selectedMenuItem,
                    onPressed: () {
                      _selectMenuItem(item);
                    },
                  ),
                ],
                const SizedBox(height: 24),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// Demo options that are shown in the `HomeScreen` drawer.
final _menu = <_MenuGroup>[
  _MenuGroup(
    items: [
      _MenuItem(
        icon: Icons.description,
        title: 'Editor Demo',
        pageBuilder: (context) {
          return ExampleEditor();
        },
      ),
      _MenuItem(
        icon: Icons.description,
        title: 'Sliver Editor Demo',
        pageBuilder: (context) {
          return SliverExampleEditor();
        },
      ),
      _MenuItem(
        icon: Icons.description,
        title: 'Custom Elements Demo',
        pageBuilder: (context) {
          return const CustomElementsExampleEditor();
        },
      ),
      _MenuItem(
        icon: Icons.description,
        title: 'Switch Docs Demo',
        pageBuilder: (context) {
          return SwitchDocumentDemo();
        },
      ),
      _MenuItem(
        icon: Icons.description,
        title: 'Lose Focus Demo',
        pageBuilder: (context) {
          return LoseFocusDemo();
        },
      ),
      _MenuItem(
        icon: Icons.description,
        title: 'Markdown Serialization Demo',
        pageBuilder: (context) {
          return MarkdownSerializationDemo();
        },
      ),
      _MenuItem(
        icon: Icons.description,
        title: 'RTL Demo',
        pageBuilder: (context) {
          return RTLDemo();
        },
      ),
    ],
  ),
  _MenuGroup(
    title: 'PIECES',
    items: [
      _MenuItem(
        icon: Icons.text_snippet,
        title: 'Paragraphs',
        pageBuilder: (context) {
          return ParagraphsDemo();
        },
      ),
    ],
  ),
  _MenuGroup(
    title: 'INFRASTRUCTURE',
    items: [
      _MenuItem(
        icon: Icons.text_fields,
        title: 'SuperTextField',
        pageBuilder: (context) {
          return TextFieldDemo();
        },
      ),
      _MenuItem(
        icon: Icons.text_fields,
        title: 'SuperSelectableText',
        pageBuilder: (context) {
          return SelectableTextDemo();
        },
      ),
      _MenuItem(
        icon: Icons.text_fields,
        title: 'Attributed Text',
        pageBuilder: (context) {
          return AttributedTextDemo();
        },
      ),
    ],
  ),
];

class _MenuGroup {
  const _MenuGroup({
    this.title,
    required this.items,
  });

  final String? title;
  final List<_MenuItem> items;
}

class _MenuItem {
  const _MenuItem({
    required this.icon,
    required this.title,
    required this.pageBuilder,
  });

  final IconData icon;
  final String title;
  final WidgetBuilder pageBuilder;
}

class _DrawerHeader extends StatelessWidget {
  const _DrawerHeader({
    Key? key,
    required this.title,
  }) : super(key: key);

  final String? title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 16, bottom: 4),
      child: Text(
        title!,
        style: const TextStyle(
          color: Color(0xFF444444),
          fontSize: 10,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class _DrawerButton extends StatelessWidget {
  const _DrawerButton({
    Key? key,
    required this.icon,
    required this.title,
    this.isSelected = false,
    required this.onPressed,
  }) : super(key: key);

  final IconData icon;
  final String title;
  final bool isSelected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        style: ButtonStyle(
            backgroundColor: MaterialStateColor.resolveWith((states) {
              if (isSelected) {
                return const Color(0xFFBBBBBB);
              }

              if (states.contains(MaterialState.hovered)) {
                return Colors.grey.withOpacity(0.1);
              }

              return Colors.transparent;
            }),
            // splashFactory: NoSplash.splashFactory,
            foregroundColor:
                MaterialStateColor.resolveWith((states) => isSelected ? Colors.white : const Color(0xFFBBBBBB)),
            elevation: MaterialStateProperty.resolveWith((states) => 0),
            padding: MaterialStateProperty.resolveWith((states) => const EdgeInsets.all(16))),
        onPressed: isSelected ? null : onPressed,
        child: Row(
          children: [
            const SizedBox(width: 8),
            Icon(
              icon,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Text(title),
            ),
          ],
        ),
      ),
    );
  }
}
