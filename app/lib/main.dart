import 'package:flutter/material.dart';

import 'db/app_database.dart';
import 'screens/home_screen.dart';
import 'sync/sync_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const NotesSyncApp());
}

class NotesSyncApp extends StatefulWidget {
  const NotesSyncApp({super.key});

  @override
  State<NotesSyncApp> createState() => _NotesSyncAppState();
}

class _NotesSyncAppState extends State<NotesSyncApp> {
  final repo = NotesRepository();
  late final SyncService syncService = SyncService(repo);
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    syncService.restore().whenComplete(() {
      if (mounted) setState(() => _ready = true);
    });
  }

  @override
  void dispose() {
    syncService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Notes Sync',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.teal,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: _ready
          ? HomeScreen(repo: repo, syncService: syncService)
          : const Scaffold(body: Center(child: CircularProgressIndicator())),
    );
  }
}
