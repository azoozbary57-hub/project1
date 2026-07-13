import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// A pairing secret is a random value shared out-of-band (QR code or typed
/// code) between devices. The server never receives it: devices derive a
/// [roomId] (used only for routing on the relay) and an [encryptionKey]
/// (used only locally to encrypt/decrypt notes) from it via HMAC-SHA256.
/// A relay operator therefore never has enough information to read notes.
class PairingSecret {
  final Uint8List bytes;

  const PairingSecret(this.bytes);

  factory PairingSecret.generate() {
    final random = Random.secure();
    final bytes = Uint8List(16);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = random.nextInt(256);
    }
    return PairingSecret(bytes);
  }

  /// Human/QR-friendly form, e.g. "a1b2-c3d4-e5f6-0718-2938-abcd-1234-5678".
  String get code {
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final groups = <String>[];
    for (var i = 0; i < hex.length; i += 4) {
      groups.add(hex.substring(i, min(i + 4, hex.length)));
    }
    return groups.join('-');
  }

  static PairingSecret? tryParse(String input) {
    final hex = input.replaceAll(RegExp(r'[^a-fA-F0-9]'), '').toLowerCase();
    if (hex.length != 32) return null;
    final bytes = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return PairingSecret(bytes);
  }

  Future<String> deriveRoomId() async {
    final mac = await Hmac.sha256().calculateMac(
      'room'.codeUnits,
      secretKey: SecretKey(bytes),
    );
    return mac.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<SecretKey> deriveEncryptionKey() async {
    final mac = await Hmac.sha256().calculateMac(
      'enc'.codeUnits,
      secretKey: SecretKey(bytes),
    );
    return SecretKey(mac.bytes);
  }
}
