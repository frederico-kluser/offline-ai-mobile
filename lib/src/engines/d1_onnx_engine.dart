/// Motor do decisor d1 sobre ONNX Runtime (`onnxruntime_v2`).
///
/// Arquitetura:
///  - a sessão ONNX (decoder + encoders opcionais) vive num isolate próprio;
///  - `decide()` constrói uma linha sem padding, com até 16 perguntas,
///    `question_ids`/`slot_positions` e corre UM forward pass sem KV cache;
///  - os logits/hidden states voltam ao isolate principal e são descodificados
///    por [D1OutputDecoder].
///
/// O bundle ONNX oficial (`d1-2B-ONNX` / `d1-Omni-2B-ONNX`) é obrigatório
/// para as primitivas tipadas; a via GGUF só cobre noul/choice/score.
library;

import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:onnxruntime_v2/onnxruntime_v2.dart';
// ignore: implementation_imports
import 'package:onnxruntime_v2/src/bindings/onnxruntime_bindings_generated.dart'
    as bg;

import '../domain/d1_decision_types.dart';
import '../domain/llm_config.dart';
import '../services/media_preprocessor.dart';
import 'd1_audio.dart';
import 'd1_engine.dart';
import 'd1_output.dart';
import 'd1_prompt.dart';
import 'd1_tokenizer.dart';
import 'd1_vision.dart';

class D1OnnxEngine implements D1Engine {
  Isolate? _isolate;
  SendPort? _commands;
  bool _ready = false;
  String? _loadError;
  String? _modelPath;
  D1ModelPaths? _paths;
  int _nextId = 0;
  final Map<int, Completer<Object?>> _inflight = {};

  @override
  bool get isLoaded => _ready;

  @override
  String get modelId {
    final p = _modelPath;
    if (p == null) return 'd1-onnx';
    final i = math.max(p.lastIndexOf('/'), p.lastIndexOf('\\'));
    return i >= 0 ? p.substring(i + 1) : p;
  }

  @override
  D1BackendKind get backend => D1BackendKind.onnx;

  @override
  D1Capabilities get capabilities => D1Capabilities(
        types: D1Capabilities.onnxVisionText.types,
        vision: _paths?.visionEncoderPath != null,
        video: _paths?.visionEncoderPath != null,
        audio: _paths?.audioEncoderPath != null,
      );

  @override
  String? get loadError => _loadError;

  @override
  Future<void> load({
    required D1ModelPaths paths,
    required D1Config config,
  }) async {
    if (_isolate != null) await unload();
    _ready = false;
    _loadError = null;
    _modelPath = paths.decoderPath;
    _paths = paths;

    final handshake = ReceivePort();
    final isolate = await Isolate.spawn(
      _d1WorkerMain,
      handshake.sendPort,
      debugName: 'D1OnnxEngine',
    );
    _isolate = isolate;
    final commands = await handshake.first as SendPort;
    handshake.close();
    _commands = commands;

    final reply = ReceivePort();
    final ack = await _request(
      reply,
      commands,
      _LoadCmd(paths: paths, config: config, reply: reply.sendPort),
    );
    reply.close();
    if (ack is _Ok) {
      _ready = true;
    } else {
      _loadError = (ack as _Err).message;
      _ready = false;
    }
  }

