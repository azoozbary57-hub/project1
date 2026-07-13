import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../crypto/crypto_service.dart';
import '../crypto/pairing.dart';
import '../db/app_database.dart';
import '../models/note.dart';

const _metaServerUrlKey = 'server_url';
const _metaSecretKey = 'pairing_secret';

/// Keeps the local database in sync with a relay room: pushes local notes,
/// applies incoming ones with last-write-wins, and listens for live pushes
/// from other paired devices while the app is open.
class SyncService {
  final NotesRepository repo;
  final _onRemoteChange = StreamController<void>.broadcast();
  final _onStatusChange = StreamController<SyncStatus>.broadcast();

  Uri? _httpSyncUri;
  Uri? _wsUri;
  CryptoService? _crypto;
  WebSocketChannel? _channel;
  StreamSubscription? _channelSub;
  Timer? _reconnectTimer;
  int _reconnectDelaySeconds = 1;
  SyncStatus _status = SyncStatus.unpaired;

  SyncService(this.repo);

  Stream<void> get onRemoteChange => _onRemoteChange.stream;
  Stream<SyncStatus> get onStatusChange => _onStatusChange.stream;
  SyncStatus get status => _status;
  bool get isConfigured => _crypto != null;

  void _setStatus(SyncStatus s) {
    _status = s;
    _onStatusChange.add(s);
  }

  /// Restores pairing from local storage on app start, if this device has
  /// previously been paired.
  Future<bool> restore() async {
    final serverUrl = await repo.getMeta(_metaServerUrlKey);
    final secretCode = await repo.getMeta(_metaSecretKey);
    if (serverUrl == null || secretCode == null) return false;
    final secret = PairingSecret.tryParse(secretCode);
    if (secret == null) return false;
    await configure(serverBaseUrl: serverUrl, secret: secret, persist: false);
    return true;
  }

  Future<void> configure({
    required String serverBaseUrl,
    required PairingSecret secret,
    bool persist = true,
  }) async {
    final normalized = serverBaseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final roomId = await secret.deriveRoomId();
    _crypto = CryptoService(await secret.deriveEncryptionKey());

    final httpScheme = normalized.startsWith('https://') ? 'https' : 'http';
    final hostAndPort = normalized.replaceFirst(RegExp(r'^https?://'), '');
    _httpSyncUri = Uri.parse('$httpScheme://$hostAndPort/rooms/$roomId/sync');
    final wsScheme = httpScheme == 'https' ? 'wss' : 'ws';
    _wsUri = Uri.parse('$wsScheme://$hostAndPort/ws?room=$roomId');

    if (persist) {
      await repo.setMeta(_metaServerUrlKey, normalized);
      await repo.setMeta(_metaSecretKey, secret.code);
    }

    _connectWebSocket();
    unawaited(syncNow());
  }

  Future<void> unpair() async {
    _reconnectTimer?.cancel();
    await _channelSub?.cancel();
    await _channel?.sink.close();
    _channel = null;
    _crypto = null;
    _httpSyncUri = null;
    _wsUri = null;
    await repo.clearMeta(_metaServerUrlKey);
    await repo.clearMeta(_metaSecretKey);
    _setStatus(SyncStatus.unpaired);
  }

  void _connectWebSocket() {
    if (_wsUri == null) return;
    _setStatus(SyncStatus.connecting);
    try {
      _channel = WebSocketChannel.connect(_wsUri!);
    } catch (_) {
      _scheduleReconnect();
      return;
    }
    _channelSub = _channel!.stream.listen(
      (raw) => _handleWsMessage(raw as String),
      onDone: _scheduleReconnect,
      onError: (_) => _scheduleReconnect(),
      cancelOnError: true,
    );
    _setStatus(SyncStatus.connected);
    _reconnectDelaySeconds = 1;
    unawaited(_sendFullSnapshotOverWs());
  }

  void _scheduleReconnect() {
    _channelSub?.cancel();
    _channel = null;
    if (_wsUri == null) return;
    _setStatus(SyncStatus.disconnected);
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(seconds: _reconnectDelaySeconds), () {
      _reconnectDelaySeconds = (_reconnectDelaySeconds * 2).clamp(1, 30);
      _connectWebSocket();
    });
  }

  Future<Map<String, Object?>> _encodeNote(Note note) async {
    final payload = await _crypto!.encryptJson({'title': note.title, 'body': note.body});
    return {
      'id': note.id,
      'ciphertext': payload.ciphertext,
      'iv': payload.iv,
      'updatedAt': note.updatedAt,
      'deleted': note.deleted,
    };
  }

  Future<void> _sendFullSnapshotOverWs() async {
    if (_channel == null || _crypto == null) return;
    final localNotes = await repo.getAll(includeDeleted: true);
    final wireNotes = await Future.wait(localNotes.map(_encodeNote));
    _channel!.sink.add(jsonEncode({'type': 'sync', 'notes': wireNotes}));
  }

  Future<void> _handleWsMessage(String raw) async {
    final msg = jsonDecode(raw) as Map<String, Object?>;
    final wireNotes = (msg['notes'] as List).cast<Map<String, Object?>>();
    final changed = await _applyRemoteNotes(wireNotes);
    if (changed) _onRemoteChange.add(null);
  }

  Future<bool> _applyRemoteNotes(List<Map<String, Object?>> wireNotes) async {
    var changed = false;
    for (final map in wireNotes) {
      final decrypted = await _crypto!.decryptJson(EncryptedPayload(
        ciphertext: map['ciphertext'] as String,
        iv: map['iv'] as String,
      ));
      final remoteNote = Note(
        id: map['id'] as String,
        title: decrypted['title'] as String,
        body: decrypted['body'] as String,
        updatedAt: map['updatedAt'] as int,
        deleted: map['deleted'] as bool,
      );
      final local = await repo.getById(remoteNote.id);
      if (local == null || remoteNote.updatedAt > local.updatedAt) {
        await repo.put(remoteNote);
        changed = true;
      }
    }
    return changed;
  }

  /// Full-state sync over REST: used on demand (pull-to-refresh, app resume)
  /// and as a fallback when the realtime WebSocket isn't connected.
  Future<void> syncNow() async {
    if (_httpSyncUri == null || _crypto == null) return;
    try {
      final localNotes = await repo.getAll(includeDeleted: true);
      final wireNotes = await Future.wait(localNotes.map(_encodeNote));
      final response = await http.post(
        _httpSyncUri!,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'notes': wireNotes}),
      );
      if (response.statusCode != 200) return;
      final body = jsonDecode(response.body) as Map<String, Object?>;
      final wireResult = (body['notes'] as List).cast<Map<String, Object?>>();
      final changed = await _applyRemoteNotes(wireResult);
      if (changed) _onRemoteChange.add(null);
    } catch (_) {
      // Offline or relay unreachable: local edits stay queued and will sync
      // next time syncNow() runs or the WebSocket reconnects.
    }
  }

  /// Pushes a single local change immediately, preferring the live socket.
  Future<void> pushNote(Note note) async {
    if (_crypto == null) return;
    final wireNote = await _encodeNote(note);
    if (_channel != null && _status == SyncStatus.connected) {
      _channel!.sink.add(jsonEncode({
        'type': 'push',
        'notes': [wireNote],
      }));
    } else {
      unawaited(syncNow());
    }
  }

  void dispose() {
    _reconnectTimer?.cancel();
    _channelSub?.cancel();
    _channel?.sink.close();
    _onRemoteChange.close();
    _onStatusChange.close();
  }
}

enum SyncStatus { unpaired, connecting, connected, disconnected }
