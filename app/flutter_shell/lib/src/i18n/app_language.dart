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

  static const russianTitle = 'Защищенное хранилище файлов';
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
    'gallery.zoom.hint':
        'Ctrl + mouse wheel changes gallery scale down to year calendar view.',
    'month.1': 'January',
    'month.2': 'February',
    'month.3': 'March',
    'month.4': 'April',
    'month.5': 'May',
    'month.6': 'June',
    'month.7': 'July',
    'month.8': 'August',
    'month.9': 'September',
    'month.10': 'October',
    'month.11': 'November',
    'month.12': 'December',
    'month.short.1': 'Jan',
    'month.short.2': 'Feb',
    'month.short.3': 'Mar',
    'month.short.4': 'Apr',
    'month.short.5': 'May',
    'month.short.6': 'Jun',
    'month.short.7': 'Jul',
    'month.short.8': 'Aug',
    'month.short.9': 'Sep',
    'month.short.10': 'Oct',
    'month.short.11': 'Nov',
    'month.short.12': 'Dec',
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
    'favorites.open.all': 'Show all favorites',
    'locations.heading': 'LOCATIONS',
    'locations.add': 'Add location',
    'locations.add.empty':
        'Install or configure a network/cloud plugin to add a new location.',
    'locations.open.all': 'Show all locations',
    'sort.title': 'Folder sorting',
    'sort.by': 'Sort by',
    'sort.name': 'Name',
    'sort.modified': 'Modified',
    'sort.created': 'Created',
    'sort.size': 'Size',
    'sort.extension': 'Extension',
    'sort.asc': 'ascending',
    'sort.desc': 'descending',
    'sort.folders.first': 'Keep folders first',
    'settings.locations.sidebar.count': 'Locations shown on the left',
    'settings.thumbnails.video': 'Show video thumbnails',
    'settings.thumbnails.video.animate': 'Animate video thumbnails',
    'settings.thumbnails.audio': 'Show audio covers',
    'settings.android.lock.resume':
        'Ask for the app password after Android resume',
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
    'explorer.use.as': 'Use as',
    'explorer.use.as.gallery': 'Gallery folder',
    'explorer.use.as.video': 'Video folder',
    'explorer.use.as.music': 'Music folder',
    'explorer.use.as.multimedia': 'Multimedia folder',
    'path.edit': 'Edit path',
    'path.unavailable': 'Path is unavailable.',
    'search.title': 'Search',
    'search.query': 'Search text',
    'search.apply': 'Apply',
    'search.clear': 'Clear',
    'search.filters': 'Search filters',
    'search.filters.note':
        'Search supports name/content modes, regular expressions, and optional recursion. Duration/date/size filters are reserved for the indexed search stage.',
    'search.mode': 'Search mode',
    'search.mode.name': 'File name',
    'search.mode.name.content': 'File name and content',
    'search.mode.content': 'Content',
    'search.regex': 'Use regular expressions',
    'search.recursive': 'Search in subfolders',
    'create.folder': 'Folder',
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
    'media.unavailable': 'No playable media source is available.',
    'media.error': 'Media playback error:',
    'media.decrypted.memory':
        'Encrypted media was decrypted only for the protected playback session.',
    'media.previous': 'Previous',
    'media.play': 'Play',
    'media.pause': 'Pause',
    'media.next': 'Next',
    'media.shuffle': 'Shuffle playback',
    'media.repeat.one': 'Repeat current item',
    'media.audio.playlist': 'Audio playlist',
    'media.video.playlist': 'Video playlist',
    'media.encrypted.item': 'Encrypted source',
    'editor.open': 'Edit',
    'editor.unsupported': 'This file type is not editable yet.',
    'editor.saved': 'Saved:',
    'editor.error': 'Editor error:',
    'editor.save.as': 'Save as',
    'editor.output.path': 'Output path',
    'editor.output.format': 'Output format',
    'editor.image.title': 'Image editor',
    'editor.rotate.right': 'Rotate',
    'editor.crop.center': 'Crop center',
    'editor.layer.undo': 'Undo layer',
    'editor.layer.clear': 'Clear layers',
    'editor.draw.hint':
        'Draw directly on the image. White brush works as a simple eraser for drawn layers.',
    'editor.audio.title': 'Audio editor',
    'editor.video.title': 'Video editor',
    'editor.ffmpeg.note': 'Rendering uses ffmpeg when it is available in PATH.',
    'editor.ffmpeg.missing': 'ffmpeg is not available in PATH.',
    'editor.trim.start': 'Trim start, e.g. 00:00:05',
    'editor.trim.end': 'Trim end, e.g. 00:01:00',
    'editor.audio.append': 'Append another audio file',
    'editor.audio.mix': 'Mix/add another sound file',
    'editor.audio.quality': 'Audio bitrate, e.g. 128k',
    'editor.video.append': 'Append another video file',
    'editor.video.replace.audio': 'Replace/add audio track path',
    'editor.video.width': 'Video width',
    'editor.video.height': 'Video height',
    'editor.video.rotate': 'Rotate video 90 degrees',
    'editor.video.quality': 'Video CRF quality, lower is better',
    'editor.render': 'Render',
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
    'settings.storage': 'Storage and navigation',
    'settings.storage.user': 'Store settings in the user profile folder',
    'settings.storage.note':
        'When disabled, settings, plugins, languages, exports, and hidden storage are kept near the program in SecureVaultData.',
    'settings.export.config': 'Export configuration and plugins',
    'settings.export.done': 'Configuration archive exported:',
    'settings.remember.last.folder': 'Remember the last opened folder',
    'settings.navigation.policy': 'Unavailable-path navigation policy',
    'settings.navigation.ask': 'Ask before entering unavailable paths',
    'settings.navigation.deny': 'Do not enter unavailable paths',
    'settings.navigation.allow': 'Enter without warning',
    'settings.navigation.fallback':
        'Fallback to locations when going above/into forbidden paths',
    'settings.navigation.root': 'Request root rights when possible',
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
    'settings.fullscreen.hidden.preview.tap':
        'Open files full-window by single tap when preview pane is hidden',
    'settings.auto.dpi': 'Auto-adjust file text and icon size by device DPI',
    'settings.file.text.scale': 'File text scale',
    'settings.file.icon.scale': 'File icon scale',
    'settings.interface.text.scale': 'Whole interface text scale',
    'settings.toolbar.icon.scale': 'Path/search toolbar icon scale',
    'settings.search.default': 'Default search mode',
    'settings.media.sections': 'Media sections',
    'settings.exclusions': 'Exclusions',
    'settings.paths.one.per.line': 'One path, folder, or mask per line.',
    'settings.torrent.enabled': 'Enable torrent section',
    'settings.torrent.disabled': 'Torrent section is disabled in settings.',
    'settings.background.media': 'Background playback',
    'settings.background.video': 'Allow background video',
    'settings.background.video.mini': 'Allow mini video player',
    'settings.background.audio.mini': 'Allow mini audio player',
    'settings.background.continue': 'Continue playback in background',
    'settings.background.autoclose': 'Close media when leaving a section',
    'settings.proxy': 'Proxy',
    'settings.proxy.program': 'Program proxy URL',
    'settings.proxy.plugins': 'Default plugin proxy URL',
    'settings.android.storage.request': 'Request Android file access again',
    'android.storage.title': 'File access is limited',
    'android.storage.body':
        'SecureVault can show more folders and media if Android grants media or all-files access. You can decline now and request it later in settings.',
    'android.storage.open': 'Open permissions',
    'android.storage.requested': 'Android permission request opened.',
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
        'Install plugin ZIP archives. Built-in templates cover WebDAV, FTP, embedded SFTP/SSH, and embedded SMB2/3.',
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
    'settings.plugins.window.title': 'Plugin settings',
    'settings.plugins.open.window': 'Open plugin settings window',
    'selection.zip.local.only':
        'ZIP operations are available only for local folders.',
    'selection.unsupported.bulk':
        'This bulk action is not available for the current selection.',
    'selection.zip': 'Archive selected to ZIP',
    'selection.clear': 'Clear selection',
    'selection.all': 'Select all',
    'selection.count': 'Selected',
    'filter.duration.max': 'Max duration, seconds',
    'filter.duration.min': 'Min duration, seconds',
    'filter.modified.to': 'Modified to YYYY-MM-DD',
    'filter.modified.from': 'Modified from YYYY-MM-DD',
    'filter.created.to': 'Created to YYYY-MM-DD',
    'filter.created.from': 'Created from YYYY-MM-DD',
    'filter.size.max': 'Max size, bytes',
    'filter.size.min': 'Min size, bytes',
    'path.root.unavailable':
        'Root access cannot be requested from this desktop build.',
    'path.unavailable.ask':
        'This path is unavailable now. If you continue, the current folder may stop working. Continue?',
    'explorer.folder.decrypt.name': 'Decrypt folder name',
    'explorer.folder.encrypt.name': 'Encrypt folder name',
  };

  static const _russianStrings = <String, String>{
    'app.title': russianTitle,
    'app.runtime.offline': 'Нативное ядро недоступно',
    'about.title': 'О программе',
    'about.version': 'Версия',
    'about.description':
        'Защищенный проводник, просмотр зашифрованных файлов, языковые пакеты и сведения о нативном ядре хранилища.',
    'nav.explorer': 'Проводник',
    'nav.gallery': 'Галерея',
    'nav.music': 'Музыка',
    'nav.video': 'Видео',
    'nav.documents': 'Документы',
    'nav.torrent': 'Торрент',
    'nav.settings': 'Настройки',
    'gallery.zoom.hint':
        'Ctrl + колесико мыши меняет масштаб галереи вплоть до календаря по годам.',
    'month.1': 'Январь',
    'month.2': 'Февраль',
    'month.3': 'Март',
    'month.4': 'Апрель',
    'month.5': 'Май',
    'month.6': 'Июнь',
    'month.7': 'Июль',
    'month.8': 'Август',
    'month.9': 'Сентябрь',
    'month.10': 'Октябрь',
    'month.11': 'Ноябрь',
    'month.12': 'Декабрь',
    'month.short.1': 'Янв',
    'month.short.2': 'Фев',
    'month.short.3': 'Мар',
    'month.short.4': 'Апр',
    'month.short.5': 'Май',
    'month.short.6': 'Июн',
    'month.short.7': 'Июл',
    'month.short.8': 'Авг',
    'month.short.9': 'Сен',
    'month.short.10': 'Окт',
    'month.short.11': 'Ноя',
    'month.short.12': 'Дек',
    'recent.title': 'Недавние',
    'recent.open.all': 'Показать все недавние файлы',
    'recent.remove': 'Удалить из недавних',
    'recent.missing.title': 'Недавний файл недоступен',
    'recent.missing.body':
        'Файл больше не существует или к нему нет доступа. Удалить его из списка недавних?',
    'recent.missing.file': 'Недоступный недавний файл',
    'favorites.title': 'ИЗБРАННОЕ',
    'favorites.add': 'Добавить в избранное',
    'favorites.remove': 'Удалить из избранного',
    'favorites.missing': 'Избранный путь недоступен.',
    'locations.heading': 'РАСПОЛОЖЕНИЯ',
    'locations.add': 'Добавить расположение',
    'locations.add.empty':
        'Установите или настройте сетевой/облачный плагин, чтобы добавить расположение.',
    'locations.open.all': 'Показать все расположения',
    'sort.title': 'Сортировка папки',
    'sort.by': 'Сортировать по',
    'sort.name': 'Имя',
    'sort.modified': 'Дата изменения',
    'sort.created': 'Дата создания',
    'sort.size': 'Размер',
    'sort.extension': 'Расширение',
    'sort.asc': 'по возрастанию',
    'sort.desc': 'по убыванию',
    'sort.folders.first': 'Сначала папки',
    'settings.locations.sidebar.count': 'Расположений слева',
    'settings.thumbnails.video': 'Показывать кадры видео',
    'settings.thumbnails.video.animate': 'Анимировать кадры видео',
    'settings.thumbnails.audio': 'Показывать обложки аудио',
    'settings.android.lock.resume':
        'Запрашивать пароль после возврата в Android',
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
    'explorer.create': 'Создать',
    'explorer.encrypt': 'Зашифровать файл',
    'explorer.copy': 'Копировать',
    'explorer.cut': 'Вырезать',
    'explorer.paste': 'Вставить',
    'explorer.delete': 'Удалить',
    'explorer.rename': 'Переименовать',
    'explorer.properties': 'Свойства',
    'explorer.name': 'Имя',
    'explorer.type': 'Тип',
    'explorer.size': 'Размер, байт',
    'explorer.modified': 'Изменен',
    'explorer.exists': 'Существует',
    'explorer.delete.confirm': 'Удалить этот файл или папку?',
    'explorer.folder.container': 'Создать зашифрованный контейнер из папки',
    'explorer.folder.encrypt': 'Зашифровать файлы',
    'explorer.folder.decrypt': 'Расшифровать файлы',
    'explorer.send': 'Отправить',
    'explorer.unzip': 'Распаковать ZIP',
    'explorer.folder': 'Папка',
    'explorer.use.as': 'Использовать как',
    'explorer.use.as.gallery': 'Папку для галереи',
    'explorer.use.as.video': 'Папку для видео',
    'explorer.use.as.music': 'Папку для аудио',
    'explorer.use.as.multimedia': 'Папку мультимедиа',
    'path.edit': 'Изменить путь',
    'path.unavailable': 'Путь недоступен.',
    'search.title': 'Поиск',
    'search.query': 'Строка поиска',
    'search.apply': 'Применить',
    'search.clear': 'Очистить',
    'search.filters': 'Фильтры поиска',
    'search.filters.note':
        'Поиск поддерживает режимы по имени и содержимому, регулярные выражения и поиск по подпапкам. Фильтры длительности, дат и размера будут подключены на этапе индексированного поиска.',
    'search.mode': 'Режим поиска',
    'search.mode.name': 'По названию файла',
    'search.mode.name.content': 'По названию файла и содержимому',
    'search.mode.content': 'По содержимому',
    'search.regex': 'Использовать регулярные выражения',
    'search.recursive': 'Искать в подпапках',
    'create.folder': 'Папка',
    'create.plain': 'Обычный файл',
    'create.encrypted.plain': 'Зашифрованный файл',
    'create.csv': 'Таблица CSV',
    'create.encrypted.csv': 'Зашифрованная таблица CSV',
    'create.image': 'Файл изображения',
    'create.encrypted.image': 'Зашифрованный файл изображения',
    'create.csv.separator': 'Разделитель CSV',
    'create.csv.separator.note':
        'По умолчанию ;. Для табуляции используйте \\t или tab.',
    'create.image.format': 'Формат изображения',
    'create.image.width': 'Ширина',
    'create.image.height': 'Высота',
    'create.image.background': 'Цвет фона',
    'create.image.transparent': 'Прозрачный фон',
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
    'media.unavailable': 'Нет доступного источника для воспроизведения.',
    'media.error': 'Ошибка воспроизведения:',
    'media.decrypted.memory':
        'Зашифрованное медиа расшифровано только для защищенного сеанса воспроизведения.',
    'media.previous': 'Предыдущий',
    'media.play': 'Воспроизвести',
    'media.pause': 'Пауза',
    'media.next': 'Следующий',
    'media.shuffle': 'Случайное воспроизведение',
    'media.repeat.one': 'Повторять текущий файл',
    'media.audio.playlist': 'Плейлист аудио',
    'media.video.playlist': 'Плейлист видео',
    'media.encrypted.item': 'Зашифрованный источник',
    'editor.open': 'Редактировать',
    'editor.unsupported': 'Этот тип файла пока нельзя редактировать.',
    'editor.saved': 'Сохранено:',
    'editor.error': 'Ошибка редактора:',
    'editor.save.as': 'Сохранить как',
    'editor.output.path': 'Путь сохранения',
    'editor.output.format': 'Формат сохранения',
    'editor.image.title': 'Редактор изображений',
    'editor.rotate.right': 'Повернуть',
    'editor.crop.center': 'Обрезать центр',
    'editor.layer.undo': 'Убрать слой',
    'editor.layer.clear': 'Очистить слои',
    'editor.draw.hint':
        'Рисуйте прямо на изображении. Белая кисть работает как простой ластик для нарисованных слоев.',
    'editor.audio.title': 'Аудиоредактор',
    'editor.video.title': 'Видеоредактор',
    'editor.ffmpeg.note':
        'Рендеринг использует ffmpeg, если он доступен в PATH.',
    'editor.ffmpeg.missing': 'ffmpeg недоступен в PATH.',
    'editor.trim.start': 'Начало обрезки, например 00:00:05',
    'editor.trim.end': 'Конец обрезки, например 00:01:00',
    'editor.audio.append': 'Склеить с другим аудиофайлом',
    'editor.audio.mix': 'Добавить/смешать другой звук',
    'editor.audio.quality': 'Качество звука, например 128k',
    'editor.video.append': 'Склеить с другим видеофайлом',
    'editor.video.replace.audio': 'Путь к новой/добавочной звуковой дорожке',
    'editor.video.width': 'Ширина видео',
    'editor.video.height': 'Высота видео',
    'editor.video.rotate': 'Повернуть видео на 90 градусов',
    'editor.video.quality': 'CRF качества видео, меньше значит лучше',
    'editor.render': 'Собрать',
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
    'settings.storage': 'Хранение и навигация',
    'settings.storage.user': 'Хранить настройки в папке пользователя',
    'settings.storage.note':
        'Если выключено, настройки, плагины, языки, экспорт и скрытое хранилище находятся рядом с программой в SecureVaultData.',
    'settings.export.config': 'Экспортировать конфигурацию и плагины',
    'settings.export.done': 'Архив конфигурации выгружен:',
    'settings.remember.last.folder': 'Запоминать последнюю открытую папку',
    'settings.navigation.policy': 'Поведение для недоступных путей',
    'settings.navigation.ask': 'Спрашивать перед переходом',
    'settings.navigation.deny': 'Не переходить в запрещенные расположения',
    'settings.navigation.allow': 'Переходить без уведомления',
    'settings.navigation.fallback':
        'При запрете возвращаться к выбору расположения',
    'settings.navigation.root': 'Запрашивать Root-права при возможности',
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
    'settings.recent': 'Недавние файлы',
    'settings.recent.remember': 'Запоминать недавно открытые файлы',
    'settings.recent.sidebar.count': 'Недавних файлов в боковой панели',
    'settings.recent.remember.count': 'Сколько недавних файлов хранить',
    'settings.favorite.sidebar.count': 'Избранных элементов в боковой панели',
    'settings.explorer.view': 'Вид проводника',
    'settings.decrypt.names':
        'Расшифровывать имена в проводнике, когда это возможно',
    'settings.fullscreen.hidden.preview.tap':
        'Открывать файлы во все окно одиночным нажатием, если область просмотра скрыта',
    'settings.auto.dpi':
        'Автоматически подстраивать размер текста и иконок под DPI устройства',
    'settings.file.text.scale': 'Масштаб текста файлов',
    'settings.file.icon.scale': 'Масштаб иконок файлов',
    'settings.interface.text.scale': 'Масштаб текста всего интерфейса',
    'settings.toolbar.icon.scale': 'Масштаб иконок пути и поиска',
    'settings.search.default': 'Режим поиска по умолчанию',
    'settings.media.sections': 'Медиа-разделы',
    'settings.exclusions': 'Исключения',
    'settings.paths.one.per.line': 'Один путь, папка или маска в строке.',
    'settings.torrent.enabled': 'Включить раздел торрентов',
    'settings.torrent.disabled': 'Раздел торрентов отключен в настройках.',
    'settings.background.media': 'Фоновое воспроизведение',
    'settings.background.video': 'Разрешить фоновое видео',
    'settings.background.video.mini': 'Разрешить мини-видео',
    'settings.background.audio.mini': 'Разрешить мини-аудиоплеер',
    'settings.background.continue': 'Продолжать воспроизведение в фоне',
    'settings.background.autoclose': 'Закрывать медиа при уходе из раздела',
    'settings.proxy': 'Прокси',
    'settings.proxy.program': 'Прокси программы',
    'settings.proxy.plugins': 'Общий прокси плагинов',
    'settings.android.storage.request':
        'Повторно запросить доступ к файлам Android',
    'android.storage.title': 'Доступ к файлам ограничен',
    'android.storage.body':
        'SecureVault сможет показать больше папок и медиафайлов, если Android предоставит доступ к медиа или ко всем файлам. Можно отказаться сейчас и повторно запросить доступ в настройках.',
    'android.storage.open': 'Открыть разрешения',
    'android.storage.requested': 'Запрос разрешений Android открыт.',
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
    'settings.language.install': 'Добавить язык в программу',
    'settings.language.export': 'Выгрузить английский образец',
    'settings.associations': 'Ассоциации файлов',
    'settings.associations.hint':
        'По одной строке: .ext=команда. Например: .psd=C:\\Program Files\\App\\app.exe',
    'settings.saved': 'Настройки сохранены.',
    'settings.remembered.deleted': 'Сохранённые пароли удалены.',
    'settings.language.valid': 'Файл языка корректен.',
    'settings.language.invalid': 'Файл языка некорректен:',
    'settings.language.exported': 'Образец файла языка выгружен:',
    'settings.language.installed': 'Файл языка добавлен:',
    'settings.plugins': 'Плагины',
    'settings.plugins.note':
        'Устанавливайте ZIP-архивы плагинов. Встроенные шаблоны охватывают WebDAV, FTP, embedded SFTP/SSH и embedded SMB2/3.',
    'settings.plugin.zip.path': 'Путь к ZIP-плагину',
    'settings.plugin.install': 'Установить ZIP-плагин',
    'settings.plugin.installed': 'Плагин установлен:',
    'snack.bad.password': 'Неверный пароль. Сохранённые пароли файлов очищены.',
    'snack.file.password.mismatch':
        'Пароль доступа к зашифрованным файлам не совпадает с настройками.',
    'snack.copied': 'Скопировано в буфер обмена.',
    'snack.cut': 'Вырезано в буфер обмена.',
    'snack.pasted': 'Вставлено:',
    'snack.deleted': 'Удалено.',
    'snack.renamed': 'Переименовано:',
    'snack.operation.error': 'Ошибка операции:',
    'snack.created': 'Создано:',
    'snack.unzipped': 'Распаковано:',
    'snack.send.next':
        'Отправка добавлена в контекстное меню и требует платформенный адаптер общего доступа.',
    'snack.folder.actions.next':
        'Действия с папками уже есть в меню и будут подключены к рекурсивной обработке и контейнерам в следующей версии.',
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