  @override
  Future<D1Response> decide(D1Request request) async {
    final commands = _commands;
    if (!_ready || commands == null) {
      throw D1Unavailable(
        'D1OnnxEngine: motor não carregado. ${_loadError ?? 'Chame load() primeiro.'}',
      );
    }
    final prepared = <Map<String, Object?>>[];
    for (final m in request.media) {
      switch (m.kind) {
        case D1MediaKind.image:
          final img = await const MediaPreprocessor().prepareImage(m.path);
          prepared.add({
            'kind': 'image',
            'width': img.width,
            'height': img.height,
            'rgb': img.rgb,
          });
        case D1MediaKind.audio:
          if (_paths?.audioEncoderPath == null) {
            throw const D1Unavailable(
              'este bundle d1 não tem audio_encoder; usa d1-Omni-2B-ONNX '
              'para áudio.',
            );
          }
          final audio = await const MediaPreprocessor().prepareAudio(m.path);
          prepared.add({
            'kind': 'audio',
            'samples': audio.samples,
            'sample_rate': audio.sampleRate,
          });
        case D1MediaKind.video:
          final video = await const MediaPreprocessor().prepareVideo(m.path);
          if (video.frames.isEmpty) {
            throw const D1Unavailable('vídeo sem frames extraídos');
          }
          prepared.add({
            'kind': 'video',
            'frames': [
              for (final f in video.frames)
                {
                  'width': f.width,
                  'height': f.height,
                  'rgb': f.rgb,
                }
            ],
            'soundtrack': video.soundtrack?.toMap(),
          });
      }
    }
    final reply = ReceivePort();
    final result = await _request(
      reply,
      commands,
      _DecideCmd(
        request: request,
        media: prepared,
        reply: reply.sendPort,
      ),
    );
    reply.close();
    if (result is _Err) {
      throw StateError('D1OnnxEngine: ${result.message}');
    }
    return (result as _Ok).payload as D1Response;
  }

  @override
  Future<void> unload() async {
    final commands = _commands;
    final isolate = _isolate;
    _commands = null;
    _isolate = null;
    _ready = false;
    _modelPath = null;
    if (commands != null && isolate != null) {
      try {
        final reply = ReceivePort();
        await _request(reply, commands, _UnloadCmd(reply: reply.sendPort))
            .timeout(const Duration(seconds: 15));
        reply.close();
      } catch (_) {
        // worker já morto
      }
    }
    for (final c in _inflight.values) {
      if (!c.isCompleted) c.complete(const _Err('D1OnnxEngine: unload()'));
    }
    _inflight.clear();
    isolate?.kill(priority: Isolate.immediate);
    _loadError = null;
  }

  Future<Object?> _request(ReceivePort port, SendPort to, _Cmd cmd) {
    final id = _nextId++;
    final completer = Completer<Object?>();
    _inflight[id] = completer;
    port.listen((message) {
      final entry = (message as Map)['id'] as int;
      final c = _inflight.remove(entry);
      if (c != null && !c.isCompleted) c.complete(message['result']);
    });
    to.send(_Envelope(id, cmd));
    return completer.future;
  }
}

// ---------------------------------------------------------------------------
// Protocolo do worker.
// ---------------------------------------------------------------------------

class _Envelope {
  final int id;
  final _Cmd cmd;
  const _Envelope(this.id, this.cmd);
}

sealed class _Cmd {
  const _Cmd();
  SendPort get reply;
}

class _LoadCmd extends _Cmd {
  final D1ModelPaths paths;
  final D1Config config;
  @override
  final SendPort reply;
  const _LoadCmd({
    required this.paths,
    required this.config,
    required this.reply,
  });
}

class _DecideCmd extends _Cmd {
  final D1Request request;
  final List<Map<String, Object?>> media;
  @override
  final SendPort reply;
  const _DecideCmd({
    required this.request,
    required this.media,
    required this.reply,
  });
}

class _UnloadCmd extends _Cmd {
  @override
  final SendPort reply;
  const _UnloadCmd({required this.reply});
}

class _Ok {
  final Object? payload;
  const _Ok([this.payload]);
}

class _Err {
  final String message;
  const _Err(this.message);
}

// ---------------------------------------------------------------------------
// Worker.
// ---------------------------------------------------------------------------

