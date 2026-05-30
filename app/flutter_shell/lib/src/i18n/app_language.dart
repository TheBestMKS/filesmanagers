import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../storage/app_paths.dart';
import '../security/security_settings.dart';

class AppLanguage {
  const AppLanguage({
    required this.code,
    required this.name,
    required this.appTitle,
    required this.strings,
    this.sourcePath,
  });

  final String code;
  final String name;
  final String appTitle;
  final Map<String, String> strings;
  final String? sourcePath;

  String t(String key) => strings[key] ?? _englishStrings[key] ?? key;

  static const russianTitle = 'Защищенное хранилище файов';
  static const englishTitle = 'Secure File Vault';

  static const _englishStrings = <String, String>{
    'app.title': englishTitle,
    'app.runtime.offline': 'Native core offline',
    'about.title': 'About',
    'about.version': 'Version',
    'about.description':
        'Protected explorer, encrypted previews, language packs, and native vault core details.',
    'nav.explorer': 'Explorer',
    'nav.gallery': 'Gallery',
    'nav.music': 'Music',
    'nav.video': 'Video',
    'nav.documents': 'Documents',
    'nav.torrent': 'Torrent',
    'nav.settings': 'Settings',
    'recent.title': 'Recent',
    'recent.open.all': 'Show all recent files',
    'recent.remove': 'Remove from recent',
    'recent.missing.title': 'Recent file is unavailable',
    'recent.missing.body':
        'The file does not exist or is currently unavailable. Remove it from recent files?',
    'recent.missing.file': 'Unavailable recent file',
    'favorites.title': 'FAVORITES',
    'favorites.add': 'Add to favorites',
    'favorites.remove': 'Remove from favorites',
    'favorites.missing': 'Favorite path is unavailable.',
    'locations.heading': 'LOCATIONS',
    'lock.prompt': 'Enter the application password.',
    'lock.failed': 'Failed login attempts',
    'common.password': 'Password',
    'common.cancel': 'Cancel',
    'common.open': 'Open',
    'common.ok': 'OK',
    'common.save': 'Save settings',
    'common.saving': 'Saving...',
    'common.execute': 'Run',
    'common.path': 'Path',
    'common.target.folder': 'Target folder',
    'explorer.choose.location': 'Choose a location',
    'explorer.choose.location.left': 'Choose a location on the left.',
    'explorer.empty': 'Folder is empty.',
    'explorer.access.error': 'Access denied or read error:',
    'explorer.up': 'Up',
    'explorer.refresh': 'Refresh',
    'explorer.upload': 'Upload',
    'explorer.download': 'Download',
    'explorer.create': 'Create',
    'explorer.encrypt': 'Encrypt file',
    'explorer.copy': 'Copy',
    'explorer.cut': 'Cut',
    'explorer.paste': 'Paste',
    'explorer.delete': 'Delete',
    'explorer.rename': 'Rename',
    'explorer.properties': 'Properties',
    'explorer.name': 'Name',
    'explorer.type': 'Type',
    'explorer.size': 'Size, bytes',
    'explorer.modified': 'Modified',
    'explorer.exists': 'Exists',
    'explorer.delete.confirm': 'Delete this file or folder?',
    'explorer.folder.container': 'Create encrypted container from folder',
    'explorer.folder.encrypt': 'Encrypt files',
    'explorer.folder.decrypt': 'Decrypt files',
    'explorer.send': 'Send',
    'explorer.unzip': 'Extract ZIP',
    'explorer.folder': 'Folder',
    'path.edit': 'Edit path',
    'path.unavailable': 'Path is unavailable.',
    'search.title': 'Search',
    'search.query': 'Search text',
    'search.apply': 'Apply',
    'search.clear': 'Clear',
    'search.filters': 'Search filters',
    'search.filters.note':
        'The search box filters by name now. Duration/date/size filters are reserved in the UI and will be wired into indexed search next.',
    'create.plain': 'Plain file',
    'create.encrypted.plain': 'Encrypted file',
    'create.csv': 'CSV table',
    'create.encrypted.csv': 'Encrypted CSV table',
    'create.image': 'Image file',
    'create.encrypted.image': 'Encrypted image file',
    'create.csv.separator': 'CSV separator',
    'create.csv.separator.note': r'Default is ;. Use \t or tab for tabulation.',
    'create.image.format': 'Image format',
    'create.image.width': 'Width',
    'create.image.height': 'Height',
    'create.image.background': 'Background color',
    'create.image.transparent': 'Transparent background',
    'preview.choose.file': 'Choose a file to preview.',
    'preview.open.password': 'Open with password',
    'preview.external': 'Open in another app',
    'preview.window': 'Open full window',
    'preview.hide': 'Hide preview',
    'preview.show': 'Show preview',
    'preview.container': 'Container',
    'preview.external.warning.title': 'Disclosure warning',
    'preview.external.warning':
        'The file can be exposed to another application, temporary files, recent-file lists, thumbnails, or system caches. Continue only if you trust that app.',
    'preview.external.temp': 'Decrypted copy prepared for external opening.',
    'transfer.upload.title': 'Upload file',
    'transfer.upload.encrypted': 'Upload encrypted',
    'transfer.upload.plain': 'Upload decrypted/plain',
    'transfer.download.title': 'Download file',
    'transfer.download.encrypted': 'Download encrypted',
    'transfer.download.plain': 'Download decrypted/plain',
    'transfer.source.path': 'Source file path',
    'transfer.password': 'Password for encryption/decryption',
    'transfer.delete.source': 'Delete source file after operation',
    'encrypt.title': 'Encrypt selected file',
    'encrypt.mode.common': 'Common key',
    'encrypt.mode.unique': 'Unique key',
    'encrypt.common.autokey': 'Common key will be used automatically',
    'encrypt.common.autokey.note':
        'No separate encrypted-file password is configured, so SecureVault does not ask for the common key again.',
    'encrypt.password.common': 'Common encryption password',
    'encrypt.password.unique': 'Unique encryption password',
    'encrypt.delete.source': 'Delete original file after encryption',
    'encrypt.configure.title': 'Common encryption is not configured',
    'encrypt.configure.body':
        'Set a common encryption password in Settings before encrypting with the common key.',
    'encrypt.configure.open': 'Open settings',
    'encrypt.select.file': 'Choose a regular file to encrypt.',
    'encrypt.already.encrypted': 'This file is already encrypted.',
    'encrypt.bad.common.password': 'Common encryption password is incorrect.',
    'decrypt.title': 'Decrypt selected file',
    'decrypt.action': 'Decrypt file',
    'decrypt.password': 'Password for decryption',
    'decrypt.delete.source': 'Delete encrypted source after decryption',
    'decrypt.select.file': 'Choose an encrypted file to decrypt.',
    'settings.title': 'Security settings',
    'settings.description':
        'Configure the application password, encrypted-file password, common encryption key, language, and screen protection.',
    'settings.passwords': 'Passwords',
    'settings.app.password.current': 'Current app password',
    'settings.app.password.new': 'New app password (empty = keep current)',
    'settings.app.password.repeat': 'Repeat new app password',
    'settings.app.password.mismatch': 'New app passwords do not match.',
    'settings.app.password': 'App password',
    'settings.file.password.separate': 'Separate password for encrypted files',
    'settings.file.password.current': 'Current encrypted-file password',
    'settings.file.password.new': 'New file password (empty = keep current)',
    'settings.file.password.repeat': 'Repeat new encrypted-file password',
    'settings.file.password.mismatch':
        'New encrypted-file passwords do not match.',
    'settings.file.password': 'Encrypted-file password',
    'settings.common.encryption': 'Common encryption key',
    'settings.common.algorithm': 'Common encryption algorithm',
    'settings.common.password.new':
        'New common encryption password (empty = keep current)',
    'settings.common.keyfile': 'Common key file path',
    'settings.common.keyfile.note':
        'When filled and the password field is empty, the common key is derived from this file content.',
    'settings.common.status.ready': 'Common encryption is configured.',
    'settings.common.status.empty': 'Common encryption is not configured yet.',
    'settings.common.reveal': 'Show current common key',
    'settings.common.reveal.note':
        'Requires the app password or encrypted-file password when configured.',
    'settings.common.current.key': 'Current common encryption key',
    'settings.remembering': 'Remembering and cleanup',
    'settings.remember.file.password': 'Remember encrypted-file password',
    'settings.file.password.grace':
        'Do not require encrypted-file password again for N seconds (0 = always ask)',
    'settings.recent': 'Recent files',
    'settings.recent.remember': 'Remember recently opened files',
    'settings.recent.sidebar.count': 'Recent files shown in the sidebar',
    'settings.recent.remember.count': 'Recent files kept in history',
    'settings.favorite.sidebar.count': 'Favorites shown in the sidebar',
    'settings.explorer.view': 'Explorer view',
    'settings.decrypt.names':
        'Decrypt encrypted names in the explorer when possible',
    'settings.auto.dpi': 'Auto-adjust file text and icon size by device DPI',
    'settings.file.text.scale': 'File text scale',
    'settings.file.icon.scale': 'File icon scale',
    'settings.media.sections': 'Media sections',
    'settings.exclusions': 'Exclusions',
    'settings.paths.one.per.line': 'One path, folder, or mask per line.',
    'settings.torrent.enabled': 'Enable torrent section',
    'settings.torrent.disabled': 'Torrent section is disabled in settings.',
    'settings.wipe.failed': 'Delete remembered passwords on failed login',
    'settings.clear.now': 'Delete remembered passwords now',
    'settings.screen': 'Screen protection',
    'settings.block.capture':
        'Block screenshots and screen recording where the platform allows it',
    'settings.block.capture.note':
        'Android uses FLAG_SECURE. Windows/Linux cannot reliably detect screen capture from Flutter, so SecureVault warns before external disclosure.',
    'settings.language': 'Language',
    'settings.language.select': 'Interface language',
    'settings.language.ru': 'Russian',
    'settings.language.en': 'English',
    'settings.language.custom': 'Custom JSON file',
    'settings.language.path': 'Custom language JSON path',
    'settings.language.validate': 'Validate language file',
    'settings.language.install': 'Add language to program',
    'settings.language.export': 'Export English sample',
    'settings.associations': 'File associations',
    'settings.associations.hint':
        'One per line: .ext=command. Example: .psd=C:\\Program Files\\App\\app.exe',
    'settings.saved': 'Settings saved.',
    'settings.remembered.deleted': 'Remembered passwords deleted.',
    'settings.language.valid': 'Language file is valid.',
    'settings.language.invalid': 'Language file is invalid:',
    'settings.language.exported': 'Sample language file exported:',
    'settings.language.installed': 'Language file installed:',
    'settings.plugins': 'Plugins',
    'settings.plugins.note':
        'Install plugin ZIP archives. Built-in WebDAV templates are created for Yandex Disk and Nextcloud.',
    'settings.plugin.zip.path': 'Plugin ZIP path',
    'settings.plugin.install': 'Install plugin ZIP',
    'settings.plugin.installed': 'Plugin installed:',
    'snack.bad.password':
        'Incorrect password. Remembered file passwords were cleared.',
    'snack.file.password.mismatch':
        'Encrypted-file password does not match settings.',
    'snack.copied': 'Copied to clipboard.',
    'snack.cut': 'Cut to clipboard.',
    'snack.pasted': 'Pasted:',
    'snack.deleted': 'Deleted.',
    'snack.renamed': 'Renamed:',
    'snack.operation.error': 'Operation error:',
    'snack.created': 'Created:',
    'snack.unzipped': 'Extracted:',
    'snack.send.next':
        'Send action is prepared in the context menu and needs a platform share adapter.',
    'snack.folder.actions.next':
        'Folder encryption/container actions are present in the menu and will be wired to recursive/container processing in the next version.',
    'snack.uploaded': 'Uploaded:',
    'snack.upload.error': 'Upload error:',
    'snack.download.select': 'Choose a file to download.',
    'snack.downloaded': 'Downloaded:',
    'snack.download.error': 'Download error:',
    'snack.encrypted': 'Encrypted:',
    'snack.encrypt.error': 'Encryption error:',
    'snack.decrypted': 'Decrypted:',
    'snack.decrypt.error': 'Decryption error:',
    'provider.reserved':
        'This location is reserved for an SMB/SSH/FTP/SFTP network provider. A transport adapter and connection form are required.',
    'provider.plugin': 'JSON plugin found:',
    'provider.plugin.detail':
        'It describes auth, listFiles, fileInfo, and fileStream. The request executor is connected through a separate adapter.',
  };

