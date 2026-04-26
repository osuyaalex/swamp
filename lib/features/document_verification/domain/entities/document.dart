import 'dart:typed_data';

import 'package:flutter/material.dart';

enum DocumentType { passport, nationalId, utilityBill }

extension DocumentTypeX on DocumentType {
  /// Wire-format string used by the API spec ("PASSPORT", "NATIONAL_ID",
  /// "UTILITY_BILL"). Kept as a tiny mapping so the entity stays decoupled
  /// from the network protocol.
  String get wire => switch (this) {
        DocumentType.passport => 'PASSPORT',
        DocumentType.nationalId => 'NATIONAL_ID',
        DocumentType.utilityBill => 'UTILITY_BILL',
      };

  String get label => switch (this) {
        DocumentType.passport => 'Passport',
        DocumentType.nationalId => 'National ID',
        DocumentType.utilityBill => 'Utility Bill',
      };

  IconData get icon => switch (this) {
        DocumentType.passport => Icons.book_outlined,
        DocumentType.nationalId => Icons.badge_outlined,
        DocumentType.utilityBill => Icons.receipt_long_outlined,
      };

  static DocumentType fromWire(String wire) => switch (wire) {
        'PASSPORT' => DocumentType.passport,
        'NATIONAL_ID' => DocumentType.nationalId,
        'UTILITY_BILL' => DocumentType.utilityBill,
        _ => throw ArgumentError('Unknown document type wire: $wire'),
      };
}

/// Lifecycle of a document. Local-only "queued"/"uploading" phases sit in
/// front of the API-defined statuses so the UI can render upload progress
/// without having to special-case "this isn't on the server yet."
enum DocumentStatus {
  queued, // local: waiting to start uploading (e.g. offline)
  uploading, // local: bytes being sent
  uploaded, // server: ack received, awaiting first PROCESSING update
  processing, // server: pipeline running
  verified, // server: terminal-success
  rejected, // server: terminal-failure
}

extension DocumentStatusX on DocumentStatus {
  String get label => switch (this) {
        DocumentStatus.queued => 'Queued',
        DocumentStatus.uploading => 'Uploading',
        DocumentStatus.uploaded => 'Uploaded',
        DocumentStatus.processing => 'Processing',
        DocumentStatus.verified => 'Verified',
        DocumentStatus.rejected => 'Rejected',
      };

  bool get isTerminal =>
      this == DocumentStatus.verified || this == DocumentStatus.rejected;

  bool get isPendingServer =>
      this == DocumentStatus.uploaded || this == DocumentStatus.processing;

  Color get color => switch (this) {
        DocumentStatus.queued => const Color(0xFF9E9E9E),
        DocumentStatus.uploading => const Color(0xFF1976D2),
        DocumentStatus.uploaded => const Color(0xFF1976D2),
        DocumentStatus.processing => const Color(0xFFFFA000),
        DocumentStatus.verified => const Color(0xFF2E7D32),
        DocumentStatus.rejected => const Color(0xFFE53935),
      };

  /// Wire-format mapping for parsing API payloads. Local-only statuses
  /// have no wire form.
  static DocumentStatus fromWire(String wire) => switch (wire) {
        'PENDING' => DocumentStatus.uploaded,
        'UPLOADED' => DocumentStatus.uploaded,
        'PROCESSING' => DocumentStatus.processing,
        'VERIFIED' => DocumentStatus.verified,
        'REJECTED' => DocumentStatus.rejected,
        _ => throw ArgumentError('Unknown status wire: $wire'),
      };
}

enum AuditKind {
  uploaded,
  statusChanged,
  retried,
  verified,
  rejected,
  deleted,
  /// Biometric prompt passed before viewing a verified document.
  accessGranted,
  /// Biometric prompt failed or was cancelled — kept for compliance.
  accessDenied,
}

/// Compliance-grade audit entry.
///
/// Beyond the message + timestamp the entry captures *who* (actor),
/// *from where* (deviceId, appVersion), and includes a tamper-evident
/// HMAC chain (`prevHash` + `signature`) so an auditor can detect any
/// post-hoc edits to the log.
///
/// `signature` and `prevHash` are populated by `AuditSigner` at the
/// moment the entry is appended; entries that pre-date the introduction
/// of signing (or those constructed by tests with a null signer) leave
/// the fields empty and validate accordingly.
@immutable
class AuditEntry {
  const AuditEntry({
    required this.id,
    required this.kind,
    required this.message,
    required this.at,
    this.actor = 'system',
    this.deviceId = '',
    this.appVersion = '',
    this.prevHash = '',
    this.signature = '',
  });

  final String id;
  final AuditKind kind;
  final String message;
  final DateTime at;

  /// Who triggered the entry (today: 'You' for user actions, 'system'
  /// for server-driven status updates). In a real backend this would be
  /// the authenticated user id.
  final String actor;

  /// Device identifier this entry was written from.
  final String deviceId;

  /// App version that wrote the entry.
  final String appVersion;

  /// SHA-256 of the previous entry's signature, base64. Empty for the
  /// first entry on a document.
  final String prevHash;

  /// HMAC-SHA-256 over the entry payload + prevSignature, base64.
  final String signature;

  /// Canonical payload used as the input to the signature. Defined here
  /// so the signer and any verifier hash *exactly* the same bytes.
  Map<String, Object?> canonicalPayload() => {
        'id': id,
        'kind': kind.name,
        'message': message,
        'at': at.toIso8601String(),
        'actor': actor,
        'deviceId': deviceId,
        'appVersion': appVersion,
        'prevHash': prevHash,
      };