Future<void> _d1WorkerMain(SendPort handshake) async {
  final commands = ReceivePort();
  handshake.send(commands.sendPort);

  D1Tokenizer? tokenizer;
  OrtSession? decoder;
  OrtSession? vision;
  OrtSession? audio;
  D1Config config = const D1Config();
  var loadError = 'motor não carregado';
  const outputDecoder = D1OutputDecoder();

  await for (final raw in commands) {
    final envelope = raw as _Envelope;
    final id = envelope.id;
    final cmd = envelope.cmd;
    Object result;
    try {
      if (cmd is _LoadCmd) {
        config = cmd.config;
        result = _workerLoad(cmd, (t, d, v, a) {
          tokenizer = t;
          decoder = d;
          vision = v;
          audio = a;
        });
        loadError = result is _Err ? result.message : '';
      } else if (cmd is _DecideCmd) {
        final tok = tokenizer;
        final dec = decoder;
        if (tok == null || dec == null) {
          result = _Err('modelo d1 não carregou: $loadError');
        } else {
          result = _workerDecide(
            request: cmd.request,
            tokenizer: tok,
            decoder: dec,
            vision: vision,
            audio: audio,
            media: cmd.media,
            config: config,
            outputDecoder: outputDecoder,
          );
        }
      } else if (cmd is _UnloadCmd) {
        await decoder?.release();
        await vision?.release();
        await audio?.release();
        _reply(id, cmd.reply, const _Ok());
        commands.close();
        Isolate.exit();
      } else {
        result = _Err('comando desconhecido: $cmd');
      }
    } catch (e, st) {
      result = _Err('$e\n${st.toString().split('\n').take(4).join('\n')}');
    }
    _reply(id, cmd.reply, result);
  }
}

void _reply(int id, SendPort reply, Object? result) {
  reply.send({'id': id, 'result': result});
}

Object _workerLoad(
  _LoadCmd cmd,
  void Function(D1Tokenizer, OrtSession, OrtSession?, OrtSession?) onReady,
) {
  try {
    OrtEnv.instance.init(level: OrtLoggingLevel.warning, logId: 'd1');
  } catch (e) {
    return _Err('ONNX Runtime (OrtEnv.init) falhou: $e');
  }
  try {
    final p = cmd.paths;
    if (p.decoderPath == null || !File(p.decoderPath!).existsSync()) {
      return _Err('decoder ONNX não encontrado: ${p.decoderPath}');
    }
    if (!File(p.tokenizerPath).existsSync()) {
      return _Err('tokenizer não encontrado: ${p.tokenizerPath}');
    }
    final tokenizer = D1Tokenizer.fromFile(p.tokenizerPath);
    final decoder = _session(p.decoderPath!, cmd.config);
    final vision = p.visionEncoderPath != null &&
            File(p.visionEncoderPath!).existsSync()
        ? _session(p.visionEncoderPath!, cmd.config)
        : null;
    final audio = p.audioEncoderPath != null &&
            File(p.audioEncoderPath!).existsSync()
        ? _session(p.audioEncoderPath!, cmd.config)
        : null;
    onReady(tokenizer, decoder, vision, audio);
    return const _Ok();
  } catch (e) {
    return _Err('modelo d1 ONNX não carregou: $e');
  }
}

OrtSession _session(String path, D1Config config) {
  final options = OrtSessionOptions()
    ..setIntraOpNumThreads(config.threads)
    ..setInterOpNumThreads(1)
    ..setSessionGraphOptimizationLevel(GraphOptimizationLevel.ortEnableAll);
  try {
    switch (config.executionProvider) {
      case 'xnnpack':
        options.appendXnnpackProvider();
      case 'coreml':
        options.appendCoreMLProvider(CoreMLFlags.useNone);
      default:
        options.appendCPUProvider(CPUFlags.useArena);
    }
  } catch (_) {
    options.appendCPUProvider(CPUFlags.useArena);
  }
  final session = OrtSession.fromFile(File(path), options);
  options.release();
  return session;
}

