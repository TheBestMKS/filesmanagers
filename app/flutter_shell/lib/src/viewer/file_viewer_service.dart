import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:xml/xml.dart';

import '../explorer/explorer_models.dart';
import '../vault/vault_models.dart';

class FileViewerService {
  static const imageExtensions = {
    '.png',
    '.jpg',
    '.jpeg',
    '.gif',
    '.bmp',
    '.webp',
    '.heic',
    '.heif'
  };
  static const textExtensions = {
    '.txt',
    '.log',
    '.md',
    '.json',
    '.xml',
    '.yaml',
    '.yml',
    '.csv',
    '.tsv',
    '.ini',
    '.cfg',
    '.conf',
    '.dart',
    '.c',
    '.h',
    '.cpp',
    '.hpp',
    '.java',
    '.kt',
    '.js',
    '.ts',
    '.css',
    '.sql'
  };
  static const htmlExtensions = {
    '.html',
    '.htm',
    '.xhtml',
  };
  static const archiveExtensions = {
    '.zip',
    '.rar',
    '.cbr',
    '.rev',
  };
  static const flashExtensions = {
    '.swf',
  };
  static const containerExtensions = {
    '.hc',
    '.tc',
    '.vc',
  };
  static const documentExtensions = {
    '.docx',
    '.doc',
    '.pdf',
    '.rtf',
    '.odt',
    '.xlsx',
    '.xls',
    '.pptx',
    '.ppt'
  };
  static const ebookExtensions = {
    '.epub',
    '.fb2',
    '.mobi',
    '.azw',
    '.azw3',
  };
  static const videoExtensions = {
    '.mp4',
    '.mkv',
    '.avi',
    '.mov',
    '.wmv',
    '.webm',
    '.m4v',
    '.3gp'
  };
  static const audioExtensions = {
    '.mp3',
    '.wav',
    '.flac',
    '.ogg',
    '.m4a',
    '.aac',
    '.wma'
  };

  static FileContentKind kindForName(String name) {
    final extension = extensionForName(name);
    if (imageExtensions.contains(extension)) return FileContentKind.image;
    if (htmlExtensions.contains(extension)) return FileContentKind.html;
    if (archiveExtensions.contains(extension)) return FileContentKind.archive;
    if (flashExtensions.contains(extension)) return FileContentKind.flash;
    if (containerExtensions.contains(extension)) {
      return FileContentKind.container;
    }
    if (textExtensions.contains(extension)) return FileContentKind.text;
    if (documentExtensions.contains(extension)) return FileContentKind.document;
    if (ebookExtensions.contains(extension)) return FileContentKind.ebook;
    if (videoExtensions.contains(extension)) return FileContentKind.video;
    if (audioExtensions.contains(extension)) return FileContentKind.audio;
    return FileContentKind.unknown;
  }

  static String extensionForName(String name) {
    final index = name.lastIndexOf('.');
    if (index < 0) return '';
    return name.substring(index).toLowerCase();
  }

