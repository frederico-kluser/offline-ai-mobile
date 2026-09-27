/// Motor do Laya sobre `model_q4.onnx` (decisor tipado ONNX 4-bit, head fundida).
///
/// Contrato: [LayaEngine] (`laya_engine.dart`) — `load()` cria a sessão ONNX sobre
/// `model_q4.onnx` com `onnxruntime_v2` (EP **CPU**; o artefacto usa `MatMulNBits`
/// contrib-op, por isso nada de NNAPI/QNN — ver `tools/specs/laya-encoding.md` §8),
/// `decide()` monta os tensores e decodifica para [LayaResponse].
///
/// **Fora da UI thread**: tokenização, montagem de tensores, `run` e decode correm
/// num Isolate persistente criado em `load()`; o isolate da UI só troca mensagens
/// com dados simples.
///
/// Encode = `build_sequence` do SDK oficial (`[CLS] <type> question: …`); decode =
/// `Agent.system_one` (temperatura por cardinalidade com clamp [0.5, 5.0] → softmax →
/// argmax/valor esperado). Especificação completa e fixtures em
/// `tools/specs/laya-encoding.md`.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:onnxruntime_v2/onnxruntime_v2.dart';

import '../domain/laya_config.dart';
import '../domain/laya_types.dart';
import '../laya/wordpiece_tokenizer.dart';
import 'laya_engine.dart';

/// Orçamento do head (opções + cabeçalho curto), em tokens — `head_max_len` da
/// calibração do checkpoint (spec §3).
const int layaHeadMaxLen = 192;

/// Temperaturas calibradas do checkpoint (`laya_config.json`), por índice de qtype
/// (0=choice, 1=score, 2=noul) — spec §6.
const List<double> _kTemperature = [
  1.6369030475616455,
  1.2514300346374512,
  1.983399510383606,
];

/// Temperaturas por bucket `"qtype:size"` (`2`, `3-5`, `6-10`, `11+`) — spec §6.
const Map<String, double> _kTemperatureByOptions = {
  'choice:2': 1.9063563346862793,
  'choice:3-5': 1.7601518630981445,
  'choice:6-10': 1.0000158548355103,
  'choice:11+': 0.10058280825614929,
  'score:3-5': 1.2514300346374512,
  'noul:2': 1.983399510383606,
};

/// Clamp de `clamp_temperature` da referência Python (`TEMP_MIN`/`TEMP_MAX`).
const double _kTempMin = 0.5;
const double _kTempMax = 5.0;

/// Índice `qtype` do tensor de entrada: **0=choice, 1=score, 2=noul**
/// (spec §2 — NÃO usar `QType.onnxIndex`, que está desalinhado com o modelo).
int qtypeIndex(QType t) => switch (t) {
      QType.choice => 0,
      QType.score => 1,
      QType.noul => 2,
    };

/// Bucket de temperatura por cardinalidade (spec §6).
String layaTempBucket(QType t, int k) {
  final size = k <= 2
      ? '2'
      : k <= 5
          ? '3-5'
          : k <= 10
              ? '6-10'
              : '11+';
  return '${t.wire}:$size';
}

/// Motor Laya ONNX. Uso: `await engine.load(...)` e depois `engine.decide(req)`.
class LayaOnnxEngine implements LayaEngine {
  Isolate? _isolate;
  SendPort? _commands;
  bool _ready = false;
  String? _loadError;
  String? _modelPath;
  final Map<int, Completer<Object?>> _inflight = {};
  int _nextId = 0;
  bool _closing = false;

  @override
  bool get isLoaded => _ready;

  @override
  String get modelId {
    final p = _modelPath;
    if (p == null) return 'laya';
    final i = math.max(p.lastIndexOf('/'), p.lastIndexOf('\\'));
    return i >= 0 ? p.substring(i + 1) : p;
  }

  /// Mensagem exata da falha de carregamento (ORT/tokenizer), se houver.
  String? get loadError => _loadError;