Object _workerDecide({
  required D1Request request,
  required D1Tokenizer tokenizer,
  required OrtSession decoder,
  required OrtSession? vision,
  required OrtSession? audio,
  required List<Map<String, Object?>> media,
  required D1Config config,
  required D1OutputDecoder outputDecoder,
}) {
  final started = DateTime.now();
  final questions = request.questions.take(config.maxQuestions).toList();
  if (questions.isEmpty) {
    return _Err('pedido d1 sem perguntas');
  }
  final answers = <String, D1Answer>{};
  var inputTokens = 0;
  var slotCount = 0;

  // ---- features visuais/áudio (uma vez por pedido) ---------------------
  var imageFeatures = <double>[];
  var imageTokens = 0;
  var audioFeatures = <double>[];
  var audioTokens = 0;
  var videoFeatures = <double>[];
  var videoTokens = 0;
  final mediaTokenCounts = <int>[];
  for (final m in media) {
    if (m['kind'] == 'image') {
      if (vision == null) {
        return _Err('bundle d1 sem vision_encoder; não é possível usar imagem');
      }
      final tensor = buildD1PixelValues(PreparedImage(
        width: m['width']! as int,
        height: m['height']! as int,
        rgb: m['rgb']! as Uint8List,
      ));
      final out = _runVision(vision, tensor);
      if (out is _Err) return out;
      final part = (out as _Ok).payload as List<double>;
      if (part.length % 2048 != 0) {
        return _Err('vision_encoder devolveu ${part.length} valores; '
            'não é múltiplo de 2048');
      }
      mediaTokenCounts.add(part.length ~/ 2048);
      imageFeatures.addAll(part);
    } else if (m['kind'] == 'audio') {
      if (audio == null) {
        return _Err('bundle d1 sem audio_encoder; não é possível usar áudio');
      }
      final tensor = buildD1LogMel(PreparedAudio(
        samples: m['samples']! as Float32List,
        sampleRate: m['sample_rate']! as int,
      ));
      final out = _runAudio(audio, tensor);
      if (out is _Err) return out;
      final part = (out as _Ok).payload as List<double>;
      if (part.length % 2048 != 0) {
        return _Err('audio_encoder devolveu ${part.length} valores; '
            'não é múltiplo de 2048');
      }
      mediaTokenCounts.add(part.length ~/ 2048);
      audioFeatures.addAll(part);
    } else if (m['kind'] == 'video') {
      if (vision == null) {
        return _Err('bundle d1 sem vision_encoder; não é possível usar vídeo');
      }
      final frames = (m['frames']! as List).cast<Map>();
      if (frames.isEmpty) return _Err('vídeo d1 sem frames');
      var count = 0;
      for (var i = 0; i < frames.length; i += 2) {
        PreparedImage frame(int j) {
          final f = frames[j];
          return PreparedImage(
            width: f['width']! as int,
            height: f['height']! as int,
            rgb: f['rgb']! as Uint8List,
          );
        }

        final a = frame(i);
        final b = frame(i + 1 < frames.length ? i + 1 : i);
        final out = _runVision(vision, buildD1VideoValues(a, b));
        if (out is _Err) return out;
        final part = (out as _Ok).payload as List<double>;
        if (part.length % 2048 != 0) {
          return _Err('vision_encoder (vídeo) devolveu ${part.length} '
              'valores; não é múltiplo de 2048');
        }
        count += part.length ~/ 2048;
        videoFeatures.addAll(part);
      }
      mediaTokenCounts.add(count);
    } else {
      return _Err('tipo de mídia d1 desconhecido: ${m['kind']}');
    }
  }
  if (imageFeatures.length % 2048 != 0) {
    return _Err('vision_encoder devolveu ${imageFeatures.length} valores; '
        'não é múltiplo de 2048');
  }
  imageTokens = imageFeatures.length ~/ 2048;
  if (audioFeatures.length % 2048 != 0) {
    return _Err('audio_encoder devolveu ${audioFeatures.length} valores; '
        'não é múltiplo de 2048');
  }
  audioTokens = audioFeatures.length ~/ 2048;
  if (videoFeatures.length % 2048 != 0) {
    return _Err('vision_encoder (vídeo) devolveu ${videoFeatures.length} '
        'valores; não é múltiplo de 2048');
  }
  videoTokens = videoFeatures.length ~/ 2048;

  for (var i = 0; i < questions.length; i++) {
    final prompt = D1PromptBuilder(
      tokenizer: tokenizer,
      maxStateTokens: config.maxStateTokens,
      maxQuestions: config.maxQuestions,
      mediaTokenCounts: mediaTokenCounts,
    ).build(request, questionIndex: i);
    if (prompt.inputIds.length > config.maxStateTokens) {
      return _Err(
        'prompt d1 (pergunta ${i + 1}) tem ${prompt.inputIds.length} tokens; '
        'limite ${config.maxStateTokens} (aumenta max_state_tokens)',
      );
    }
    final one = _runOne(
      question: questions[i],
      prompt: prompt,
      decoder: decoder,
      tokenizer: tokenizer,
      outputDecoder: outputDecoder,
      imageFeatures: imageFeatures,
      imageTokens: imageTokens,
      audioFeatures: audioFeatures,
      audioTokens: audioTokens,
      videoFeatures: videoFeatures,
      videoTokens: videoTokens,
    );
    if (one is _Err) return one;
    answers[questions[i].id] = (one as _Ok).payload as D1Answer;
    inputTokens += prompt.inputIds.length;
    slotCount += prompt.slots.length;
  }

  return _Ok(D1Response(
    answers: answers,
    inputTokens: inputTokens,
    latencyMs: DateTime.now().difference(started).inMilliseconds,
    slotCount: slotCount,
    engine: 'd1-onnx',
  ));
}

