# Защищенное хранилище файов - Flutter Shell

Flutter-оболочка SecureVault версии `0.2.0`.

## Что делает оболочка

- Показывает проводник с расположениями, файлами и областью просмотра.
- Открывает локальные пути Windows/Linux/Android, область файлов телефона Android и скрытую папку приложения.
- Позволяет загружать и выгружать файлы в plain/encrypted режиме.
- Шифрует и расшифровывает app-created `.crypt` файлы через контекстное меню.
- Поддерживает общий и уникальный ключи, XChaCha20-Poly1305 и AES-256-GCM.
- Использует сохраненный общий ключ автоматически, если отдельный пароль зашифрованных файлов не включен.
- Поддерживает файл-ключ для общего шифрования.
- Хранит настройки в зашифрованной оболочке на встроенном ключе приложения.
- Показывает тексты, изображения и извлеченный текст документов; аудио/видео пока отображаются как защищенная мета-информация.
- Содержит русскую/английскую локализацию, импорт пользовательского JSON-языка и экспорт образца.
- Переносит техническую информацию о версии и ядре в кнопку `i` (`О программе`).

## Проверка

```powershell
..\..\tooling\flutter\flutter\bin\flutter.bat analyze
..\..\tooling\flutter\flutter\bin\flutter.bat test
```

## Сборка

```powershell
..\..\tooling\flutter\flutter\bin\flutter.bat build windows --release
..\..\tooling\flutter\flutter\bin\flutter.bat build apk --release
```

Windows output:

```text
build/windows/x64/runner/Release/secure_vault_shell.exe
```

Android output:

```text
build/app/outputs/flutter-apk/app-release.apk
```

Оставшиеся крупные задачи перечислены в корневом `README.md`.