  @override
  Future<void> load({
    required String modelPath,
    required String tokenizerPath,
    required LayaConfig config,
  }) async {
    if (_isolate != null) await unload();
    _ready = false;
    _loadError = null;
    _modelPath = modelPath;

    final handshake = Completer<SendPort>();
    final isolate = await Isolate.spawn(
      _layaWorkerMain,
      handshake.complete,
      debugName: 'LayaOnnxEngine',
      onError: null,
    );
    _isolate = isolate;
    final commands = await handshake.future;
    _commands = commands;

    final reply = ReceivePort();
    final ack = await _request(
      reply,
      _LoadCmd(
        modelPath: modelPath,
        tokenizerPath: tokenizerPath,
        config: config,
        reply: reply.sendPort,
      ),
    );
    reply.close();
    if (ack is _Ok) {
      _ready = true;
    } else {
      // Contrato (spec §8.1): load() não rebenta — decide() lança StateError.
      _loadError = (ack as _Err).message;
      _ready = false;
    }
  }

  @override
  Future<LayaResponse> decide(LayaRequest request) async {
    if (!_ready || _commands == null) {
      throw StateError(
          'LayaOnnxEngine: decide() sem motor carregado. ${_loadError ?? 'Chame load() primeiro.'}');
    }
    final reply = ReceivePort();
    final result = await _request(
      reply,
      _DecideCmd(request: request, reply: reply.sendPort),
    );
    reply.close();
    if (result is _Err) {
      throw StateError('LayaOnnxEngine: ${result.message}');
    }
    return (result as _Ok).payload as LayaResponse;
  }

  @override
  Future<void> unload() async {
    final commands = _commands;
    final isolate = _isolate;
    _commands = null;
    _isolate = null;
    _ready = false;
    _modelPath = null;
    if (commands != null && isolate != null && !_closing) {
      _closing = true;
      try {
        final reply = ReceivePort();
        await _request(reply, _UnloadCmd(reply: reply.sendPort))
            .timeout(const Duration(seconds: 10));
        reply.close();
      } catch (_) {
        // worker já morto — o kill abaixo chega
      }
      _closing = false;
    }
    for (final c in _inflight.values) {
      if (!c.isCompleted) c.completeError(StateError('LayaOnnxEngine: unload()'));
    }
    _inflight.clear();
    isolate?.kill(priority: Isolate.immediate);
    _loadError = null;
  }

  Future<Object?> _request(ReceivePort port, Object cmd) {
    final id = _nextId++;
    final completer = Completer<Object?>();
    _inflight[id] = completer;
    port.listen((message) {
      final entry = (message as Map)['id'] as int;
      final c = _inflight.remove(entry);
      if (c != null && !c.isCompleted) c.complete(message['result']);
    });
    _commands!.send(_Envelope(id, cmd));
    return completer.future;
  }
}

// ---------------------------------------------------------------------------
// Protocolo com o worker isolate (só dados simples atravessam a fronteira).
// ---------------------------------------------------------------------------

class _Envelope {
  final int id;
  final Object cmd;
  const _Envelope(this.id, this.cmd);
}

class _LoadCmd {
  final String modelPath;
  final String tokenizerPath;
  final LayaConfig config;
  final SendPort reply;
  const _LoadCmd({
    required this.modelPath,
    required this.tokenizerPath,
    required this.config,
    required this.reply,
  });
}

class _DecideCmd {
  final LayaRequest request;
  final SendPort reply;
  const _DecideCmd({required this.request, required this.reply});
}

