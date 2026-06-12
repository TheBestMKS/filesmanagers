import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:filesmanagers/src/explorer/file_explorer_repository.dart';
import 'package:filesmanagers/src/ffi/crypt_bindings.dart';

void main() {
  test('app-created crypt file can be preview-decrypted', () async {
    final temp = await Directory.systemTemp.createTemp('filesmanagers_test_');
    addTearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });

    final source = File('${temp.path}${Platform.pathSeparator}note.txt');
    await source.writeAsString('secret note');

    final repository = FileExplorerRepository(CryptBindings());
    final encrypted = await repository.encryptFileToDirectory(
      source,
      temp,
      password: 'passphrase',
    );
    final preview =
        await repository.previewFile(encrypted.path, password: 'passphrase');

    expect(preview.decrypted, isTrue);
    expect(preview.title, 'note.txt');
    expect(preview.text, contains('secret note'));
  });
}
