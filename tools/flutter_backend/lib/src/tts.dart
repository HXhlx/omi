/// TTS catalog + voice preference. Inference is delegated to an adjacent local
/// worker (the harness runs speaches piper on `http://127.0.0.1:8300`); this
/// module owns the wire contract and the user's stored voice preference only.
library;

/// Voices the local piper/speaches worker exposes. ids match the wire contract
/// `TtsVoice {id, name}`; the default is what the Omi backend returns for zh.
const kTtsVoices = <Map<String, String>>[
  {'id': 'speaches-ai/piper-zh_CN-huayan-medium', 'name': '小蜗-普通话女声'},
  {'id': 'speaches-ai/piper-zh_CN-huayan-medium-low', 'name': '小蜗-普通话女声(低)'},
  {'id': 'edge-zh-CN-XiaoxiaoNeural', 'name': '晓晓'},
  {'id': 'edge-zh-CN-YunxiNeural', 'name': '云希'},
];

const kDefaultAssistantVoice = 'speaches-ai/piper-zh_CN-huayan-medium';

const kDefaultTtsUpstream = 'http://127.0.0.1:8300';

/// Mimics the upstream `TtsSynthesizeRequest` shape the client posts:
/// `{text, model_id?, voice_id?, output_format?, voice_settings?}`.
class TtsRequest {
  TtsRequest(this.text, {this.voiceId, this.outputFormat});

  factory TtsRequest.fromJson(Map<String, dynamic> j) => TtsRequest(
        j['text'] as String,
        voiceId: j['voice_id'] as String?,
        outputFormat: j['output_format'] as String?,
      );

  final String text;
  final String? voiceId;
  final String? outputFormat;

  Map<String, dynamic> toJson() => {
        'text': text,
        'voice_id': voiceId ?? kDefaultAssistantVoice,
        'output_format': outputFormat ?? 'mp3_44100_128',
      };
}