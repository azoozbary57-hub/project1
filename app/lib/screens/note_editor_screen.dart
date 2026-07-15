import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../db/app_database.dart';
import '../models/note.dart';
import '../sync/sync_service.dart';

class NoteEditorScreen extends StatefulWidget {
  final NotesRepository repo;
  final SyncService syncService;
  final Note? note;
  final String? highlightQuery;

  const NoteEditorScreen({
    super.key,
    required this.repo,
    required this.syncService,
    this.note,
    this.highlightQuery,
  });

  @override
  State<NoteEditorScreen> createState() => _NoteEditorScreenState();
}

class _NoteEditorScreenState extends State<NoteEditorScreen> {
  late final TextEditingController _titleController;
  late final TextEditingController _bodyController;
  final _bodyFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.note?.title ?? '');
    _bodyController = TextEditingController(text: widget.note?.body ?? '');
    _jumpToSearchMatch();
  }

  void _jumpToSearchMatch() {
    final query = widget.highlightQuery?.trim();
    if (query == null || query.isEmpty) return;
    final body = _bodyController.text;
    final index = body.toLowerCase().indexOf(query.toLowerCase());
    if (index == -1) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _bodyFocusNode.requestFocus();
      _bodyController.selection = TextSelection(
        baseOffset: index,
        extentOffset: index + query.length,
      );
    });
  }

  @override
  void dispose() {
    _titleController.dispose();
    _bodyController.dispose();
    _bodyFocusNode.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final title = _titleController.text.trim();
    final body = _bodyController.text;
    if (title.isEmpty && body.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    final note = Note(
      id: widget.note?.id ?? const Uuid().v4(),
      title: title,
      body: body,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await widget.repo.put(note);
    await widget.syncService.pushNote(note);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final id = widget.note?.id;
    if (id == null) return;
    await widget.repo.delete(id);
    final deletedNote = await widget.repo.getById(id);
    if (deletedNote != null) {
      await widget.syncService.pushNote(deletedNote);
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        actions: [
          if (widget.note != null)
            IconButton(icon: const Icon(Icons.delete_outline), onPressed: _delete),
          IconButton(icon: const Icon(Icons.check), onPressed: _save),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _titleController,
              style: Theme.of(context).textTheme.titleLarge,
              decoration: const InputDecoration(
                hintText: 'العنوان',
                border: InputBorder.none,
              ),
            ),
            const Divider(),
            Expanded(
              child: TextField(
                controller: _bodyController,
                focusNode: _bodyFocusNode,
                decoration: const InputDecoration(
                  hintText: 'اكتب ملاحظتك هنا...',
                  border: InputBorder.none,
                ),
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