  Map<String, dynamic> toJson() => {
        ...canonicalPayload(),
        'signature': signature,
      };

  factory AuditEntry.fromJson(Map<String, dynamic> json) => AuditEntry(
        id: json['id'] as String,
        kind: AuditKind.values.byName(json['kind'] as String),
        message: json['message'] as String,
        at: DateTime.parse(json['at'] as String),
        actor: (json['actor'] as String?) ?? 'system',
        deviceId: (json['deviceId'] as String?) ?? '',
        appVersion: (json['appVersion'] as String?) ?? '',
        prevHash: (json['prevHash'] as String?) ?? '',
        signature: (json['signature'] as String?) ?? '',
      );
}

/// File payload kept alongside the document so retry can re-upload without
/// asking the user to re-pick. Bytes live in memory; a real impl would
/// stream them from disk.
@immutable
class DocumentBytes {
  const DocumentBytes({
    required this.bytes,
    required this.originalName,
    required this.mimeType,
    required this.size,
    required this.checksum,
  });

  final Uint8List bytes;
  final String originalName;
  final String mimeType; // image/jpeg, image/png, application/pdf
  final int size; // bytes
  final String checksum; // sha-ish — mock impl uses a quick hash
}

@immutable
class Document {
  const Document({
    required this.id,
    required this.type,
    required this.status,
    required this.progress,
    required this.originalName,
    required this.size,
    required this.checksum,
    required this.createdAt,
    required this.audit,
    this.serverId,
    this.uploadedAt,
    this.verifiedAt,
    this.expiresAt,
    this.stage,
    this.confidence,
    this.issues = const [],
    this.rejectionReason,
    this.bytes,
  });

  /// Stable client-side id. Survives offline → online → retry cycles.
  final String id;

  /// Server-issued id, populated on first successful upload response.
  final String? serverId;

  final DocumentType type;
  final DocumentStatus status;
  final double progress; // 0.0 .. 1.0

  // Metadata from the picker. Persisted across restarts.
  final String originalName;
  final int size;
  final String checksum;

  final DateTime createdAt;
  final DateTime? uploadedAt;
  final DateTime? verifiedAt;
  final DateTime? expiresAt;

  // Latest WS-pushed details (or last polled values).
  final String? stage;
  final double? confidence;
  final List<String> issues;
  final String? rejectionReason;

  /// Optional in-memory file bytes for retry. Not persisted.
  final DocumentBytes? bytes;

  final List<AuditEntry> audit;

  Document copyWith({
    String? serverId,
    DocumentStatus? status,
    double? progress,
    DateTime? uploadedAt,
    DateTime? verifiedAt,
    DateTime? expiresAt,
    String? stage,
    double? confidence,
    List<String>? issues,
    String? rejectionReason,
    bool clearRejection = false,
    DocumentBytes? bytes,
    bool clearBytes = false,
    List<AuditEntry>? audit,
  }) {
    return Document(
      id: id,
      serverId: serverId ?? this.serverId,
      type: type,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      originalName: originalName,
      size: size,
      checksum: checksum,
      createdAt: createdAt,
      uploadedAt: uploadedAt ?? this.uploadedAt,
      verifiedAt: verifiedAt ?? this.verifiedAt,
      expiresAt: expiresAt ?? this.expiresAt,
      stage: stage ?? this.stage,
      confidence: confidence ?? this.confidence,
      issues: issues ?? this.issues,
      rejectionReason:
          clearRejection ? null : (rejectionReason ?? this.rejectionReason),
      bytes: clearBytes ? null : (bytes ?? this.bytes),
      audit: audit ?? this.audit,
    );
  }

  // -------------------- Persistence (without bytes) -------------------------

  Map<String, dynamic> toJson() => {
        'id': id,
        'serverId': serverId,
        'type': type.name,
        'status': status.name,
        'progress': progress,
        'originalName': originalName,
        'size': size,
        'checksum': checksum,
        'createdAt': createdAt.toIso8601String(),
        'uploadedAt': uploadedAt?.toIso8601String(),
        'verifiedAt': verifiedAt?.toIso8601String(),
        'expiresAt': expiresAt?.toIso8601String(),
        'stage': stage,
        'confidence': confidence,
        'issues': issues,
        'rejectionReason': rejectionReason,
        'audit': audit.map((e) => e.toJson()).toList(),
      };

  factory Document.fromJson(Map<String, dynamic> json) => Document(
        id: json['id'] as String,
        serverId: json['serverId'] as String?,
        type: DocumentType.values.byName(json['type'] as String),
        status: DocumentStatus.values.byName(json['status'] as String),
        progress: (json['progress'] as num).toDouble(),
        originalName: json['originalName'] as String,
        size: json['size'] as int,
        checksum: json['checksum'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
        uploadedAt: json['uploadedAt'] == null
            ? null
            : DateTime.parse(json['uploadedAt'] as String),
        verifiedAt: json['verifiedAt'] == null
            ? null
            : DateTime.parse(json['verifiedAt'] as String),
        expiresAt: json['expiresAt'] == null
            ? null
            : DateTime.parse(json['expiresAt'] as String),
        stage: json['stage'] as String?,
        confidence: (json['confidence'] as num?)?.toDouble(),
        issues: (json['issues'] as List?)?.cast<String>() ?? const [],
        rejectionReason: json['rejectionReason'] as String?,
        audit: ((json['audit'] as List?) ?? const [])
            .cast<Map<String, dynamic>>()
            .map(AuditEntry.fromJson)
            .toList(),
      );
}

/// Connection state surfaced to the UI for the "we're offline" banner.
enum DocumentConnectionState { connected, reconnecting, offline }
