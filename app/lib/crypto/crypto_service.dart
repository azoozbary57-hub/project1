import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

class EncryptedPayload {
  final String ciphertext; // base64: AES-GCM cipherText + 16-byte MAC
  final String iv; // base64: 12-byte nonce

  const EncryptedPayload({required this.ciphertext, required this.iv});
}

class CryptoService {
  final SecretKey encryptionKey;
  final _algorithm = AesGcm.with256bits();

  CryptoService(this.encryptionKey);

  Future<EncryptedPayload> encryptJson(Map<String, Object?> data) async {
    final plaintext = utf8.encode(jsonEncode(data));
    final nonce = _algorithm.newNonce();
    final secretBox = await _algorithm.encrypt(
      plaintext,
      secretKey: encryptionKey,
      nonce: nonce,
    );
    final combined = Uint8List.fromList([
      ...secretBox.cipherText,
      ...secretBox.mac.bytes,
    ]);
    return EncryptedPayload(
      ciphertext: base64Encode(combined),
      iv: base64Encode(nonce),
    );
  }

  Future<Map<String, Object?>> decryptJson(EncryptedPayload payload) async {
    final combined = base64Decode(payload.ciphertext);
    final nonce = base64Decode(payload.iv);
    final macBytes = combined.sublist(combined.length - 16);
    final cipherText = combined.sublist(0, combined.length - 16);
    final secretBox = SecretBox(cipherText, nonce: nonce, mac: Mac(macBytes));
    final plaintext = await _algorithm.decrypt(
      secretBox,
      secretKey: encryptionKey,
    );
    return jsonDecode(utf8.decode(plaintext)) as Map<String, Object?>;
  }
}
