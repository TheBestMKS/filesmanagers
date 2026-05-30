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
    if (textExtensions.contains(extension)) return FileContentKind.text;
    if (documentExtensions.contains(extension)) return FileContentKind.document;
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
          bytes: await file.readAsBytes(),
          contentKind: kind);
    }
    if (kind == FileContentKind.text && size <= 1024 * 1024) {
      final bytes = await file.readAsBytes();
      return FilePreview(
          title: name,
          subtitle: 'Text, $size bytes',
          text: _bytesToText(bytes),
          bytes: bytes,
          contentKind: kind);
    }
    if (kind == FileContentKind.html && size <= 2 * 1024 * 1024) {
      final bytes = await file.readAsBytes();
      return FilePreview(
        title: name,
        subtitle: 'HTML, $size bytes',
        text: _htmlSummary(_bytesToText(bytes)),
        bytes: bytes,
        contentKind: kind,
      );
    }
    if (kind == FileContentKind.archive && size <= 80 * 1024 * 1024) {
      final bytes = await file.readAsBytes();
      return FilePreview(
        title: name,
        subtitle: 'ZIP archive, $size bytes',
        text: _zipSummary(bytes),
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
        text: _mediaSummary(name, bytes),
        bytes: bytes,
        contentKind: kind,
      );
    }
    return FilePreview(
        title: name,
        subtitle: _kindSubtitle(kind, size),
        text: _fallbackText(kind),
        contentKind: kind);
  }

  static Future<FilePreview> previewBytes({
    required String name,
    required Uint8List bytes,
    required String subtitle,
    VaultContainerInfo? containerInfo,
  }) async {
    final kind = kindForName(name);
    if (kind == FileContentKind.image && bytes.length <= 25 * 1024 * 1024) {
      return FilePreview(
          title: name,
          subtitle: subtitle,
          bytes: bytes,
          containerInfo: containerInfo,
          decrypted: true,
          contentKind: kind);
    }
    if (kind == FileContentKind.text && bytes.length <= 1024 * 1024) {
      return FilePreview(
          title: name,
          subtitle: subtitle,
          text: _bytesToText(bytes),
          bytes: bytes,
          containerInfo: containerInfo,
          decrypted: true,
          contentKind: kind);
    }
    if (kind == FileContentKind.html && bytes.length <= 2 * 1024 * 1024) {
      return FilePreview(
          title: name,
          subtitle: subtitle,
          text: _htmlSummary(_bytesToText(bytes)),
          bytes: bytes,
          containerInfo: containerInfo,
          decrypted: true,
          contentKind: kind);
    }
    if (kind == FileContentKind.archive && bytes.length <= 80 * 1024 * 1024) {
      return FilePreview(
          title: name,
          subtitle: subtitle,
          text: _zipSummary(bytes),
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
          text: _mediaSummary(name, bytes),
          bytes: bytes,
          containerInfo: containerInfo,
          decrypted: true,
          contentKind: kind);
    }
    return FilePreview(
        title: name,
        subtitle: subtitle,
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
      FileContentKind.html => 'HTML page, $size bytes',
      FileContentKind.archive => 'Archive file, $size bytes',
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
      FileContentKind.html =>
        'HTML pages are rendered as a safe in-app text preview. External browser opening is available after the disclosure warning.',
      FileContentKind.archive =>
        'ZIP archives can be inspected and extracted from the file context menu.',
      FileContentKind.unknown =>
        'No built-in viewer association exists yet. Add an extension association in settings or open externally.',
      _ => '',
    };
  }

  static String _bytesToText(List<int> bytes) {
    try {
      final text = utf8.decode(bytes, allowMalformed: false);
      return text.length > 12000
          ? '${text.substring(0, 12000)}\n\n...trimmed...'
          : text;
    } catch (_) {
      final sample = bytes
          .take(128)
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join(' ');
      return 'Binary file. First bytes:\n$sample';
    }
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
}