  static const _russianStrings = <String, String>{
    'app.title': russianTitle,
    'app.runtime.offline': 'Нативное ядро недоступно',
    'about.title': 'О программе',
    'about.version': 'Версия',
    'about.description':
        'Защищенный проводник, просмотр зашифрованных файлов, языковые пакеты и сведения о нативном ядре хранилища.',
    'nav.explorer': 'Проводник',
    'nav.settings': 'Настройки',
    'locations.heading': 'РАСПОЛОЖЕНИЯ',
    'lock.prompt': 'Введите пароль входа в приложение.',
    'lock.failed': 'Ошибок входа',
    'common.password': 'Пароль',
    'common.cancel': 'Отмена',
    'common.open': 'Открыть',
    'common.ok': 'ОК',
    'common.save': 'Сохранить настройки',
    'common.saving': 'Сохраняю...',
    'common.execute': 'Выполнить',
    'common.path': 'Путь',
    'common.target.folder': 'Целевая папка',
    'explorer.choose.location': 'Выберите расположение',
    'explorer.choose.location.left': 'Выберите расположение слева.',
    'explorer.empty': 'Папка пуста.',
    'explorer.access.error': 'Нет доступа или ошибка чтения:',
    'explorer.up': 'Вверх',
    'explorer.refresh': 'Обновить',
    'explorer.upload': 'Загрузить',
    'explorer.download': 'Выгрузить',
    'explorer.encrypt': 'Зашифровать файл',
    'explorer.folder': 'Папка',
    'preview.choose.file': 'Выберите файл для просмотра.',
    'preview.open.password': 'Открыть с паролем',
    'preview.external': 'Открыть другой программой',
    'preview.window': 'Открыть во все окно',
    'preview.hide': 'Скрыть просмотр',
    'preview.show': 'Показать просмотр',
    'preview.container': 'Контейнер',
    'preview.external.warning.title': 'Предупреждение о раскрытии',
    'preview.external.warning':
        'Файл может быть раскрыт другой программе, временным файлам, спискам последних документов, миниатюрам или системному кэшу. Продолжайте только если доверяете этой программе.',
    'preview.external.temp':
        'Расшифрованная копия подготовлена для внешнего открытия.',
    'transfer.upload.title': 'Загрузить файл',
    'transfer.upload.encrypted': 'Загрузить в зашифрованном виде',
    'transfer.upload.plain': 'Загрузить в расшифрованном виде',
    'transfer.download.title': 'Выгрузить файл',
    'transfer.download.encrypted': 'Выгрузить в зашифрованном виде',
    'transfer.download.plain': 'Выгрузить в расшифрованном виде',
    'transfer.source.path': 'Путь к исходному файлу',
    'transfer.password': 'Пароль для шифрования/расшифрования',
    'transfer.delete.source': 'Удалить исходный файл после операции',
    'encrypt.title': 'Зашифровать выбранный файл',
    'encrypt.mode.common': 'Общий ключ',
    'encrypt.mode.unique': 'Уникальный ключ',
    'encrypt.common.autokey': 'Общий ключ будет использован автоматически',
    'encrypt.common.autokey.note':
        'Отдельный пароль для зашифрованных файлов не настроен, поэтому программа не спрашивает общий ключ повторно.',
    'encrypt.password.common': 'Пароль общего шифрования',
    'encrypt.password.unique': 'Уникальный пароль шифрования',
    'encrypt.delete.source': 'Удалить исходный файл после шифрования',
    'encrypt.configure.title': 'Общее шифрование не настроено',
    'encrypt.configure.body':
        'Задайте пароль общего шифрования в настройках, прежде чем шифровать общим ключом.',
    'encrypt.configure.open': 'Открыть настройки',
    'encrypt.select.file': 'Выберите обычный файл для шифрования.',
    'encrypt.already.encrypted': 'Этот файл уже зашифрован.',
    'encrypt.bad.common.password': 'Пароль общего шифрования неверный.',
    'decrypt.title': 'Расшифровать выбранный файл',
    'decrypt.action': 'Расшифровать файл',
    'decrypt.password': 'Пароль для расшифрования',
    'decrypt.delete.source':
        'Удалить зашифрованный исходный файл после расшифрования',
    'decrypt.select.file': 'Выберите зашифрованный файл для расшифрования.',
    'settings.title': 'Настройки безопасности',
    'settings.description':
        'Здесь задаются пароль входа, пароль доступа к зашифрованным файлам, общий ключ шифрования, язык и защита экрана.',
    'settings.passwords': 'Пароли',
    'settings.app.password.current': 'Текущий пароль входа',
    'settings.app.password.new': 'Новый пароль входа (пусто = не менять)',
    'settings.app.password.repeat': 'Повторите новый пароль входа',
    'settings.app.password.mismatch': 'Новые пароли входа не совпадают.',
    'settings.app.password': 'Пароль входа',
    'settings.file.password.separate':
        'Отдельный пароль для зашифрованных файлов',
    'settings.file.password.current': 'Текущий пароль зашифрованных файлов',
    'settings.file.password.new': 'Новый пароль файлов (пусто = не менять)',
    'settings.file.password.repeat':
        'Повторите новый пароль зашифрованных файлов',
    'settings.file.password.mismatch':
        'Новые пароли зашифрованных файлов не совпадают.',
    'settings.file.password': 'Пароль зашифрованных файлов',
    'settings.common.encryption': 'Общий ключ шифрования',
    'settings.common.algorithm': 'Алгоритм общего шифрования',
    'settings.common.password.new':
        'Новый пароль общего шифрования (пусто = не менять)',
    'settings.common.keyfile': 'Путь к файлу общего ключа',
    'settings.common.keyfile.note':
        'Если поле пароля пустое, общий ключ будет получен из содержимого этого файла.',
    'settings.common.status.ready': 'Общее шифрование настроено.',
    'settings.common.status.empty': 'Общее шифрование пока не настроено.',
    'settings.common.reveal': 'Показать текущий общий ключ',
    'settings.common.reveal.note':
        'Требуется пароль входа или пароль зашифрованных файлов, если он настроен.',
    'settings.common.current.key': 'Текущий общий ключ шифрования',
    'settings.remembering': 'Запоминание и очистка',
    'settings.remember.file.password':
        'Запоминать пароль для зашифрованных файлов',
    'settings.file.password.grace':
        'Не требовать пароль зашифрованных файлов повторно N секунд (0 = всегда спрашивать)',
    'settings.wipe.failed': 'Удалять сохранённые пароли при неправильном входе',
    'settings.clear.now': 'Удалить сохранённые пароли сейчас',
    'settings.screen': 'Защита экрана',
    'settings.block.capture':
        'Блокировать скриншоты и запись экрана там, где это позволяет платформа',
    'settings.block.capture.note':
        'На Android используется FLAG_SECURE. Windows/Linux из Flutter не умеют надежно определять запись экрана, поэтому SecureVault предупреждает перед внешним раскрытием файлов.',
    'settings.language': 'Язык',
    'settings.language.select': 'Язык интерфейса',
    'settings.language.ru': 'Русский',
    'settings.language.en': 'Английский',
    'settings.language.custom': 'Пользовательский JSON-файл',
    'settings.language.path': 'Путь к JSON-файлу языка',
    'settings.language.validate': 'Проверить файл языка',
    'settings.language.export': 'Выгрузить английский образец',
    'settings.associations': 'Ассоциации файлов',
    'settings.associations.hint':
        'По одной строке: .ext=команда. Например: .psd=C:\\Program Files\\App\\app.exe',
    'settings.saved': 'Настройки сохранены.',
    'settings.remembered.deleted': 'Сохранённые пароли удалены.',
    'settings.language.valid': 'Файл языка корректен.',
    'settings.language.invalid': 'Файл языка некорректен:',
    'settings.language.exported': 'Образец файла языка выгружен:',
    'snack.bad.password': 'Неверный пароль. Сохранённые пароли файлов очищены.',
    'snack.file.password.mismatch':
        'Пароль доступа к зашифрованным файлам не совпадает с настройками.',
    'snack.uploaded': 'Загружено:',
    'snack.upload.error': 'Ошибка загрузки:',
    'snack.download.select': 'Выберите файл для выгрузки.',
    'snack.downloaded': 'Выгружено:',
    'snack.download.error': 'Ошибка выгрузки:',
    'snack.encrypted': 'Зашифровано:',
    'snack.encrypt.error': 'Ошибка шифрования:',
    'snack.decrypted': 'Расшифровано:',
    'snack.decrypt.error': 'Ошибка расшифрования:',
    'provider.reserved':
        'Это место зарезервировано под сетевой провайдер SMB/SSH/FTP/SFTP. Нужен транспортный адаптер и форма подключения.',
    'provider.plugin': 'JSON-плагин найден:',
    'provider.plugin.detail':
        'Он описывает auth, listFiles, fileInfo и fileStream. Исполнитель запросов будет подключаться отдельным адаптером.',
  };

