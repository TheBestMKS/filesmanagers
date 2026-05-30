import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../vault/vault_models.dart';

typedef _CryptCoreVersionNative = ffi.Pointer<Utf8> Function();
typedef _CryptCoreVersionDart = ffi.Pointer<Utf8> Function();
typedef _CryptGetRuntimeInfoNative = ffi.Uint32 Function(
    ffi.Pointer<_NativeRuntimeInfo>);
typedef _CryptGetRuntimeInfoDart = int Function(
    ffi.Pointer<_NativeRuntimeInfo>);
typedef _CryptProbeContainerNative = ffi.Uint32 Function(
  ffi.Pointer<ffi.Uint8>,
  ffi.IntPtr,
  ffi.Pointer<_NativeProbeResult>,
);
typedef _CryptProbeContainerDart = int Function(
  ffi.Pointer<ffi.Uint8>,
  int,
  ffi.Pointer<_NativeProbeResult>,
);
typedef _CryptReadFolderMetaSummaryNative = ffi.Uint32 Function(
  ffi.Pointer<ffi.Uint8>,
  ffi.IntPtr,
  ffi.Pointer<_NativeFolderMetaSummary>,
);
typedef _CryptReadFolderMetaSummaryDart = int Function(
  ffi.Pointer<ffi.Uint8>,
  int,
  ffi.Pointer<_NativeFolderMetaSummary>,
);
typedef _CryptReadFileContainerSummaryNative = ffi.Uint32 Function(
  ffi.Pointer<ffi.Uint8>,
  ffi.IntPtr,
  ffi.Pointer<_NativeFileContainerSummary>,
);
typedef _CryptReadFileContainerSummaryDart = int Function(
  ffi.Pointer<ffi.Uint8>,
  int,
  ffi.Pointer<_NativeFileContainerSummary>,
);

final class _NativeRuntimeInfo extends ffi.Struct {
  @ffi.Uint16()
  external int apiMajor;

  @ffi.Uint16()
  external int apiMinor;

  @ffi.Uint16()
  external int formatMajor;

  @ffi.Uint16()
  external int formatMinor;

  @ffi.Uint16()
  external int androidMinSdk;

  @ffi.Uint16()
  external int reserved0;

  @ffi.Uint32()
  external int capabilities;
}

final class _NativeProbeResult extends ffi.Struct {
  @ffi.Uint16()
  external int statusCode;

  @ffi.Uint16()
  external int containerType;

  @ffi.Uint16()
  external int formatMajor;

  @ffi.Uint16()
  external int formatMinor;

  @ffi.Uint16()
  external int headerSize;

  @ffi.Uint16()
  external int extensionCount;

  @ffi.Uint32()
  external int flags;
}

final class _NativeFolderMetaSummary extends ffi.Struct {
  @ffi.Uint16()
  external int statusCode;

  @ffi.Uint16()
  external int previewType;

  @ffi.Uint16()
  external int nameKdfId;

  @ffi.Uint16()
  external int nameCipherId;

  @ffi.Uint64()
  external int createdAtUtcMs;

  @ffi.Uint64()
  external int updatedAtUtcMs;

  @ffi.Uint32()
  external int encryptedNameLen;

  @ffi.Uint32()
  external int encryptedPreviewLen;

  @ffi.Array.multi([16])
  external ffi.Array<ffi.Uint8> folderId;

  @ffi.Array.multi([16])
  external ffi.Array<ffi.Uint8> parentFolderId;
}

final class _NativeFileContainerSummary extends ffi.Struct {
  @ffi.Uint16()
  external int statusCode;

  @ffi.Uint16()
  external int previewType;

  @ffi.Uint16()
  external int headerKdfId;

  @ffi.Uint16()
  external int headerCipherId;

  @ffi.Uint16()
  external int payloadCipherId;

  @ffi.Uint16()
  external int reservedAlign0;

  @ffi.Uint32()
  external int reservedAlign1;

  @ffi.Uint64()
  external int createdAtUtcMs;

  @ffi.Uint64()
  external int updatedAtUtcMs;

  @ffi.Uint64()
  external int originalSize;