  static Future<FilePreview> previewPlainFile(File file) async {
    final stat = await file.stat();
    final name = file.path.split(Platform.pathSeparator).last;
    final kind = kindForName(name);
    final size = stat.size;
    if (kind == FileContentKind.image && size <= 25 * 1024 * 1024) {
      return FilePreview(
          title: name,
          subtitle: 'Image, $size bytes',
          sourcePath: file.path,
          bytes: await file.readAsBytes(),
          contentKind: kind);
    }
    if (kind == FileContentKind.text && size <= 1024 * 1024) {
      final bytes = await file.readAsBytes();
      return FilePreview(
          title: name,
          subtitle: 'Text, $size bytes',
          sourcePath: file.path,
          text: bytesToText(bytes),
          bytes: bytes,
          contentKind: kind);
    }
    if (kind == FileContentKind.html && size <= 2 * 1024 * 1024) {
      final bytes = await file.readAsBytes();
      return FilePreview(
        title: name,
        subtitle: 'HTML, $size bytes',
        sourcePath: file.path,
        text: _htmlSummary(bytesToText(bytes)),
        bytes: bytes,
        contentKind: kind,
      );
    }
    if (kind == FileContentKind.archive && size <= 80 * 1024 * 1024) {
      final bytes = await file.readAsBytes();
      return FilePreview(
        title: name,
        subtitle: 'Archive, $size bytes',
        sourcePath: file.path,
        text: _zipSummary(bytes),
        bytes: bytes,
        contentKind: kind,
      );
    }
    if (kind == FileContentKind.flash && size <= 80 * 1024 * 1024) {
      final bytes = await file.readAsBytes();
      return FilePreview(
        title: name,
        subtitle: 'SWF/Flash, $size bytes',
        sourcePath: file.path,
        text: _flashSummary(bytes),
        bytes: bytes,
        contentKind: kind,
      );
    }
    if (kind == FileContentKind.container) {
      return FilePreview(
        title: name,
        subtitle: 'Encrypted disk container, $size bytes',
        sourcePath: file.path,
        text: _containerSummary(name, size),
        contentKind: kind,
      );
    }
    if (kind == FileContentKind.ebook && size <= 80 * 1024 * 1024) {
      final bytes = await file.readAsBytes();
      final text = await _extractEbookText(name, bytes);
      return FilePreview(
        title: name,
        subtitle: 'E-book, $size bytes',
        sourcePath: file.path,
        text: text.isEmpty ? bytesToText(bytes) : text,
        bytes: bytes,
        contentKind: kind,
      );
    }
    if (kind == FileContentKind.document && size <= 40 * 1024 * 1024) {
      final bytes = await file.readAsBytes();
      final text = await _extractDocumentText(name, bytes);
      return FilePreview(
        title: name,
        subtitle: 'Document, $size bytes',
        sourcePath: file.path,
        text: text.isEmpty
            ? 'No preview text was extracted from this file.'
            : text,
        bytes: bytes,
        contentKind: kind,
      );
    }
    if ((kind == FileContentKind.audio || kind == FileContentKind.video) &&
        size <= 40 * 1024 * 1024) {
      final bytes = await file.readAsBytes();
      return FilePreview(
        title: name,
        subtitle: _kindSubtitle(kind, size),
        sourcePath: file.path,
        text: _mediaSummary(name, bytes),
        bytes: bytes,
        contentKind: kind,
      );
    }
    if (kind == FileContentKind.unknown && size <= 5 * 1024 * 1024) {
      final bytes = await file.readAsBytes();
      return FilePreview(
        title: name,
        subtitle: _kindSubtitle(kind, size),
        sourcePath: file.path,
        text: bytesToText(bytes),
        bytes: bytes,
        contentKind: kind,
      );
    }
    return FilePreview(
        title: name,
        subtitle: _kindSubtitle(kind, size),
        sourcePath: file.path,
        text: _fallbackText(kind),
        contentKind: kind);
  }

