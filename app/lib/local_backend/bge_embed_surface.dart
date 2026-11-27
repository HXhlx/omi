import 'dart:convert' show LineSplitter, utf8;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:onnxruntime_v2/onnxruntime_v2.dart';

import 'package:flutter_backend/embedded.dart';

import 'package:omi/local_backend/on_device_models.dart';

/// `local-embed` card, served by bge-base-zh int8 through onnxruntime_v2
/// (the same runtime the VAD engine uses). WordPiece tokenizes, runs the BERT
/// encoder, mean-pools the last hidden state, L2-normalizes — the standard
/// bge sentence-embedding contract. ~10ms per sentence on an SD865.
class BgeEmbedSurface implements EmbedSurface {
  BgeEmbedSurface({this.maxSequenceLength = 128});

  /// BERT cap; bge's training context is 512 but memories are short.
  final int maxSequenceLength;

  OrtSession? _session;
  OrtSessionOptions? _options;
  Map<String, int> _vocab = const {};
  static const _dim = 768;

  Future<void> _ensureLoaded() async {
    if (_session != null) return;
    if (!await isOnDeviceModelDownloaded('local-embed')) {
      throw StateError('embed model not downloaded (请在供应商卡片里下载嵌入模型)');
    }
    final modelBytes = await readOnDeviceModelFile('local-embed', 'embed/bge-base-zh/model_int8.onnx');
    final vocabText = utf8.decode(await readOnDeviceModelFile('local-embed', 'embed/bge-base-zh/vocab.txt'));
    _vocab = _parseVocab(vocabText);
    final options = OrtSessionOptions()
      ..setIntraOpNumThreads(2)
      ..setInterOpNumThreads(1);
    _session = OrtSession.fromBuffer(modelBytes, options);
    _options = options;
  }

  /// Token ids for [text]: CLS + tokens + SEP. BERT Chinese convention — CJK
  /// characters tokenize one-per-token (the vocab carries single chars);
  /// Latin runs split on whitespace and go through greedy longest-prefix
  /// WordPiece with `##` continuations.
  List<int> _tokenize(String text) {
    final tokens = <int>[101]; // [CLS]
    final runes = text.runes.toList();
    var latin = StringBuffer();
    void flushLatin() {
      final word = latin.toString().toLowerCase();
      latin = StringBuffer();
      if (word.isEmpty) return;
      final direct = _vocab[word];
      if (direct != null) {
        tokens.add(direct);
        return;
      }
      var start = 0;
      while (start < word.length && tokens.length < maxSequenceLength - 1) {
        var end = word.length;
        int? id;
        while (end > start) {
          final candidate = start == 0 ? word.substring(start, end) : '##${word.substring(start, end)}';
          id = _vocab[candidate];
          if (id != null) break;
          end--;
        }
        if (id == null) {
          tokens.add(100); // [UNK]
          return;
        }
        tokens.add(id);
        start = end;
      }
    }

    for (final rune in runes) {
      if (tokens.length >= maxSequenceLength - 1) break;
      final c = String.fromCharCode(rune);
      if (RegExp(r'[一-鿿㐀-䶿豈-﫿　-〿＀-￯]').hasMatch(c)) {
        flushLatin();
        // CJK or CJK punctuation: single-char token, falling back to [UNK]
        // only for punctuation outside the vocab.
        tokens.add(_vocab[c] ?? 100);
      } else if (c.trim().isEmpty) {
        flushLatin();
      } else {
        latin.write(c);
      }
    }
    flushLatin();
    tokens.add(102); // [SEP]
    if (tokens.length > maxSequenceLength) {
      return tokens.sublist(0, maxSequenceLength - 1)..add(102);
    }
    return tokens;
  }

  @override
  Future<List<List<double>>> embed(List<String> texts) async {
    if (texts.isEmpty) return const [];
    await _ensureLoaded();
    return [for (final text in texts) await _embedOne(text)];
  }

  Future<List<double>> _embedOne(String text) async {
    final ids = _tokenize(text);
    final seq = ids.length;
    final input = OrtValueTensor.createTensorWithDataList(Int64List.fromList(ids), [1, seq]);
    final mask =
        OrtValueTensor.createTensorWithDataList(Int64List.fromList(List<int>.filled(seq, 1)), [1, seq]);
    final types =
        OrtValueTensor.createTensorWithDataList(Int64List.fromList(List<int>.filled(seq, 0)), [1, seq]);
    final runOptions = OrtRunOptions();
    List<OrtValue?>? outputs;
    try {
      outputs = await _session!.runAsync(runOptions, {
        'input_ids': input,
        'attention_mask': mask,
        'token_type_ids': types,
      });
      if (outputs == null || outputs.isEmpty) {
        throw StateError('bge encoder returned no output');
      }
      // [1, seq, dim] nested list → mean pool over seq.
      final layers = (outputs[0]!.value as List)[0] as List;
      final sum = List<double>.filled(_dim, 0);
      for (final row in layers) {
        final values = row as List;
        for (var i = 0; i < _dim && i < values.length; i++) {
          sum[i] += (values[i] as num).toDouble();
        }
      }
      final mean = [for (final x in sum) x / layers.length];
      // L2 normalize — bge vectors are unit length.
      var norm = 0.0;
      for (final x in mean) {
        norm += x * x;
      }
      if (norm <= 0) throw StateError('bge produced a zero vector');
      final inv = 1.0 / math.sqrt(norm);
      return [for (final x in mean) x * inv];
    } finally {
      for (final o in outputs ?? <OrtValue?>[]) {
        o?.release();
      }
      input.release();
      mask.release();
      types.release();
      runOptions.release();
    }
  }

  /// `vocab.txt`: one token per line, line number = id.
  static Map<String, int> _parseVocab(String text) {
    final vocab = <String, int>{};
    var id = 0;
    for (final line in const LineSplitter().convert(text)) {
      if (line.isNotEmpty) vocab[line] = id;
      id++;
    }
    return vocab;
  }

  Future<void> close() async {
    await _session?.release();
    _options?.release();
    _session = null;
  }
}