class _UnloadCmd {
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
// Worker isolate: tokenizer + sessão ORT + encode/decode.
// ---------------------------------------------------------------------------

Future<void> _layaWorkerMain(void Function(SendPort) handshake) async {
  final commands = ReceivePort();
  handshake(commands.sendPort);

  LayaTokenizer? tokenizer;
  OrtSession? session;
  OrtEnv? env;
  var loadError = 'motor não carregado';

  await for (final raw in commands) {
    final envelope = raw as _Envelope;
    final id = envelope.id;
    final cmd = envelope.cmd;
    try {
      if (cmd is _LoadCmd) {
        final result = _workerLoad(cmd, () {
          env = OrtEnv.instance;
        }, (t, s) {
          tokenizer = t;
          session = s;
        });
        if (result is _Ok) {
          loadError = '';
        } else {
          loadError = (result as _Err).message;
        }
        _reply(id, cmd.reply, result);
      } else if (cmd is _DecideCmd) {
        final tok = tokenizer;
        final sess = session;
        if (tok == null || sess == null) {
          _reply(
              id,
              cmd.reply,
              _Err('não é possível decidir — o modelo não carregou: $loadError'));
          continue;
        }
        _reply(id, cmd.reply, _workerDecide(cmd.request, tok, sess));
      } else if (cmd is _UnloadCmd) {
        session?.release();
        env?.release();
        _reply(id, cmd.reply, const _Ok());
        commands.close();
        Isolate.exit();
      }
    } catch (e, st) {
      _reply(id, (cmd as dynamic).reply as SendPort,
          _Err('$e\n${st.toString().split('\n').take(4).join('\n')}'));
    }
  }
}

void _reply(int id, SendPort reply, Object? result) {
  reply.send({'id': id, 'result': result});
}

/// Cria tokenizer + sessão ORT (EP CPU). Devolve [_Ok] ou [_Err] com o erro exato.
Object _workerLoad(
  _LoadCmd cmd,
  void Function() onEnv,
  void Function(LayaTokenizer, OrtSession) onReady,
) {
  try {
    onEnv();
    OrtEnv.instance.init(level: OrtLoggingLevel.warning, logId: 'laya');
  } catch (e) {
    return _Err('ONNX Runtime (OrtEnv.init) falhou: $e');
  }
  try {
    if (!File(cmd.modelPath).existsSync()) {
      return _Err('modelo não encontrado: ${cmd.modelPath}');
    }
    final tokenizer = LayaTokenizer.fromFile(cmd.tokenizerPath);
    final options = OrtSessionOptions()
      ..setIntraOpNumThreads(cmd.config.threads)
      ..setInterOpNumThreads(1)
      ..setSessionGraphOptimizationLevel(GraphOptimizationLevel.ortEnableAll);
    // EP CPU apenas (spec §8): MatMulNBits não é acelerado por NNAPI/QNN/CoreML
    // e particionamentos heterogéneos só custam cópias. Não é usado nenhum EP de
    // hardware — o default do ORT é o CPU EP.
    final session = OrtSession.fromFile(File(cmd.modelPath), options);
    options.release();
    onReady(tokenizer, session);
    return const _Ok();
  } catch (e) {
    // Caso §8.1 da spec: o runtime não carregou o artefacto (p.ex. contrib-ops
    // MatMulNBits em falta). O erro exato do ORT segue para decide().
    return _Err('model_q4.onnx não carregou no ONNX Runtime: $e');
  }
}

/// Pipeline completo de uma decisão: encode → tensores → run → decode.
Object _workerDecide(LayaRequest request, LayaTokenizer tokenizer,
    OrtSession session) {
  final started = DateTime.now();
  final maxLen = request.questions.isEmpty ? 512 : 512; // substituído abaixo
  // maxLen/maxStateChars vêm do config guardado no load; aqui usa-se o contrato:
  // `maxStateTokens` do LayaConfig — ver `_workerConfig`.
  final config = _workerConfig ?? const LayaConfig();
  final maxLen2 = config.maxStateTokens;
  final state = config.maxStateChars > 0 &&
          request.state.length > config.maxStateChars
      ? request.state.substring(0, config.maxStateChars)
      : request.state;

  final answers = <String, TypedAnswer>{};
  var inputTokens = 0;

  for (final question in request.questions) {
    final q = _toInternal(question);
    final built = _buildSequence(
      tokenizer: tokenizer,
      state: state,
      q: q,
      maxLen: maxLen2,
      headMaxLen: layaHeadMaxLen,
    );
    final k = built.markers.length;
    if (k != q.options.length) {
      throw StateError(
          'pergunta ${question.id}: ${q.options.length} opções não cabem em '
          'head_max_len=$layaHeadMaxLen tokens');
    }
    inputTokens += built.ids.length;

    final decoded = _runAndDecode(
      session: session,
      tokenizer: tokenizer,
      qtype: qtypeIndex(question.type),
      ids: built.ids,
      markers: built.markers,
    );
    answers[question.id] = _makeAnswer(question, decoded);
  }

  return _Ok(LayaResponse(
    answers: answers,
    inputTokens: inputTokens,
    outputTokens: 0,
    latencyMs: DateTime.now().difference(started).inMilliseconds,
  ));
}

/// Config do motor, guardada no load (o worker não tem estado de UI).
LayaConfig? _workerConfig;

/// Forma interna de uma pergunta (espelha `_to_internal` da referência).
class _InternalQuestion {
  final QType t;
  final String ins;
  final List<String> options;
  const _InternalQuestion(this.t, this.ins, this.options);
}

_InternalQuestion _toInternal(TypedQuestion q) {
  switch (q) {
    case NoulQuestion(:final trueCriteria, :final falseCriteria):
      return _InternalQuestion(QType.noul, q.instructions, [
        'false: ${falseCriteria.isEmpty ? 'no, the statement does not hold' : falseCriteria}',
        'true: ${trueCriteria.isEmpty ? 'yes, the statement holds' : trueCriteria}',
      ]);
    case ChoiceQuestion(:final criteria):
      return _InternalQuestion(
          QType.choice,
          q.instructions,
          [
            for (final e in criteria.entries)
              e.value.isEmpty ? e.key : '${e.key}: ${e.value}'
          ]);
    case ScoreQuestion(:final levels):
      return _InternalQuestion(QType.score, q.instructions,
          [for (var i = 0; i < levels.length; i++) 'level $i: ${levels[i]}']);
  }
}

class _BuiltSequence {
  final List<int> ids;
  final List<int> markers;
  const _BuiltSequence(this.ids, this.markers);
}

/// `build_sequence` literal (spec §3).
_BuiltSequence _buildSequence({
  required LayaTokenizer tokenizer,
  required String state,
  required _InternalQuestion q,
  required int maxLen,
  required int headMaxLen,
}) {
  String scrub(String s) => s.replaceAll(LayaTokenizer.maskToken, ' ');

  final headIds = tokenizer.encode('${q.t.wire} question: ${scrub(q.ins)}');
  var optIds = [
    for (final o in q.options)
      [tokenizer.maskId, ...tokenizer.encode(' ${scrub(o)}').take(48)]
  ];

  int total(List<List<int>> xs) =>
      xs.fold<int>(0, (sum, o) => sum + o.length);
  var optBudget = headMaxLen - total(optIds);
  if (optBudget < 16) {
    final per = math.max(4, (headMaxLen - 16) ~/ math.max(1, optIds.length));
    optIds = [for (final o in optIds) o.take(per).toList()];
    optBudget = headMaxLen - total(optIds);
  }
  final head = headIds.take(math.max(8, optBudget)).toList();

  final ids = <int>[tokenizer.clsId, ...head, tokenizer.sepId];
  final markers = <int>[];
  for (final o in optIds) {
    markers.add(ids.length);
    ids.addAll(o);
  }
  ids.add(tokenizer.sepId);

  final room = math.max(0, maxLen - ids.length - 1);
  ids.addAll(tokenizer.encode(scrub(state)).take(room));
  ids.add(tokenizer.sepId);

  final clipped = ids.take(maxLen).toList();
  final keptMarkers = markers.where((m) => m < maxLen).toList();
  return _BuiltSequence(clipped, keptMarkers);
}

class _Decoded {
  final List<double> probs; // softmax(logits/T), k valores
  final double actProbability;
  final double confidence;
  final double answerConfidence;
  const _Decoded(this.probs, this.actProbability, this.confidence,
      this.answerConfidence);
}

/// Corre o grafo (batch estático 1) e faz o decode base (spec §4 e §7).
_Decoded _runAndDecode({
  required OrtSession session,
  required LayaTokenizer tokenizer,
  required int qtype,
  required List<int> ids,
  required List<int> markers,
}) {
  final l = ids.length;
  final k = markers.length;
  final inputs = <String, OrtValue>{
    'input_ids': OrtValueTensor.createTensorWithDataList(ids, [1, l]),
    'attention_mask':
        OrtValueTensor.createTensorWithDataList(List<int>.filled(l, 1), [1, l]),
    'marker_pos': OrtValueTensor.createTensorWithDataList(markers, [1, k]),
    'marker_mask':
        OrtValueTensor.createTensorWithDataList(List<bool>.filled(k, true), [1, k]),
    'qtype': OrtValueTensor.createTensorWithDataList(<int>[qtype], [1]),
  };
  final runOptions = OrtRunOptions();
  List<OrtValue?>? outputs;
  try {
    outputs = session.run(runOptions, inputs, ['logits', 'act_logits']);
    final logits = _flattenDoubles((outputs[0] as OrtValueTensor).value);
    final act = _flattenDoubles((outputs[1] as OrtValueTensor).value);
    if (logits.length < k || act.length < 2) {
      throw StateError(
          'saídas inesperadas do ONNX: logits=${logits.length}, act=${act.length}');
    }

    final t = _temperatureFor(qtype, k);
    final z = [for (var i = 0; i < k; i++) logits[i] / t];
    final probs = _softmax(z);
    final actProb = _softmax(act.take(2).toList());
    return _Decoded(
      probs,
      actProb[0],
      _confidence(qtype, probs),
      _answerConfidence(probs),
    );
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

double _temperatureFor(int qtype, int k) {
  final name = ['choice', 'score', 'noul'][qtype];
  final size = k <= 2
      ? '2'
      : k <= 5
          ? '3-5'
          : k <= 10
              ? '6-10'
              : '11+';
  final t = _kTemperatureByOptions['$name:$size'] ?? _kTemperature[qtype];
  return t.clamp(_kTempMin, _kTempMax).toDouble();
}

TypedAnswer _makeAnswer(TypedQuestion question, _Decoded d) {
  final probs = {for (var i = 0; i < d.probs.length; i++) i: d.probs[i]};
  switch (question) {
    case ChoiceQuestion(:final criteria):
      final keys = criteria.keys.toList();
      var best = 0;
      for (var i = 1; i < d.probs.length; i++) {
        if (d.probs[i] > d.probs[best]) best = i;
      }
      return ChoiceAnswer(
        id: question.id,
        choice: keys[best],
        probabilities: {for (final i in probs.keys) keys[i]: _round4(probs[i]!)},
        confidence: _round4(d.confidence),
        answerConfidence: _round4(d.answerConfidence),
        actProbability: _round4(d.actProbability),
      );
    case ScoreQuestion(:final levels):
      var score = 0.0;
      for (var i = 0; i < d.probs.length; i++) {
        score += i * d.probs[i];
      }
      return ScoreAnswer(
        id: question.id,
        score: _round4(score),
        legend: {for (var i = 0; i < levels.length; i++) '$i': levels[i]},
        probabilities: {for (final i in probs.keys) '$i': _round4(probs[i]!)},
        confidence: _round4(d.confidence),
        answerConfidence: _round4(d.answerConfidence),
        actProbability: _round4(d.actProbability),
      );
    case NoulQuestion():
      final pTrue = d.probs.length > 1 ? d.probs[1] : 0.0;
      return NoulAnswer(
        id: question.id,
        pTrue: _round4(pTrue),
        probabilities: {
          'false': _round4(d.probs[0]),
          'true': _round4(pTrue),
        },
        confidence: _round4(d.confidence),
        answerConfidence: _round4(d.answerConfidence),
        actProbability: _round4(d.actProbability),
      );
  }
}

/// `confidence` = 1 − H(p)/log(k) (choice/score) ou max(p, 1−p) (noul) — spec §7.
double _confidence(int qtype, List<double> p) {
  if (qtype == 2) {
    final pTrue = p.length > 1 ? p[1] : 0.0;
    return math.max(pTrue, 1.0 - pTrue);
  }
  final k = p.length;
  if (k < 2) return 1.0;
  var ent = 0.0;
  for (final x in p) {
    ent -= x * math.log(math.max(x, 1e-12));
  }
  return (1.0 - ent / math.log(k)).clamp(0.0, 1.0).toDouble();
}

/// `answer_confidence` = max(p) — a confiança calibrada (spec §7).
double _answerConfidence(List<double> p) =>
    p.reduce(math.max).clamp(0.0, 1.0).toDouble();

List<double> _softmax(List<double> z) {
  final zMax = z.reduce(math.max);
  final e = [for (final v in z) math.exp(v - zMax)];
  final sum = e.fold<double>(0.0, (a, b) => a + b);
  return [for (final v in e) v / sum];
}

double _round4(double x) => (x * 1e4).roundToDouble() / 1e4;

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