  @ffi.Uint64()
  external int storedSize;

  @ffi.Uint32()
  external int chunkSize;

  @ffi.Uint32()
  external int encryptedHeaderLen;

  @ffi.Uint32()
  external int encryptedPayloadLen;

  @ffi.Array.multi([16])
  external ffi.Array<ffi.Uint8> fileId;

  @ffi.Array.multi([16])
  external ffi.Array<ffi.Uint8> parentFolderId;
}

class CryptRuntimeInfo {
  const CryptRuntimeInfo({
    required this.isLoaded,
    required this.versionText,
    required this.apiMajor,
    required this.apiMinor,
    required this.formatMajor,
    required this.formatMinor,
    required this.androidMinSdk,
    required this.capabilities,
  });

  final bool isLoaded;
  final String versionText;
  final int apiMajor;
  final int apiMinor;
  final int formatMajor;
  final int formatMinor;
  final int androidMinSdk;
  final int capabilities;

  bool get supportsCommonHeader => (capabilities & (1 << 0)) != 0;
  bool get supportsFolderMeta => (capabilities & (1 << 1)) != 0;
  bool get supportsFileContainer => (capabilities & (1 << 2)) != 0;
  bool get supportsStrictValidation => (capabilities & (1 << 3)) != 0;
  bool get supportsTlvExtensions => (capabilities & (1 << 4)) != 0;

  static const unavailable = CryptRuntimeInfo(
    isLoaded: false,
    versionText: 'crypt_core native library not available in this shell yet.',
    apiMajor: 0,
    apiMinor: 0,
    formatMajor: 0,
    formatMinor: 0,
    androidMinSdk: 24,
    capabilities: 0,
  );
}

class CryptBindings {
  CryptBindings() : _lib = _tryOpenLibrary();

  final ffi.DynamicLibrary? _lib;

  Future<String> describeCoreVersion() async {
    final lib = _lib;
    if (lib == null) {
      return 'crypt_core native library not available in this shell yet.';
    }
    try {
      final fn =
          lib.lookupFunction<_CryptCoreVersionNative, _CryptCoreVersionDart>(
        'crypt_core_version',
      );
      final ptr = fn();
      return ptr.toDartString();
    } catch (_) {
      return 'crypt_core native library not available in this shell yet.';
    }
  }

  Future<CryptRuntimeInfo> getRuntimeInfo() async {
    final lib = _lib;
    if (lib == null) {
      return CryptRuntimeInfo.unavailable;
    }
    try {
      final version = await describeCoreVersion();
      final fn = lib
          .lookupFunction<_CryptGetRuntimeInfoNative, _CryptGetRuntimeInfoDart>(
        'crypt_get_runtime_info',
      );
      final infoPtr = calloc<_NativeRuntimeInfo>();
      try {
        final status = fn(infoPtr);
        if (status != 0) {
          return CryptRuntimeInfo.unavailable;
        }
        final info = infoPtr.ref;
        return CryptRuntimeInfo(
          isLoaded: true,
          versionText: version,
          apiMajor: info.apiMajor,
          apiMinor: info.apiMinor,
          formatMajor: info.formatMajor,
          formatMinor: info.formatMinor,
          androidMinSdk: info.androidMinSdk,
          capabilities: info.capabilities,
        );
      } finally {
        calloc.free(infoPtr);
      }
    } catch (_) {
      return CryptRuntimeInfo.unavailable;
    }
  }