  static Future<FilePreview> previewBytes({
    required String name,
    required Uint8List bytes,
    required String subtitle,
    String? sourcePath,
    VaultContainerInfo? containerInfo,
  }) async {
    final kind = kindForName(name);
    if (kind == FileContentKind.image && bytes.length <= 25 * 1024 * 1024) {
      return FilePreview(
          title: name,
          subtitle: subtitle,
          sourcePath: sourcePath,
          bytes: bytes,
          containerInfo: containerInfo,
          decrypted: true,
          contentKind: kind);
    }
    if (kind == FileContentKind.text && bytes.length <= 1024 * 1024) {
      return FilePreview(
          title: name,
          subtitle: subtitle,
          sourcePath: sourcePath,
          text: bytesToText(bytes),
          bytes: bytes,
          containerInfo: containerInfo,
          decrypted: true,
          contentKind: kind);
    }
    if (kind == FileContentKind.html && bytes.length <= 2 * 1024 * 1024) {
      return FilePreview(
          title: name,
          subtitle: subtitle,
          sourcePath: sourcePath,
          text: _htmlSummary(bytesToText(bytes)),
          bytes: bytes,
          containerInfo: containerInfo,
          decrypted: true,
          contentKind: kind);
    }
    if (kind == FileContentKind.archive && bytes.length <= 80 * 1024 * 1024) {
      return FilePreview(
          title: name,
          subtitle: subtitle,
          sourcePath: sourcePath,
          text: _zipSummary(bytes),
          bytes: bytes,
          containerInfo: containerInfo,
          decrypted: true,
          contentKind: kind);
    }
    if (kind == FileContentKind.flash) {
      return FilePreview(
          title: name,
          subtitle: subtitle,
          sourcePath: sourcePath,
          text: _flashSummary(bytes),
          bytes: bytes,
          containerInfo: containerInfo,
          decrypted: true,
          contentKind: kind);
    }
    if (kind == FileContentKind.container) {
      return FilePreview(
          title: name,
          subtitle: subtitle,
          sourcePath: sourcePath,
          text: _containerSummary(name, bytes.length),
          bytes: bytes,
          containerInfo: containerInfo,
          decrypted: true,
          contentKind: kind);
    }
    if (kind == FileContentKind.ebook) {
      final text = await _extractEbookText(name, bytes);
      return FilePreview(
          title: name,
          subtitle: subtitle,
          sourcePath: sourcePath,
          text: text.isEmpty ? bytesToText(bytes) : text,
          bytes: bytes,
          containerInfo: containerInfo,
          decrypted: true,
          contentKind: kind);
    }
    if (kind == FileContentKind.document) {
      final text = await _extractDocumentText(name, bytes);
      return FilePreview(
          title: name,
          subtitle: subtitle,
          sourcePath: sourcePath,
          text: text.isEmpty
              ? 'No preview text was extracted from this file.'
              : text,
          bytes: bytes,
          containerInfo: containerInfo,
          decrypted: true,
          contentKind: kind);
    }
    if (kind == FileContentKind.audio || kind == FileContentKind.video) {
      return FilePreview(
          title: name,
          subtitle: subtitle,
          sourcePath: sourcePath,
          text: _mediaSummary(name, bytes),
          bytes: bytes,
          containerInfo: containerInfo,
          decrypted: true,
          contentKind: kind);
    }
    return FilePreview(
        title: name,
        subtitle: subtitle,
        sourcePath: sourcePath,
        text: _fallbackText(kind),
        bytes: bytes,
        containerInfo: containerInfo,
        decrypted: true,
        contentKind: kind);
  }

  static String _kindSubtitle(FileContentKind kind, int size) {
    return switch (kind) {
      FileContentKind.video => 'Video file, $size bytes',
      FileContentKind.audio => 'Audio file, $size bytes',
      FileContentKind.document => 'Document file, $size bytes',
      FileContentKind.ebook => 'E-book file, $size bytes',
      FileContentKind.html => 'HTML page, $size bytes',
      FileContentKind.archive => 'Archive file, $size bytes',
      FileContentKind.flash => 'SWF/Flash file, $size bytes',
      FileContentKind.container => 'Encrypted disk container, $size bytes',
      FileContentKind.image => 'Image file, $size bytes',
      FileContentKind.text => 'Text file, $size bytes',
      FileContentKind.unknown => 'Unknown file type, $size bytes',
    };
  }

  static String _fallbackText(FileContentKind kind) {
    return switch (kind) {
      FileContentKind.video =>
        'Video preview is protected in memory. Native playback plugins require Windows symlink support on this machine, so SecureVault does not write decrypted video to disk automatically.',
      FileContentKind.audio =>
        'Audio preview is protected in memory. Native playback plugins require Windows symlink support on this machine, so SecureVault does not write decrypted audio to disk automatically.',
      FileContentKind.document =>
        'This document type is recognized. Text extraction is built in for PDF, DOCX, ODT, XLSX, PPTX, and RTF where possible.',
      FileContentKind.ebook =>
        'This e-book can be read in the built-in reader. TTS is available from the preview menu when the platform provides speech synthesis.',
      FileContentKind.html =>
        'HTML pages are rendered in the built-in browser-like preview. External browser opening remains available after the disclosure warning.',
      FileContentKind.archive =>
        'ZIP and RAR archives can be inspected and extracted from the file context menu.',
      FileContentKind.flash =>
        'SWF is recognized and can be opened interactively through the bundled Ruffle plugin.',
      FileContentKind.container =>
        'TrueCrypt/VeraCrypt-compatible container. Mounting uses the bundled container plugin or an installed VeraCrypt CLI/driver.',
      FileContentKind.unknown =>
        'No built-in viewer association exists yet. Add an extension association in settings or open externally.',
      _ => '',
    };
  }

