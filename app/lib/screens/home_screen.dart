import 'dart:async';

import 'package:flutter/material.dart';

import '../db/app_database.dart';
import '../models/note.dart';
import '../sync/sync_service.dart';
import 'note_editor_screen.dart';
import 'pairing_screen.dart';
import 'trash_screen.dart';

class HomeScreen extends StatefulWidget {
  final NotesRepository repo;
  final SyncService syncService;

  const HomeScreen({super.key, required this.repo, required this.syncService});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<Note> _notes = [];
  StreamSubscription? _remoteSub;
  StreamSubscription? _statusSub;
  SyncStatus _status = SyncStatus.unpaired;

  @override
  void initState() {
    super.initState();
    _status = widget.syncService.status;
    _load();
    _remoteSub = widget.syncService.onRemoteChange.listen((_) => _load());
    _statusSub = widget.syncService.onStatusChange.listen((s) {
      if (mounted) setState(() => _status = s);
    });
  }

  @override
  void dispose() {
    _remoteSub?.cancel();
    _statusSub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final notes = await widget.repo.getAll();
    if (mounted) setState(() => _notes = notes);
  }

  IconData get _statusIcon {
    switch (_status) {
      case SyncStatus.unpaired:
        return Icons.link_off;
      case SyncStatus.connecting:
        return Icons.sync;
      case SyncStatus.connected:
        return Icons.cloud_done_outlined;
      case SyncStatus.disconnected:
        return Icons.cloud_off_outlined;
    }
  }

  String get _statusLabel {
    switch (_status) {
      case SyncStatus.unpaired:
        return 'غير مرتبط بأي جهاز آخر';
      case SyncStatus.connecting:
        return 'جاري الاتصال...';
      case SyncStatus.connected:
        return 'متزامن';
      case SyncStatus.disconnected:
        return 'غير متصل، سيعاد الاتصال تلقائياً';
    }
  }

  Future<void> _openPairing() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PairingScreen(syncService: widget.syncService),
    ));
    if (mounted) setState(() {});
  }

  Future<void> _openTrash() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => TrashScreen(repo: widget.repo, syncService: widget.syncService),
    ));
    _load();
  }

  Future<void> _openEditor([Note? note]) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => NoteEditorScreen(
        repo: widget.repo,
        syncService: widget.syncService,
        note: note,
      ),
    ));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('الملاحظات'),
        actions: [
          IconButton(
            tooltip: 'سلة المحذوفات',
            icon: const Icon(Icons.delete_outline),
            onPressed: _openTrash,
          ),
          IconButton(
            tooltip: _statusLabel,
            icon: Icon(_statusIcon),
            onPressed: _openPairing,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await widget.syncService.syncNow();
          await _load();
        },
        child: _notes.isEmpty
            ? LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: constraints.maxHeight),
                    child: const Center(child: Text('لا توجد ملاحظات بعد. اضغط + للإضافة.')),
                  ),
                ),
              )
            : ListView.builder(
                itemCount: _notes.length,
                itemBuilder: (context, index) {
                  final note = _notes[index];
                  return ListTile(
                    title: Text(note.title.isEmpty ? '(بدون عنوان)' : note.title),
                    subtitle: Text(
                      note.body,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => _openEditor(note),
                  );
                },
              ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openEditor(),
        child: const Icon(Icons.add),
      ),
    );
  }
}