  static List<String> get requiredStringKeys => _englishStrings.keys.toList();

  static AppLanguage builtIn(String code) {
    if (code == 'en') {
      return const AppLanguage(
        code: 'en',
        name: 'English',
        appTitle: englishTitle,
        strings: _englishStrings,
      );
    }
    return const AppLanguage(
      code: 'ru',
      name: 'Русский',
      appTitle: russianTitle,
      strings: _russianStrings,
    );
  }

  static Future<AppLanguage> load(SecuritySettings settings) async {
    if (settings.languageCode == 'custom' &&
        (settings.customLanguagePath?.isNotEmpty ?? false)) {
      try {
        return await fromFile(settings.customLanguagePath!);
      } catch (_) {
        return builtIn('ru');
      }
    }

    final code = settings.languageCode == 'en' ? 'en' : 'ru';
    try {
      final raw = await rootBundle.loadString('assets/i18n/$code.json');
      return fromJson(jsonDecode(raw) as Map<String, Object?>,
          sourcePath: null);
    } catch (_) {
      return builtIn(code);
    }
  }

  static Future<AppLanguage> fromFile(String path) async {
    final file = File(path);
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Root JSON object expected.');
    }
    return fromJson(decoded, sourcePath: path);
  }

  static AppLanguage fromJson(Map<String, Object?> json, {String? sourcePath}) {
    final code = json['code'];
    final name = json['name'];
    final appTitle = json['appTitle'];
    final strings = json['strings'];
    if (code is! String || code.trim().isEmpty) {
      throw const FormatException('Missing string field: code.');
    }
    if (name is! String || name.trim().isEmpty) {
      throw const FormatException('Missing string field: name.');
    }
    if (appTitle is! String || appTitle.trim().isEmpty) {
      throw const FormatException('Missing string field: appTitle.');
    }
    if (strings is! Map) {
      throw const FormatException('Missing object field: strings.');
    }
    final typedStrings = strings.map(
      (key, value) => MapEntry(key.toString(), value.toString()),
    );
    final missing = requiredStringKeys
        .where((key) => !typedStrings.containsKey(key))
        .toList();
    if (missing.isNotEmpty) {
      throw FormatException('Missing translation keys: ${missing.join(', ')}');
    }
    return AppLanguage(
      code: code,
      name: name,
      appTitle: appTitle,
      strings: typedStrings,
      sourcePath: sourcePath,
    );
  }

  static Future<String> exportEnglishSample() async {
    final appData = await AppPaths.appDataDirectory();
    final file = File(
      '${appData.path}${Platform.pathSeparator}securevault_language_en_sample.json',
    );
    await file.writeAsString(sampleJson(), flush: true);
    return file.path;
  }

  static String sampleJson() => const JsonEncoder.withIndent('  ').convert({
        'schema': 'securevault.language.v1',
        'code': 'en-custom',
        'name': 'English translation sample',
        'appTitle': englishTitle,
        'strings': _englishStrings,
      });
}