  static const knownTextEncodings = <String>[
    'utf-8',
    'windows-1251',
    'latin1',
    'utf-16le',
    'utf-16be',
  ];

  static String bytesToText(List<int> bytes, {String encoding = 'auto'}) {
    return decodeText(bytes, encoding: encoding, trim: true);
  }

  static String decodeText(
    List<int> bytes, {
    String encoding = 'auto',
    bool trim = false,
  }) {
    String text;
    try {
      text = switch (encoding.toLowerCase()) {
        'windows-1251' || 'cp1251' => _decodeWindows1251(bytes),
        'latin1' || 'iso-8859-1' => latin1.decode(bytes),
        'utf-16le' => _decodeUtf16(bytes, Endian.little),
        'utf-16be' => _decodeUtf16(bytes, Endian.big),
        'utf-8' => utf8.decode(bytes, allowMalformed: false),
        _ => _decodeAuto(bytes),
      };
    } catch (_) {
      final sample = bytes
          .take(128)
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join(' ');
      return 'Binary file. First bytes:\n$sample';
    }
    if (!trim) return text;
    return text.length > 12000
        ? '${text.substring(0, 12000)}\n\n...trimmed...'
        : text;
  }

  static Uint8List encodeText(String text, {String encoding = 'utf-8'}) {
    final normalized = encoding.toLowerCase();
    return Uint8List.fromList(switch (normalized) {
      'windows-1251' || 'cp1251' => _encodeWindows1251(text),
      'latin1' || 'iso-8859-1' => latin1.encode(text),
      'utf-16le' => _encodeUtf16(text, Endian.little),
      'utf-16be' => _encodeUtf16(text, Endian.big),
      _ => utf8.encode(text),
    });
  }