Object _runOne({
  required D1Question question,
  required D1Prompt prompt,
  required OrtSession decoder,
  required D1Tokenizer tokenizer,
  required D1OutputDecoder outputDecoder,
  List<double> imageFeatures = const [],
  int imageTokens = 0,
  List<double> audioFeatures = const [],
  int audioTokens = 0,
  List<double> videoFeatures = const [],
  int videoTokens = 0,
}) {
  final n = prompt.inputIds.length;
  final inputs = <String, OrtValue>{};
  final available = decoder.inputNames.toSet();

  void addInt(String name, List<int> values, List<int> shape) {
    if (!available.contains(name)) return;
    inputs[name] = OrtValueTensor.createTensorWithDataList(values, shape);
  }

  addInt('input_ids', prompt.inputIds, [1, n]);
  addInt('attention_mask', List<int>.filled(n, 1), [1, n]);
  addInt('position_ids', List<int>.generate(n, (i) => i), [1, n]);
  addInt('question_ids', prompt.questionIds, [1, n]);
  addInt('slot_positions', prompt.slotPositions, [prompt.slotPositions.length]);
  // O decoder oficial declara sempre estes inputs (mesmo sem mídia); o grafo
  // exige o tensor e o ORT não aceita shape [0,2048], por isso usa-se uma
  // linha zero quando não há features (o modelo ignora-a sem marcador).
  if (available.contains('image_features')) {
    inputs['image_features'] = imageFeatures.isEmpty
        ? _emptyFloatTensor(const [0, 2048])
        : OrtValueTensor.createTensorWithDataList(
            Float32List.fromList(imageFeatures),
            [imageTokens, 2048],
          );
  }
  if (available.contains('audio_features')) {
    inputs['audio_features'] = audioFeatures.isEmpty
        ? _emptyFloatTensor(const [0, 2048])
        : OrtValueTensor.createTensorWithDataList(
            Float32List.fromList(audioFeatures),
            [audioTokens, 2048],
          );
  }
  if (available.contains('video_features')) {
    inputs['video_features'] = videoFeatures.isEmpty
        ? _emptyFloatTensor(const [0, 2048])
        : OrtValueTensor.createTensorWithDataList(
            Float32List.fromList(videoFeatures),
            [videoTokens, 2048],
          );
  }

  if (!available.contains('input_ids') ||
      !available.contains('attention_mask') ||
      !available.contains('slot_positions')) {
    for (final v in inputs.values) {
      v.release();
    }
    return _Err('decoder d1 não expõe os inputs obrigatórios: '
        '${decoder.inputNames.join(', ')}');
  }

  final outputNames = <String>[
    if (decoder.outputNames.contains('logits'))
      'logits'
    else
      decoder.outputNames.first,
    if (decoder.outputNames.contains('hidden_states'))
      'hidden_states'
    else if (decoder.outputNames.length > 1)
      decoder.outputNames[1],
  ];

  final runOptions = OrtRunOptions();
  List<OrtValue?>? outputs;
  try {
    outputs = decoder.run(runOptions, inputs, outputNames);
    final logits = _flattenDoubles((outputs[0] as OrtValueTensor).value);
    final logitsShape = _shapeOf((outputs[0] as OrtValueTensor).value);
    List<double>? hidden;
    List<int>? hiddenShape;
    if (outputs.length > 1 && outputs[1] is OrtValueTensor) {
      hidden = _flattenDoubles((outputs[1] as OrtValueTensor).value);
      hiddenShape = _shapeOf((outputs[1] as OrtValueTensor).value);
    }
    return _Ok(outputDecoder.decodeOne(
      question: question,
      prompt: prompt,
      logits: logits,
      logitsShape: logitsShape,
      tokenizer: tokenizer,
      hiddenStates: hidden,
      hiddenShape: hiddenShape,
      latencyMs: 0,
    ));
  } on D1UnsupportedPrimitive catch (e) {
    return _Err(e.toString());
  } catch (e) {
    return _Err('execução ONNX do d1 falhou: $e');
  } finally {
    runOptions.release();
    for (final o in outputs ?? const <OrtValue?>[]) {
      o?.release();
    }
    for (final v in inputs.values) {
      v.release();
    }
  }
}

