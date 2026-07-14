import 'package:flutter/material.dart';

import '../db/app_database.dart';
import '../models/note.dart';
import '../sync/sync_service.dart';

class TrashScreen extends StatefulWidget {
  final NotesRepository repo;
  final SyncService syncService;

  const TrashScreen({super.key, required this.repo, required this.syncService});

  @override
  State<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends State<TrashScreen> {
  List<Note> _notes = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final notes = await widget.repo.getTrash();
    if (mounted) setState(() => _notes = notes);
  }

  Future<void> _restore(Note note) async {
    await widget.repo.restore(note.id);
    final restored = await widget.repo.getById(note.id);
    if (restored != null) await widget.syncService.pushNote(restored);
    _load();
  }

  Future<void> _deleteForever(Note note) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('حذف نهائي'),
        content: Text('حذف "${note.title.isEmpty ? '(بدون عنوان)' : note.title}" نهائياً؟ لا يمكن التراجع.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('إلغاء')),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('حذف نهائياً')),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.repo.purge(note.id);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('سلة المحذوفات')),
      body: _notes.isEmpty
          ? const Center(child: Text('سلة المحذوفات فارغة.'))
          : ListView.builder(
              itemCount: _notes.length,
              itemBuilder: (context, index) {
                final note = _notes[index];
                return ListTile(
                  title: Text(note.title.isEmpty ? '(بدون عنوان)' : note.title),
                  subtitle: Text(note.body, maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'استعادة',
                        icon: const Icon(Icons.restore),
                        onPressed: () => _restore(note),
                      ),
                      IconButton(
                        tooltip: 'حذف نهائي',
                        icon: const Icon(Icons.delete_forever_outlined),
                        onPressed: () => _deleteForever(note),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}
