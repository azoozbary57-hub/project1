import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../crypto/pairing.dart';
import '../sync/sync_service.dart';
import 'qr_scan_screen.dart';

class PairingScreen extends StatefulWidget {
  final SyncService syncService;

  const PairingScreen({super.key, required this.syncService});

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> with SingleTickerProviderStateMixin {
  final _createServerController = TextEditingController(text: 'http://');
  final _joinServerController = TextEditingController(text: 'http://');
  final _joinCodeController = TextEditingController();
  PairingSecret? _createdSecret;
  String? _error;
  bool _busy = false;

  bool get _canScan =>
      defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS;

  @override
  void dispose() {
    _createServerController.dispose();
    _joinServerController.dispose();
    _joinCodeController.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final secret = PairingSecret.generate();
      await widget.syncService.configure(
        serverBaseUrl: _createServerController.text,
        secret: secret,
      );
      setState(() => _createdSecret = secret);
    } catch (e) {
      setState(() => _error = 'تعذر الإنشاء: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _join([String? codeOverride]) async {
    final secret = PairingSecret.tryParse(codeOverride ?? _joinCodeController.text);
    if (secret == null) {
      setState(() => _error = 'رمز الاقتران غير صحيح');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.syncService.configure(
        serverBaseUrl: _joinServerController.text,
        secret: secret,
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      setState(() => _error = 'تعذر الانضمام: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _scan() async {
    final result = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const QrScanScreen()),
    );
    if (result != null) {
      _joinCodeController.text = result;
      await _join(result);
    }
  }

  Future<void> _unpair() async {
    await widget.syncService.unpair();
    if (mounted) setState(() => _createdSecret = null);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.syncService.isConfigured && _createdSecret == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('المزامنة')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.cloud_done_outlined, size: 64),
              const SizedBox(height: 16),
              const Text('هذا الجهاز مرتبط بمجموعة مزامنة.'),
              const SizedBox(height: 24),
              FilledButton.tonal(
                onPressed: _unpair,
                child: const Text('إلغاء الارتباط'),
              ),
            ],
          ),
        ),
      );
    }

    if (_createdSecret != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('رمز الاقتران')),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const Text('امسح هذا الرمز من الجهاز الآخر، أو أدخل الكود يدوياً:'),
              const SizedBox(height: 16),
              QrImageView(data: _createdSecret!.code, size: 220),
              const SizedBox(height: 16),
              SelectableText(
                _createdSecret!.code,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 16),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                icon: const Icon(Icons.copy),
                label: const Text('نسخ الكود'),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: _createdSecret!.code));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('تم نسخ الكود')),
                  );
                },
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('تم'),
              ),
            ],
          ),
        ),
      );
    }

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('ربط الأجهزة'),
          bottom: const TabBar(tabs: [Tab(text: 'إنشاء مجموعة'), Tab(text: 'الانضمام لمجموعة')]),
        ),
        body: TabBarView(
          children: [
            _buildCreateTab(),
            _buildJoinTab(),
          ],
        ),
      ),
    );
  }

  Widget _buildCreateTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'أنشئ مجموعة مزامنة جديدة على هذا الجهاز، ثم اربط بقية أجهزتك بها.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _createServerController,
            decoration: const InputDecoration(
              labelText: 'رابط سيرفر المزامنة',
              hintText: 'http://192.168.1.10:8787',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _busy ? null : _create,
            child: _busy ? const CircularProgressIndicator() : const Text('إنشاء'),
          ),
        ],
      ),
    );
  }

  Widget _buildJoinTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('أدخل رابط نفس السيرفر ورمز الاقتران الظاهر على الجهاز الآخر.'),
          const SizedBox(height: 16),
          TextField(
            controller: _joinServerController,
            decoration: const InputDecoration(
              labelText: 'رابط سيرفر المزامنة',
              hintText: 'http://192.168.1.10:8787',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _joinCodeController,
            decoration: const InputDecoration(
              labelText: 'رمز الاقتران',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          if (_canScan)
            OutlinedButton.icon(
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('مسح رمز QR بالكاميرا'),
              onPressed: _busy ? null : _scan,
            ),
          const SizedBox(height: 8),
          if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _busy ? null : () => _join(),
            child: _busy ? const CircularProgressIndicator() : const Text('انضمام'),
          ),
        ],
      ),
    );
  }
}
