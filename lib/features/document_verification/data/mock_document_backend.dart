import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'package:untitled2/core/id.dart';
import 'package:untitled2/features/document_verification/domain/entities/document.dart';

// ===== Wire-format DTOs (the shapes the API spec defines) ====================

@immutable
class UploadResponse {
  const UploadResponse({
    required this.id,
    required this.status,
    required this.uploadedAt,
    required this.estimatedProcessingTimeSeconds,
  });

  final String id;
  final String status; // "UPLOADED"
  final DateTime uploadedAt;
  final int estimatedProcessingTimeSeconds;
}

@immutable
class StatusResponse {
  const StatusResponse({
    required this.id,
    required this.status,
    required this.progress,
    this.verifiedAt,
    this.rejectionReason,
    this.expiresAt,
  });

  final String id;
  final String status; // PENDING|PROCESSING|VERIFIED|REJECTED
  final double progress;
  final DateTime? verifiedAt;
  final String? rejectionReason;
  final DateTime? expiresAt;
}

@immutable
class WsStatusUpdate {
  const WsStatusUpdate({
    required this.documentId,
    required this.status,
    required this.progress,
    required this.stage,
    required this.confidence,
    required this.issues,
  });

  final String documentId;
  final String status; // PROCESSING|VERIFIED|REJECTED
  final double progress;
  final String stage;
  final double confidence;
  final List<String> issues;
}

// ===== Backend simulator =====================================================

/// A single in-process simulator for the document service. The HTTP client,
/// the WebSocket client, and the polling service all read from this one
/// instance so they stay consistent with each other (mirroring how a real
/// backend would).
///
/// Documents progress through stages on a Timer:
///   0.00 → 0.30  "Optical character recognition"        (UPLOADED → PROCESSING)
///   0.30 → 0.70  "Identity field extraction"
///   0.70 → 1.00  "Authenticity verification"            (→ VERIFIED | REJECTED)
class MockDocumentBackend {
  MockDocumentBackend({
    Random? rng,
    Duration uploadLatency = const Duration(milliseconds: 900),
    Duration pollLatency = const Duration(milliseconds: 250),
    double rejectionRate = 0.25,
    Duration stageDuration = const Duration(seconds: 4),
  })  : _rng = rng ?? Random(),
        _uploadLatency = uploadLatency,
        _pollLatency = pollLatency,
        _rejectionRate = rejectionRate,
        _stageDuration = stageDuration;

  final Random _rng;
  final Duration _uploadLatency;
  final Duration _pollLatency;
  final double _rejectionRate;
  final Duration _stageDuration;

  final Map<String, _ServerDoc> _docs = {};
  final StreamController<WsStatusUpdate> _updates =
      StreamController<WsStatusUpdate>.broadcast();
  final List<Timer> _activeTimers = [];

  /// All status updates ever pushed by the simulated server. The WS client
  /// subscribes here when it is "connected".
  Stream<WsStatusUpdate> get updates => _updates.stream;

  /// Hook the WS client uses to ask "what did I miss while disconnected?".
  /// Returns the latest known status for each tracked id.
  List<WsStatusUpdate> snapshot(Iterable<String> ids) {
    return [
      for (final id in ids)
        if (_docs[id] != null) _docs[id]!.lastUpdate,
    ];
  }

  // ----- HTTP-shaped methods (called by the API client) ----------------------

  Future<UploadResponse> upload({
    required DocumentType type,
    required String originalName,
    required int size,
    required String checksum,
  }) async {
    await Future.delayed(_uploadLatency);
    final id = IdGen.next('srv_doc');
    final now = DateTime.now();
    final est = 8 + _rng.nextInt(12); // 8..20s total processing window
    final doc = _ServerDoc(
      id: id,
      type: type,
      uploadedAt: now,
      estimatedSeconds: est,
    );
    _docs[id] = doc;
    _scheduleProgression(doc);
    return UploadResponse(
      id: id,
      status: 'UPLOADED',
      uploadedAt: now,
      estimatedProcessingTimeSeconds: est,
    );
  }

