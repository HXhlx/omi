/// Conversation wire model — mirrors Omi `Conversation` from
/// `docs/api-reference/app-client-openapi.json`.
library;

class TranscriptSegment {
  TranscriptSegment({
    required this.text,
    required this.isUser,
    required this.start,
    required this.end,
    this.speaker = 'SPEAKER_00',
    this.speakerId,
    this.personId,
  });

  factory TranscriptSegment.fromJson(Map<String, dynamic> j) => TranscriptSegment(
        text: j['text'] as String,
        isUser: j['is_user'] as bool,
        start: (j['start'] as num).toDouble(),
        end: (j['end'] as num).toDouble(),
        speaker: j['speaker'] as String? ?? 'SPEAKER_00',
        speakerId: j['speaker_id'] as int?,
        personId: j['person_id'] as String?,
      );

  final String text;
  final bool isUser;
  final double start;
  final double end;
  final String speaker;
  final int? speakerId;
  final String? personId;

  Map<String, dynamic> toJson() => {
        'text': text,
        'is_user': isUser,
        'start': start,
        'end': end,
        'speaker': speaker,
        if (speakerId != null) 'speaker_id': speakerId,
        if (personId != null) 'person_id': personId,
      };
}

/// Minimal structural projection of the Omi Conversation. Fields kept are the
/// subset the desktop + mobile clients actually read on list/get; the full
/// upstream schema carries ~80 fields (app_results, audio_files, capture_…)
/// that a local build supplies as defaults.
class Conversation {
  Conversation({
    required this.id,
    required this.startedAt,
    this.finishedAt,
    this.status = 'processing',
    this.source = 'desktop',
    this.language = 'zh',
    this.title,
    this.visibility = 'private',
    this.transcript,
    this.discarded = false,
  });

  factory Conversation.fromJson(Map<String, dynamic> j) => Conversation(
        id: j['id'] as String,
        startedAt: DateTime.parse(j['started_at'] as String),
        finishedAt: j['finished_at'] == null
            ? null
            : DateTime.parse(j['finished_at'] as String),
        status: j['status'] as String? ?? 'processing',
        source: j['source'] as String? ?? 'desktop',
        language: j['language'] as String? ?? 'zh',
        title: j['title'] as String?,
        visibility: j['visibility'] as String? ?? 'private',
        transcript: (j['transcript'] as List?)
            ?.map((e) => TranscriptSegment.fromJson(e as Map<String, dynamic>))
            .toList(),
        discarded: j['discarded'] as bool? ?? false,
      );

  final String id;
  final DateTime startedAt;
  final DateTime? finishedAt;
  final String status;
  final String source;
  final String language;
  final String? title;
  final String visibility;
  final List<TranscriptSegment>? transcript;
  final bool discarded;

  Map<String, dynamic> toJson() => {
        'id': id,
        'started_at': startedAt.toIso8601String(),
        if (finishedAt != null) 'finished_at': finishedAt!.toIso8601String(),
        'status': status,
        'source': source,
        'language': language,
        if (title != null) 'title': title,
        'visibility': visibility,
        if (transcript != null)
          'transcript': transcript!.map((s) => s.toJson()).toList(),
        'discarded': discarded,
        // Local-build defaults that client UI reads and tolerates missing.
        'apps_results': <Object>[],
        'audio_files': <Object>[],
        'recording': false,
      };
}