  static String _htmlSummary(String html) {
    final titleMatch = RegExp(
      r'<title[^>]*>(.*?)</title>',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(html);
    final title = titleMatch == null
        ? ''
        : titleMatch.group(1)!.replaceAll(RegExp(r'\s+'), ' ').trim();
    final text = html
        .replaceAll(
            RegExp(r'<script[\s\S]*?</script>', caseSensitive: false), ' ')
        .replaceAll(
            RegExp(r'<style[\s\S]*?</style>', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final preview = text.length > 12000 ? text.substring(0, 12000) : text;
    return [
      if (title.isNotEmpty) 'Title: $title',
      'Safe HTML text preview:',
      preview,
    ].join('\n\n');
  }

  static String _zipSummary(List<int> bytes) {
    try {
      final archive = ZipDecoder().decodeBytes(bytes, verify: false);
      final lines = <String>[
        'ZIP archive entries: ${archive.files.length}',
        '',
        for (final file in archive.files.take(300))
          '${file.isFile ? 'file' : 'dir '}  ${file.size.toString().padLeft(10)}  ${file.name}',
      ];
      if (archive.files.length > 300) {
        lines.add('...trimmed...');
      }
      return lines.join('\n');
    } catch (error) {
      return 'ZIP archive could not be read: $error';
    }
  }

  static String _flashSummary(List<int> bytes) {
    final signature = bytes.length >= 3
        ? String.fromCharCodes(bytes.take(3)).toUpperCase()
        : '';
    final compressed = signature == 'CWS' || signature == 'ZWS';
    final version = bytes.length > 3 ? bytes[3] : 0;
    return [
      'SWF / Flash object',
      'Version: $version',
      'Compressed: ${compressed ? 'yes' : 'no'}',
      'Interactive opening is available through the preview menu and uses the configured external application or plugin handler.',
    ].join('\n');
  }

  static String _containerSummary(String name, int size) {
    final extension = extensionForName(name);
    final family = switch (extension) {
      '.hc' || '.vc' => 'VeraCrypt',
      '.tc' => 'TrueCrypt',
      _ => 'Encrypted disk',
    };
    return [
      '$family container',
      'Size: $size bytes',
      'Use the container plugin profile or installed VeraCrypt CLI/driver to mount it as a location.',
    ].join('\n');
  }

  static Future<String> _extractDocumentText(
      String name, List<int> bytes) async {
    final extension = extensionForName(name);
    try {
      return switch (extension) {
        '.pdf' => _extractPdfText(bytes),
        '.docx' => _extractZipXmlText(bytes, ['word/document.xml']),
        '.odt' => _extractZipXmlText(bytes, ['content.xml']),
        '.xlsx' => _extractZipXmlText(bytes, [
            'xl/sharedStrings.xml',
            'xl/workbook.xml',
          ]),
        '.pptx' => _extractZipXmlText(bytes, null),
        '.rtf' => _extractRtfText(bytes),
        _ => '',
      };
    } catch (error) {
      return 'Preview extraction failed: $error';
    }
  }

  static Future<String> _extractEbookText(String name, List<int> bytes) async {
    final extension = extensionForName(name);
    try {
      return switch (extension) {
        '.epub' => _extractEpubText(bytes),
        '.fb2' => _extractFb2Text(bytes),
        _ => _trimText(bytesToText(bytes, encoding: 'auto')),
      };
    } catch (error) {
      return 'E-book preview extraction failed: $error';
    }
  }

  static String _extractEpubText(List<int> bytes) {
    final archive = ZipDecoder().decodeBytes(bytes, verify: false);
    final parts = <String>[];
    for (final file in archive.files) {
      final name = file.name.toLowerCase();
      if (!file.isFile ||
          !(name.endsWith('.xhtml') ||
              name.endsWith('.html') ||
              name.endsWith('.htm') ||
              name.endsWith('.xml'))) {
        continue;
      }
      final html = utf8.decode(file.content as List<int>, allowMalformed: true);
      parts.add(_stripMarkup(html));
      if (parts.join(' ').length > 20000) break;
    }
    return _trimText(parts.join(' '));
  }

  static String _extractFb2Text(List<int> bytes) {
    final xmlText = bytesToText(bytes, encoding: 'auto');
    return _trimText(_stripMarkup(xmlText));
  }

  static String _extractPdfText(List<int> bytes) {
    final document = PdfDocument(inputBytes: bytes);
    try {
      final text = PdfTextExtractor(document).extractText();
      return _trimText(text);
    } finally {
      document.dispose();
    }
  }

  static Future<String> _extractZipXmlText(
    List<int> bytes,
    List<String>? preferredFiles,
  ) async {
    final archive = ZipDecoder().decodeBytes(bytes);
    final candidates = preferredFiles ??
        archive.files
            .where((file) => file.isFile && file.name.endsWith('.xml'))
            .map((file) => file.name)
            .toList();
    final parts = <String>[];
    for (final fileName in candidates) {
      final document = archive.findFile(fileName);
      if (document == null || !document.isFile) continue;
      final xmlText =
          utf8.decode(document.content as List<int>, allowMalformed: true);
      final parsed = XmlDocument.parse(xmlText);
      parts.addAll(parsed.descendants
          .whereType<XmlText>()
          .map((node) => node.value.trim())
          .where((text) => text.isNotEmpty));
    }
    return _trimText(parts.join(' '));
  }

  static String _extractRtfText(List<int> bytes) {
    var text = utf8.decode(bytes, allowMalformed: true);
    text = text.replaceAll(RegExp(r"\\'[0-9a-fA-F]{2}"), ' ');
    text = text.replaceAll(RegExp(r'\\[a-zA-Z]+-?\d* ?'), ' ');
    text = text.replaceAll(RegExp(r'[{}]'), ' ');
    text = text.replaceAll(RegExp(r'\s+'), ' ');
    return _trimText(text);
  }

  static String _mediaSummary(String name, List<int> bytes) {
    final extension = extensionForName(name);
    final signature = bytes
        .take(16)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join(' ');
    final details = <String>[
      'Format: ${extension.isEmpty ? 'unknown' : extension.substring(1).toUpperCase()}',
      'Size in memory: ${bytes.length} bytes',
      'First bytes: $signature',
    ];
    if (extension == '.wav' && bytes.length > 44) {
      final data = ByteData.sublistView(Uint8List.fromList(bytes));
      final channels = data.getUint16(22, Endian.little);
      final sampleRate = data.getUint32(24, Endian.little);
      final bits = data.getUint16(34, Endian.little);
      details.add('WAV: $channels channel(s), $sampleRate Hz, $bits-bit');
    } else if (extension == '.mp3' &&
        bytes.length > 3 &&
        utf8.decode(bytes.take(3).toList(), allowMalformed: true) == 'ID3') {
      details.add('MP3 metadata: ID3 tag detected');
    } else if ({'.mp4', '.m4v', '.mov'}.contains(extension)) {
      details.add(
          'MP4/MOV container detected; protected playback avoids writing decrypted bytes to disk.');
    }
    return details.join('\n');
  }

  static String _trimText(String text) {
    final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return normalized.length > 12000
        ? '${normalized.substring(0, 12000)}\n\n...trimmed...'
        : normalized;
  }

  static String _stripMarkup(String value) {
    return value
        .replaceAll(
            RegExp(r'<script[\s\S]*?</script>', caseSensitive: false), ' ')
        .replaceAll(
            RegExp(r'<style[\s\S]*?</style>', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll(RegExp(r'&nbsp;'), ' ')
        .replaceAll(RegExp(r'&amp;'), '&')
        .replaceAll(RegExp(r'&lt;'), '<')
        .replaceAll(RegExp(r'&gt;'), '>')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static String _decodeAuto(List<int> bytes) {
    if (bytes.length >= 2) {
      if (bytes[0] == 0xFF && bytes[1] == 0xFE) {
        return _decodeUtf16(bytes.sublist(2), Endian.little);
      }
      if (bytes[0] == 0xFE && bytes[1] == 0xFF) {
        return _decodeUtf16(bytes.sublist(2), Endian.big);
      }
    }
    try {
      return utf8.decode(bytes, allowMalformed: false);
    } catch (_) {
      return _decodeWindows1251(bytes);
    }
  }

  static String _decodeUtf16(List<int> bytes, Endian endian) {
    final buffer = StringBuffer();
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      final code = endian == Endian.little
          ? bytes[i] | (bytes[i + 1] << 8)
          : (bytes[i] << 8) | bytes[i + 1];
      buffer.writeCharCode(code);
    }
    return buffer.toString();
  }

  static List<int> _encodeUtf16(String text, Endian endian) {
    final out = <int>[];
    for (final unit in text.codeUnits) {
      if (endian == Endian.little) {
        out
          ..add(unit & 0xFF)
          ..add((unit >> 8) & 0xFF);
      } else {
        out
          ..add((unit >> 8) & 0xFF)
          ..add(unit & 0xFF);
      }
    }
    return out;
  }

  static String _decodeWindows1251(List<int> bytes) =>
      String.fromCharCodes(bytes.map(_windows1251ToUnicode));

  static List<int> _encodeWindows1251(String text) =>
      text.runes.map(_unicodeToWindows1251).toList();

  static int _windows1251ToUnicode(int byte) {
    if (byte < 0x80) return byte;
    if (byte >= 0xC0) return 0x0410 + (byte - 0xC0);
    return _cp1251Upper[byte - 0x80];
  }

  static int _unicodeToWindows1251(int rune) {
    if (rune < 0x80) return rune;
    if (rune >= 0x0410 && rune <= 0x044F) return 0xC0 + (rune - 0x0410);
    final index = _cp1251Upper.indexOf(rune);
    return index >= 0 ? index + 0x80 : 0x3F;
  }

  static const _cp1251Upper = <int>[
    0x0402,
    0x0403,
    0x201A,
    0x0453,
    0x201E,
    0x2026,
    0x2020,
    0x2021,
    0x20AC,
    0x2030,
    0x0409,
    0x2039,
    0x040A,
    0x040C,
    0x040B,
    0x040F,
    0x0452,
    0x2018,
    0x2019,
    0x201C,
    0x201D,
    0x2022,
    0x2013,
    0x2014,
    0x0000,
    0x2122,
    0x0459,
    0x203A,
    0x045A,
    0x045C,
    0x045B,
    0x045F,
    0x00A0,
    0x040E,
    0x045E,
    0x0408,
    0x00A4,
    0x0490,
    0x00A6,
    0x00A7,
    0x0401,
    0x00A9,
    0x0404,
    0x00AB,
    0x00AC,
    0x00AD,
    0x00AE,
    0x0407,
    0x00B0,
    0x00B1,
    0x0406,
    0x0456,
    0x0491,
    0x00B5,
    0x00B6,
    0x00B7,
    0x0451,
    0x2116,
    0x0454,
    0x00BB,
    0x0458,
    0x0405,
    0x0455,
    0x0457,
  ];
}
