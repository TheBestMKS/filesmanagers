# CRYPT Format v1.0

## 1. Scope

This document defines the starter binary format for:

- file containers: `f_<FILE_ID_HEX>.crypt`
- folder metadata containers: `.folder.cryptmeta`

The goal of `v1.0` is to lock down strict, extensible binary layouts for metadata and outer file envelopes while keeping payload cryptography pluggable for the next stage.

## 2. Normative Rules

- Endianness: little-endian
- Packing: no implicit struct padding is allowed in the serialized format
- Strings: UTF-8, length-prefixed, no null terminator
- Time fields: `u64` Unix UTC milliseconds
- Algorithm identifiers: stored as `u16`; valid range is `0..511`
- Reserved fields: must be serialized as zero and rejected if non-zero on read
- Every container stores `format_major : u16` and `format_minor : u16`
- Every container begins with the same `Common Header`
- Minor-compatible extensibility uses TLV blocks

## 3. Physical Naming Rules

### 3.1 Folders

- physical folder name: `d_<FOLDER_ID_HEX>`
- `FOLDER_ID_HEX` is exactly 32 lowercase hex characters representing 16 bytes
- each vault folder must contain a metadata file named `.folder.cryptmeta`

### 3.2 Files

- physical file name: `f_<FILE_ID_HEX>.crypt`
- `FILE_ID_HEX` is exactly 32 lowercase hex characters representing 16 bytes

### 3.3 Privacy Rule

Real file names and folder names must never be derivable from filesystem names. The real names live only in encrypted metadata.

## 4. Primitive Types

| Type | Size | Notes |
|---|---:|---|
| `u8` | 1 | unsigned |
| `u16` | 2 | unsigned, little-endian |
| `u32` | 4 | unsigned, little-endian |
| `u64` | 8 | unsigned, little-endian |
| `bytes[n]` | n | raw byte array |
| `utf8` | var | encoded as `u16 byte_len` + `byte_len` bytes |

This starter uses `u16`-length UTF-8 strings to keep metadata compact. Readers must reject malformed UTF-8 if a later stage adds validation; current code validates only length and storage rules.

## 5. Common Header

The `Common Header` is present at offset `0` in every container.

| Field | Type | Value / Rule |
|---|---|---|
| `magic` | `bytes[8]` | ASCII `CRYPTFMT` |
| `container_type` | `u16` | enum, strict |
| `format_major` | `u16` | currently `1` |
| `format_minor` | `u16` | currently `0` |
| `header_size` | `u16` | total bytes from offset `0` through the fixed header and all immediately following fixed outer fields, excluding variable payloads |
| `extension_count` | `u16` | count of TLV extension records that directly follow the fixed fields for the current container |
| `flags` | `u32` | currently must be `0` |
| `reserved0` | `u32` | must be `0` |

Fixed serialized size: `26` bytes.

Validation rules:

- `magic` must match exactly
- `format_major` must equal `1`
- `format_minor` must be `0`
- `header_size` must equal the fixed size of the specific container in `v1.0`
- `flags == 0`
- `reserved0 == 0`

## 6. TLV Extensions

TLV entries enable backward-compatible growth within the same major version.

TLV record format:

| Field | Type | Rule |
|---|---|---|
| `tag` | `u16` | non-zero |
| `length` | `u16` | byte length |
| `value` | `bytes[length]` | opaque |

TLVs are serialized contiguously. Unknown tags must be preserved by higher-level rewrite flows in later stages. In this starter they are parsed and exposed as opaque records.

## 7. Container Types

| Name | Value |
|---|---:|
| `CRYPT_CONTAINER_FILE` | 1 |
| `CRYPT_CONTAINER_FOLDER_META` | 2 |

## 8. Algorithm IDs v1.0

| Family | Name | Value |
|---|---|---:|
| header KDF | Argon2id | 1 |
| header cipher | XChaCha20-Poly1305 | 1 |
| payload cipher | XChaCha20-Poly1305-Chunked-V1 | 1 |
| name KDF | Argon2id | 1 |
| name cipher | XChaCha20-Poly1305 | 1 |

`0` is reserved for "unspecified / invalid".

## 9. .folder.cryptmeta Container

Container type: `CRYPT_CONTAINER_FOLDER_META`

After the `Common Header`, the fixed folder-meta fields are serialized:

| Field | Type | Rule |
|---|---|---|
| `folder_id` | `bytes[16]` | random stable folder id |
| `parent_folder_id` | `bytes[16]` | zero for root vault folder |
| `created_at_utc_ms` | `u64` | required |
| `updated_at_utc_ms` | `u64` | required |
| `name_kdf_id` | `u16` | valid algorithm id |
| `name_cipher_id` | `u16` | valid algorithm id |
| `preview_type` | `u16` | enum, currently `0` only |
| `reserved1` | `u16` | zero |
| `encrypted_name_len` | `u32` | bytes following TLV area |
| `encrypted_preview_len` | `u32` | bytes following encrypted name |

Fixed size including `Common Header`: `90` bytes.

Layout:

```text
[Common Header: 26]
[Folder fixed fields: 64]
[TLV extensions]
[encrypted_name bytes]
[encrypted_preview bytes]
```

Notes:

- `encrypted_name` contains the real folder name ciphertext.
- `encrypted_preview` is reserved for future folder preview payload; in `v1.0` it may be empty.
- root folder is represented by all-zero `parent_folder_id`.

## 10. .crypt File Container

Container type: `CRYPT_CONTAINER_FILE`

After the `Common Header`, the fixed file outer fields are serialized:

| Field | Type | Rule |
|---|---|---|
| `file_id` | `bytes[16]` | random stable file id |
| `parent_folder_id` | `bytes[16]` | owning logical folder id |
| `created_at_utc_ms` | `u64` | required |
| `updated_at_utc_ms` | `u64` | required |
| `original_size` | `u64` | plaintext bytes |
| `stored_size` | `u64` | encrypted payload bytes, may be `0` before payload write |
| `header_kdf_id` | `u16` | valid algorithm id |
| `header_cipher_id` | `u16` | valid algorithm id |
| `payload_cipher_id` | `u16` | valid algorithm id |
| `preview_type` | `u16` | enum |
| `chunk_size` | `u32` | planned payload chunk size, non-zero in final encrypted files |
| `encrypted_header_len` | `u32` | bytes following TLV area |

Fixed size including `Common Header`: `106` bytes.

Layout:

```text
[Common Header: 26]
[File fixed fields: 80]
[TLV extensions]
[encrypted_header bytes]
[encrypted payload bytes]
```

### 10.1 Encrypted Header Payload Contract

The encrypted header is opaque in this starter, but `v1.0` reserves it for:

- real file name
- MIME hint
- per-file random `file_key`
- optional preview bytes
- optional future chunk-table metadata

The encrypted header must be password-derived and authenticated independently from the file payload.

### 10.2 Payload Contract

The encrypted payload is not implemented yet, but the format contract is:

- each file has its own random `file_key`
- payload is encrypted chunk-by-chunk
- random seek/read of individual chunks must be possible
- chunk nonce and AAD derivation must be deterministic from file metadata and chunk index
- previews must live only inside the encrypted header, not in open plaintext

## 11. Preview Types

| Name | Value |
|---|---:|
| `CRYPT_PREVIEW_NONE` | 0 |
| `CRYPT_PREVIEW_JPEG` | 1 |
| `CRYPT_PREVIEW_WEBP` | 2 |
| `CRYPT_PREVIEW_PNG` | 3 |

In this starter, only enum validation is enforced. Semantic decoding is deferred.

## 12. Validation Rules

Readers must fail on any of the following:

- wrong magic
- unsupported `container_type`
- unsupported `format_major`
- unsupported `format_minor`
- invalid `header_size`
- algorithm id outside `0..511`
- required algorithm field equal to `0`
- non-zero reserved fields
- buffer shorter than declared lengths
- TLV record overrun
- `tag == 0` in a TLV

Additional strict starter rules:

- `.folder.cryptmeta` must use `name_kdf_id != 0` and `name_cipher_id != 0`
- `.crypt` must use `header_kdf_id != 0`, `header_cipher_id != 0`, and `payload_cipher_id != 0`
- all fixed-layout parsers reject trailing truncation immediately

## 13. Compatibility Policy

- `format_major` changes indicate breaking layout or semantic changes
- `format_minor` changes must remain readable by older readers when they ignore unknown TLVs
- older readers may reject containers with unsupported mandatory semantics introduced without a major bump

## 14. Starter Implementation Limits

The starter code intentionally does not:

- derive keys
- encrypt headers
- encrypt payloads
- validate UTF-8 correctness byte-by-byte
- preserve unknown TLVs during rewrite yet beyond in-memory round-trip APIs

It does define exact byte layout, error handling, parser/writer responsibilities, and upgrade points.