/// Cria um tensor float32 vazio (`[0,2048]`) — o `createTensorWithDataList` do
/// onnxruntime_v2 não aceita listas vazias e o decoder d1 exige o input.
OrtValueTensor _emptyFloatTensor(List<int> shape) {
  final shapePtr = calloc<ffi.Int64>(shape.length);
  for (var i = 0; i < shape.length; i++) {
    shapePtr[i] = shape[i];
  }
  final out = calloc<ffi.Pointer<bg.OrtValue>>();
  try {
    final status = OrtEnv.instance.ortApiPtr.ref.CreateTensorAsOrtValue
        .asFunction<
            bg.OrtStatusPtr Function(
              ffi.Pointer<bg.OrtAllocator>,
              ffi.Pointer<ffi.Int64>,
              int,
              int,
              ffi.Pointer<ffi.Pointer<bg.OrtValue>>,
            )>()(
      OrtAllocator.instance.ptr,
      shapePtr,
      shape.length,
      1, // ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT
      out,
    );
    OrtStatus.checkOrtStatus(status);
    return OrtValueTensor.fromAddress(out.value.address);
  } finally {
    calloc.free(shapePtr);
    calloc.free(out);
  }
}

Object _runVision(OrtSession session, D1PixelTensor tensor) {
  if (session.inputNames.isEmpty || session.outputNames.isEmpty) {
    return _Err('vision_encoder sem inputs/outputs');
  }
  final inputName = session.inputNames.contains('pixel_values')
      ? 'pixel_values'
      : session.inputNames.first;
  final input =
      OrtValueTensor.createTensorWithDataList(tensor.data, tensor.shape);
  final runOptions = OrtRunOptions();
  List<OrtValue?>? outputs;
  try {
    outputs = session.run(
      runOptions,
      {inputName: input},
      [session.outputNames.first],
    );
    return _Ok(_flattenDoubles((outputs[0] as OrtValueTensor).value));
  } catch (e) {
    return _Err('vision_encoder falhou: $e');
  } finally {
    runOptions.release();
    for (final o in outputs ?? const <OrtValue?>[]) {
      o?.release();
    }
    input.release();
  }
}

Object _runAudio(OrtSession session, D1AudioTensor tensor) {
  if (session.inputNames.isEmpty || session.outputNames.isEmpty) {
    return _Err('audio_encoder sem inputs/outputs');
  }
  final inputName = session.inputNames.contains('input_features')
      ? 'input_features'
      : session.inputNames.first;
  final input =
      OrtValueTensor.createTensorWithDataList(tensor.data, tensor.shape);
  final runOptions = OrtRunOptions();
  List<OrtValue?>? outputs;
  try {
    outputs = session.run(
      runOptions,
      {inputName: input},
      [session.outputNames.first],
    );
    return _Ok(_flattenDoubles((outputs[0] as OrtValueTensor).value));
  } catch (e) {
    return _Err('audio_encoder falhou: $e');
  } finally {
    runOptions.release();
    for (final o in outputs ?? const <OrtValue?>[]) {
      o?.release();
    }
    input.release();
  }
}

List<double> _flattenDoubles(Object? value) {
  final out = <double>[];
  void walk(Object? v) {
    if (v is num) {
      out.add(v.toDouble());
    } else if (v is List) {
      for (final e in v) {
        walk(e);
      }
    }
  }

  walk(value);
  return out;
}

List<int> _shapeOf(Object? value) {
  final out = <int>[];
  var v = value;
  while (v is List) {
    out.add(v.length);
    if (v.isEmpty) break;
    v = v.first;
  }
  return out;
}
