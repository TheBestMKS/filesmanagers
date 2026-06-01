import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

class VaultCrypto {
  VaultCrypto._();

  static const xchacha20Poly1305 = 'xchacha20-poly1305';
  static const aes256Gcm = 'aes-256-gcm';

  static final Xchacha20 _xchacha = Xchacha20.poly1305Aead();
  static final AesGcm _aesGcm = AesGcm.with256bits();
  static final Argon2id _kdf = Argon2id(
    parallelism: 1,
    memory: 4096,
    iterations: 2,
    hashLength: 32,
  );

  static Uint8List randomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
        List<int>.generate(length, (_) => random.nextInt(256)));
  }

  static Future<SecretKey> deriveKey(String password, List<int> salt) {
    return _kdf.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: salt,
    );
  }

  static Future<String> passwordDigest(String password, List<int> salt) async {
    final key = await deriveKey(password, salt);
    final bytes = await key.extractBytes();
    return base64UrlEncode(bytes);
  }

  static Future<Uint8List> encryptBytes(
    List<int> clearBytes, {
    required String password,
    required List<int> salt,
    List<int> aad = const [],
    String algorithm = xchacha20Poly1305,
  }) async {
    final key = await deriveKey(password, salt);
    final box = await _cipherFor(algorithm)
        .encrypt(clearBytes, secretKey: key, aad: aad);
    return _packBox(box);
  }

  static Future<Uint8List> encryptBytesWithKey(
    List<int> clearBytes, {
    required SecretKey key,
    List<int> aad = const [],
    String algorithm = xchacha20Poly1305,
  }) async {
    final box = await _cipherFor(algorithm)
        .encrypt(clearBytes, secretKey: key, aad: aad);
    return _packBox(box);
  }

  static Future<Uint8List> decryptBytes(
    List<int> packedBox, {
    required String password,
    required List<int> salt,
    List<int> aad = const [],
    String algorithm = xchacha20Poly1305,
  }) async {
    final key = await deriveKey(password, salt);
    final box = _unpackBox(
      Uint8List.fromList(packedBox),
      nonceLength: nonceLengthFor(algorithm),
    );
    final clear =
        await _cipherFor(algorithm).decrypt(box, secretKey: key, aad: aad);
    return Uint8List.fromList(clear);
  }

  static Future<Uint8List> decryptBytesWithKey(
    List<int> packedBox, {
    required SecretKey key,
    List<int> aad = const [],
    String algorithm = xchacha20Poly1305,
  }) async {
    final box = _unpackBox(
      Uint8List.fromList(packedBox),
      nonceLength: nonceLengthFor(algorithm),
    );
    final clear =
        await _cipherFor(algorithm).decrypt(box, secretKey: key, aad: aad);
    return Uint8List.fromList(clear);
  }

  static int nonceLengthFor(String algorithm) => switch (algorithm) {
        aes256Gcm => 12,
        _ => 24,
      };

  static Cipher _cipherFor(String algorithm) => switch (algorithm) {
        aes256Gcm => _aesGcm,
        xchacha20Poly1305 => _xchacha,
        _ => throw FormatException('Unsupported cipher: $algorithm'),
      };

  static Future<Map<String, Object?>> encryptTextEnvelope(
    String clearText, {
    required String password,
  }) async {
    final salt = randomBytes(16);
    final encrypted = await encryptBytes(
      utf8.encode(clearText),
      password: password,
      salt: salt,
      aad: utf8.encode('securevault.settings.v1'),
    );
    return <String, Object?>{
      'schema': 'securevault.encryptedText.v1',
      'kdf': 'argon2id',
      'cipher': 'xchacha20-poly1305',
      'salt': base64UrlEncode(salt),
      'box': base64UrlEncode(encrypted),
    };
  }

  static Future<String> decryptTextEnvelope(
    Map<String, Object?> envelope, {
    required String password,
  }) async {
    final saltText = envelope['salt'] as String?;
    final boxText = envelope['box'] as String?;
    if (saltText == null || boxText == null) {
      throw const FormatException('Incomplete encrypted text envelope.');
    }
    final clear = await decryptBytes(
      base64Url.decode(boxText),
      password: password,
      salt: base64Url.decode(saltText),
      aad: utf8.encode('securevault.settings.v1'),
    );
    return utf8.decode(clear);
  }

  static Uint8List _packBox(SecretBox box) {
    return Uint8List.fromList(<int>[
      ...box.nonce,
      ...box.cipherText,
      ...box.mac.bytes,
    ]);
  }

  static SecretBox _unpackBox(Uint8List bytes, {required int nonceLength}) {
    const macLength = 16;
    if (bytes.length < nonceLength + macLength) {
      throw const FormatException('Encrypted box is too small.');
    }
    final nonce = bytes.sublist(0, nonceLength);
    final mac = bytes.sublist(bytes.length - macLength);
    final cipherText = bytes.sublist(nonceLength, bytes.length - macLength);
    return SecretBox(cipherText, nonce: nonce, mac: Mac(mac));
  }
}