  Future<StatusResponse> status(String serverId) async {
    await Future.delayed(_pollLatency);
    final doc = _docs[serverId];
    if (doc == null) {
      throw StateError('Unknown document id: $serverId');
    }
    return StatusResponse(
      id: serverId,
      status: doc.lastUpdate.status,
      progress: doc.lastUpdate.progress,
      verifiedAt: doc.verifiedAt,
      rejectionReason: doc.rejectionReason,
      expiresAt: doc.expiresAt,
    );
  }

  // ----- Progression engine --------------------------------------------------

  void _scheduleProgression(_ServerDoc doc) {
    final stages = <_Stage>[
      _Stage(name: 'Optical character recognition', target: 0.30),
      _Stage(name: 'Identity field extraction', target: 0.70),
      _Stage(name: 'Authenticity verification', target: 1.00),
    ];

    void runStage(int stageIdx) {
      if (stageIdx >= stages.length) {
        _finalize(doc);
        return;
      }
      final stage = stages[stageIdx];
      // Push intermediate updates every ~600ms within a stage so the UI
      // animates smoothly.
      const step = Duration(milliseconds: 600);
      final ticks = (_stageDuration.inMilliseconds / step.inMilliseconds)
          .ceil()
          .clamp(1, 999);
      final start = stageIdx == 0 ? 0.0 : stages[stageIdx - 1].target;
      var tick = 0;

      late Timer t;
      t = Timer.periodic(step, (_) {
        if (_disposed) {
          t.cancel();
          return;
        }
        tick++;
        final progress =
            start + (stage.target - start) * (tick / ticks).clamp(0, 1);
        final update = WsStatusUpdate(
          documentId: doc.id,
          status: 'PROCESSING',
          progress: progress,
          stage: stage.name,
          confidence: 0.6 + _rng.nextDouble() * 0.3,
          issues: const [],
        );
        doc.lastUpdate = update;
        _updates.add(update);
        if (tick >= ticks) {
          t.cancel();
          _activeTimers.remove(t);
          runStage(stageIdx + 1);
        }
      });
      _activeTimers.add(t);
    }

    runStage(0);
  }

  void _finalize(_ServerDoc doc) {
    final reject = _rng.nextDouble() < _rejectionRate;
    final now = DateTime.now();
    if (reject) {
      final reason = _rejectionReasons[_rng.nextInt(_rejectionReasons.length)];
      doc.rejectionReason = reason;
      doc.lastUpdate = WsStatusUpdate(
        documentId: doc.id,
        status: 'REJECTED',
        progress: 1.0,
        stage: 'Authenticity verification',
        confidence: 0.4 + _rng.nextDouble() * 0.2,
        issues: [reason],
      );
    } else {
      doc.verifiedAt = now;
      doc.expiresAt = now.add(const Duration(days: 365));
      doc.lastUpdate = WsStatusUpdate(
        documentId: doc.id,
        status: 'VERIFIED',
        progress: 1.0,
        stage: 'Authenticity verification',
        confidence: 0.9 + _rng.nextDouble() * 0.09,
        issues: const [],
      );
    }
    _updates.add(doc.lastUpdate);
  }

  static const _rejectionReasons = [
    'Image too blurry to read key fields',
    'Glare obscures the photograph',
    'Document appears expired',
    'Photo-of-photo detected — please capture the original',
    'Selected document type does not match contents',
  ];

  bool _disposed = false;

  Future<void> dispose() async {
    _disposed = true;
    for (final t in _activeTimers) {
      t.cancel();
    }
    _activeTimers.clear();
    await _updates.close();
  }
}

class _ServerDoc {
  _ServerDoc({
    required this.id,
    required this.type,
    required this.uploadedAt,
    required this.estimatedSeconds,
  })  : lastUpdate = WsStatusUpdate(
          documentId: id,
          status: 'PROCESSING',
          progress: 0.0,
          stage: 'Queued',
          confidence: 0.0,
          issues: const [],
        );

  final String id;
  final DocumentType type;
  final DateTime uploadedAt;
  final int estimatedSeconds;
  WsStatusUpdate lastUpdate;
  DateTime? verifiedAt;
  DateTime? expiresAt;
  String? rejectionReason;
}

class _Stage {
  _Stage({required this.name, required this.target});
  final String name;
  final double target;
}