  Future<VaultContainerInfo> inspectFolderMeta(Uint8List bytes) async {
    final lib = _lib;
    if (lib == null) {
      return _unavailableContainerInfo();
    }
    try {
      final probe = _probe(bytes);
      final fn = lib.lookupFunction<_CryptReadFolderMetaSummaryNative,
          _CryptReadFolderMetaSummaryDart>('crypt_read_folder_meta_summary');
      final bytesPtr = calloc<ffi.Uint8>(bytes.length);
      final summaryPtr = calloc<_NativeFolderMetaSummary>();
      try {
        bytesPtr.asTypedList(bytes.length).setAll(0, bytes);
        final status = fn(bytesPtr, bytes.length, summaryPtr);
        final summary = summaryPtr.ref;
        return VaultContainerInfo(
          statusCode: status,
          containerType: probe.containerType,
          formatMajor: probe.formatMajor,
          formatMinor: probe.formatMinor,
          headerSize: probe.headerSize,
          extensionCount: probe.extensionCount,
          flags: probe.flags,
          previewType: summary.previewType,
          nameKdfId: summary.nameKdfId,
          nameCipherId: summary.nameCipherId,
          encryptedNameLength: summary.encryptedNameLen,
          encryptedPreviewLength: summary.encryptedPreviewLen,
        );
      } finally {
        calloc.free(bytesPtr);
        calloc.free(summaryPtr);
      }
    } catch (_) {
      return _unavailableContainerInfo();
    }
  }

  Future<VaultContainerInfo> inspectFileContainer(Uint8List bytes) async {
    final lib = _lib;
    if (lib == null) {
      return _unavailableContainerInfo();
    }
    try {
      final probe = _probe(bytes);
      final fn = lib.lookupFunction<_CryptReadFileContainerSummaryNative,
              _CryptReadFileContainerSummaryDart>(
          'crypt_read_file_container_summary');
      final bytesPtr = calloc<ffi.Uint8>(bytes.length);
      final summaryPtr = calloc<_NativeFileContainerSummary>();
      try {
        bytesPtr.asTypedList(bytes.length).setAll(0, bytes);
        final status = fn(bytesPtr, bytes.length, summaryPtr);
        final summary = summaryPtr.ref;
        return VaultContainerInfo(
          statusCode: status,
          containerType: probe.containerType,
          formatMajor: probe.formatMajor,
          formatMinor: probe.formatMinor,
          headerSize: probe.headerSize,
          extensionCount: probe.extensionCount,
          flags: probe.flags,
          previewType: summary.previewType,
          headerKdfId: summary.headerKdfId,
          headerCipherId: summary.headerCipherId,
          payloadCipherId: summary.payloadCipherId,
          chunkSize: summary.chunkSize,
          originalSize: summary.originalSize,
          storedSize: summary.storedSize,
          encryptedHeaderLength: summary.encryptedHeaderLen,
          encryptedPayloadLength: summary.encryptedPayloadLen,
        );
      } finally {
        calloc.free(bytesPtr);
        calloc.free(summaryPtr);
      }
    } catch (_) {
      return _unavailableContainerInfo();
    }
  }

  VaultContainerInfo _probe(Uint8List bytes) {
    final lib = _lib;
    if (lib == null) {
      return _unavailableContainerInfo();
    }
    final fn = lib
        .lookupFunction<_CryptProbeContainerNative, _CryptProbeContainerDart>(
      'crypt_probe_container',
    );
    final bytesPtr = calloc<ffi.Uint8>(bytes.length);
    final resultPtr = calloc<_NativeProbeResult>();
    try {
      bytesPtr.asTypedList(bytes.length).setAll(0, bytes);
      final status = fn(bytesPtr, bytes.length, resultPtr);
      final result = resultPtr.ref;
      return VaultContainerInfo(
        statusCode: status == 0 ? result.statusCode : status,
        containerType: result.containerType,
        formatMajor: result.formatMajor,
        formatMinor: result.formatMinor,
        headerSize: result.headerSize,
        extensionCount: result.extensionCount,
        flags: result.flags,
      );
    } finally {
      calloc.free(bytesPtr);
      calloc.free(resultPtr);
    }
  }

  static VaultContainerInfo _unavailableContainerInfo() {
    return const VaultContainerInfo(
      statusCode: 1,
      containerType: 0,
      formatMajor: 0,
      formatMinor: 0,
      headerSize: 0,
      extensionCount: 0,
      flags: 0,
    );
  }

  static ffi.DynamicLibrary? _tryOpenLibrary() {
    try {
      if (Platform.isAndroid || Platform.isLinux) {
        return ffi.DynamicLibrary.open('libcrypt_core.so');
      }
      if (Platform.isWindows) {
        return ffi.DynamicLibrary.open('crypt_core.dll');
      }
    } catch (_) {
      return null;
    }
    return null;
  }
}
