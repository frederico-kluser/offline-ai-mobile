/// Ferramentas locais do agente LFM3 e catálogo de Deferred Tool Loading.
///
/// Regras: resultados NUNCA vazios nem ambíguos — status explícito
/// `ok`/`no_results`/`error` + motivo — e truncagem com marcador explícito.
///
/// O catálogo tem 50+ ferramentas marcadas com `defer_loading: true`; apenas
/// `search_tools` (e o terminador `final_answer`) entram no system prompt.
/// Quando o modelo chama `search_tools`, o handler devolve as referências e
/// os esquemas completos, que o ToolLoop injeta em `<additional_tools>`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../domain/tool_spec.dart';

/// Truncagem com marcador explícito (nunca corte silencioso).
String truncateToolOutput(String output, {int maxChars = 4096}) {
  if (output.length <= maxChars) return output;
  final omitted = output.length - maxChars;
  return '${output.substring(0, maxChars)}\n[...truncado: $omitted caracteres omitidos]';
}

typedef ToolHandler = Future<String> Function(Map<String, dynamic> args);

class LocalTool {
  final ToolSpec spec;
  final ToolHandler handler;
  final Duration timeout;

  const LocalTool({
    required this.spec,
    required this.handler,
    this.timeout = const Duration(seconds: 5),
  });
}

/// Resultado de uma pesquisa local no catálogo de ferramentas.
class ToolSearchHit {
  final LocalTool tool;
  final double score;

  const ToolSearchHit(this.tool, this.score);
}

/// Catálogo determinístico com pesquisa local por nome/descrição/categoria.
class ToolCatalog {
  final List<LocalTool> tools;

  /// Ferramentas carregadas no system prompt inicial.
  final List<LocalTool> active;

  ToolCatalog({required this.tools, required this.active});

  /// Catálogo em que todas as ferramentas estão carregadas (ex.: browser).
  factory ToolCatalog.allActive(List<LocalTool> tools) =>
      ToolCatalog(tools: tools, active: tools);

  List<LocalTool> get deferred =>
      [for (final t in tools) if (t.spec.deferLoading) t];

  LocalTool? byName(String name) {
    for (final t in tools) {
      if (t.spec.name == name) return t;
    }
    return null;
  }

  /// Pesquisa local (sem rede). Devolve até [limit] referências.
  List<ToolSearchHit> search(
    String query, {
    int limit = 6,
    String? category,
  }) {
    final terms = query
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9_]+'))
        .where((t) => t.length >= 2)
        .toSet();
    final hits = <ToolSearchHit>[];
    for (final tool in deferred) {
      if (category != null && category.isNotEmpty && tool.spec.category != category) {
        continue;
      }
      final haystack = '${tool.spec.name} ${tool.spec.description} '
              '${tool.spec.category} ${tool.spec.params.map((p) => p.name).join(' ')}'
          .toLowerCase();
      var score = 0.0;
      for (final term in terms) {
        if (tool.spec.name.toLowerCase().contains(term)) score += 3;
        if (haystack.contains(term)) score += 1;
      }
      if (terms.isEmpty) score = 0.1;
      if (score > 0) hits.add(ToolSearchHit(tool, score));
    }
    hits.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      return byScore != 0
          ? byScore
          : a.tool.spec.name.compareTo(b.tool.spec.name);
    });
    return hits.take(limit).toList();
  }
}

/// Constrói o catálogo completo (50+ ferramentas deferidas).
ToolCatalog buildAgentCatalog({Map<String, String>? noteStore}) {
  final notes = noteStore ?? <String, String>{};
  final tools = <LocalTool>[
    ..._coreTools(notes),
    ..._deviceTools(),
    ..._textTools(),
    ..._mediaTools(),
    ..._timeTools(),
  ];
  final catalog = ToolCatalog(tools: tools, active: const []);
  final searchTool = _searchToolsTool(catalog);
  final active = <LocalTool>[searchTool];
  final withControl = [
    ...tools,
    searchTool,
    LocalTool(
      spec: finalAnswerSpec,
      handler: (args) async => 'ok: ${args['answer'] ?? ''}',
    ),
  ];
  active.add(withControl.last);
  return ToolCatalog(tools: withControl, active: active);
}

/// Alias de compatibilidade usado pela UI e pelos testes.
List<LocalTool> demoTools(Map<String, String> noteStore) =>
    buildAgentCatalog(noteStore: noteStore).tools;

LocalTool _searchToolsTool(ToolCatalog catalog) => LocalTool(
      spec: const ToolSpec(
        name: 'search_tools',
        description:
            'Pesquisa o catálogo de ferramentas locais. Usa-a quando nenhuma '
            'das ferramentas carregadas resolve o pedido; devolve referências '
            'e esquemas completos que ficam disponíveis no próximo passo.',
        category: 'meta',
        params: [
          ParamSpec(
            name: 'query',
            type: 'string',
            description: 'O que precisas de fazer, em palavras-chave',
          ),
          ParamSpec(
            name: 'category',
            type: 'string',
            description: 'Categoria opcional (ex.: device, text, time)',
            required: false,
          ),
        ],
      ),
      handler: (args) async {
        final query = (args['query'] ?? '').toString();
        if (query.trim().isEmpty) {
          return 'error: query vazia';
        }
        final category = args['category']?.toString();
        final hits = catalog.search(query, category: category);
        if (hits.isEmpty) {
          return 'no_results: nenhuma ferramenta corresponde a "$query"';
        }
        return jsonEncode({
          'status': 'ok',
          'query': query,
          'tools': [
            for (final h in hits) h.tool.spec.toReference(),
          ],
          'schemas': [
            for (final h in hits) h.tool.spec.toOpenAiSchema(),
          ],
        });
      },
    );

List<LocalTool> _coreTools(Map<String, String> notes) => [
      LocalTool(
        spec: const ToolSpec(
          name: 'calc_expression',
          description:
              'Calculadora/calculator: calcula uma expressão aritmética com '
              'números, + - * / % ( ) e devolve o resultado. Usa-a para '
              'qualquer conta exata.',
          category: 'math',
          deferLoading: true,
          params: [
            ParamSpec(
              name: 'expression',
              type: 'string',
              description: 'Expressão a calcular, ex.: "(17*23)+109"',
            ),
          ],
        ),
        handler: (args) async {
          final expr = (args['expression'] ?? '').toString();
          final value = safeEval(expr);
          if (value.startsWith('error')) return value;
          return 'ok: $expr = $value';
        },
      ),
      LocalTool(
        spec: const ToolSpec(
          name: 'note_save',
          description: 'Guarda uma nota curta com uma chave, para recordar '
              'informação entre passos.',
          category: 'notes',
          deferLoading: true,
          params: [
            ParamSpec(name: 'key', type: 'string', description: 'Chave da nota'),
            ParamSpec(name: 'value', type: 'string', description: 'Conteúdo'),
          ],
        ),
        handler: (args) async {
          final key = (args['key'] ?? '').toString();
          notes[key] = (args['value'] ?? '').toString();
          return 'ok: nota "$key" guardada';
        },
      ),
      LocalTool(
        spec: const ToolSpec(
          name: 'note_read',
          description: 'Lê uma nota guardada pela chave. Se não existir, '
              'devolve no_results.',
          category: 'notes',
          deferLoading: true,
          params: [
            ParamSpec(name: 'key', type: 'string', description: 'Chave da nota'),
          ],
        ),
        handler: (args) async {
          final key = (args['key'] ?? '').toString();
          final v = notes[key];
          if (v == null) return 'no_results: nota "$key" não existe';
          return 'ok: $v';
        },
      ),
      LocalTool(
        spec: const ToolSpec(
          name: 'note_list',
          description: 'Lista as chaves de notas guardadas.',
          category: 'notes',
          deferLoading: true,
          params: [],
        ),
        handler: (args) async => notes.isEmpty
            ? 'no_results: sem notas'
            : 'ok: ${notes.keys.join(', ')}',
      ),
      LocalTool(
        spec: const ToolSpec(
          name: 'set_alarm',
          description: 'Cria um alarme local à hora indicada (HH:mm) — demo '
              'determinística, não toca no sistema.',
          category: 'device',
          deferLoading: true,
          params: [
            ParamSpec(name: 'time', type: 'string', description: 'Hora HH:mm'),
            ParamSpec(
              name: 'label',
              type: 'string',
              description: 'Etiqueta do alarme',
              required: false,
            ),
          ],
        ),
        handler: (args) async =>
            'ok: alarme "${args['label'] ?? 'alarme'}" às ${args['time']} (demo)',
      ),
      LocalTool(
        spec: const ToolSpec(
          name: 'get_battery',
          description: 'Devolve o nível de bateria conhecido pela app.',
          category: 'device',
          deferLoading: true,
          params: [],
        ),
        handler: (args) async => 'ok: bateria desconhecida (demo offline)',
      ),
    ];

List<LocalTool> _deviceTools() => [
      for (final spec in const [
        ToolSpec(
            name: 'get_device_info',
            description: 'Modelo, SO e arquitetura do dispositivo.',
            category: 'device',
            deferLoading: true,
            params: []),
        ToolSpec(
            name: 'get_storage',
            description: 'Espaço livre e total no armazenamento.',
            category: 'device',
            deferLoading: true,
            params: []),
        ToolSpec(
            name: 'get_network_status',
            description: 'Estado da rede e tipo de ligação.',
            category: 'device',
            deferLoading: true,
            params: []),
        ToolSpec(
            name: 'get_brightness',
            description: 'Nível de brilho do ecrã.',
            category: 'device',
            deferLoading: true,
            params: []),
        ToolSpec(
            name: 'set_brightness',
            description: 'Ajusta o brilho do ecrã (0-100).',
            category: 'device',
            deferLoading: true,
            params: [
              ParamSpec(name: 'level', type: 'integer', description: '0-100')
            ]),
        ToolSpec(
            name: 'get_volume',
            description: 'Nível de volume multimédia.',
            category: 'device',
            deferLoading: true,
            params: []),
        ToolSpec(
            name: 'set_volume',
            description: 'Ajusta o volume multimédia (0-100).',
            category: 'device',
            deferLoading: true,
            params: [
              ParamSpec(name: 'level', type: 'integer', description: '0-100')
            ]),
        ToolSpec(
            name: 'vibrate',
            description: 'Faz vibrar o dispositivo por N milissegundos.',
            category: 'device',
            deferLoading: true,
            params: [
              ParamSpec(name: 'ms', type: 'integer', description: 'Duração')
            ]),
        ToolSpec(
            name: 'flashlight_on',
            description: 'Liga a lanterna.',
            category: 'device',
            deferLoading: true,
            params: []),
        ToolSpec(
            name: 'flashlight_off',
            description: 'Desliga a lanterna.',
            category: 'device',
            deferLoading: true,
            params: []),
        ToolSpec(
            name: 'open_settings',
            description: 'Abre as definições do sistema.',
            category: 'device',
            deferLoading: true,
            params: []),
        ToolSpec(
            name: 'open_url',
            description: 'Abre um URL no browser do sistema.',
            category: 'device',
            deferLoading: true,
            params: [
              ParamSpec(name: 'url', type: 'string', description: 'URL')
            ]),
        ToolSpec(
            name: 'share_text',
            description: 'Partilha texto pelo menu do sistema.',
            category: 'device',
            deferLoading: true,
            params: [
              ParamSpec(name: 'text', type: 'string', description: 'Texto')
            ]),
        ToolSpec(
            name: 'copy_to_clipboard',
            description: 'Copia texto para a área de transferência.',
            category: 'device',
            deferLoading: true,
            params: [
              ParamSpec(name: 'text', type: 'string', description: 'Texto')
            ]),
        ToolSpec(
            name: 'read_clipboard',
            description: 'Lê o texto da área de transferência.',
            category: 'device',
            deferLoading: true,
            params: []),
        ToolSpec(
            name: 'battery_health',
            description: 'Saúde e ciclos da bateria.',
            category: 'device',
            deferLoading: true,
            params: []),
        ToolSpec(
            name: 'cpu_info',
            description: 'Núcleos, frequência e instruções da CPU.',
            category: 'device',
            deferLoading: true,
            params: []),
        ToolSpec(
            name: 'memory_info',
            description: 'Memória total e disponível.',
            category: 'device',
            deferLoading: true,
            params: []),
        ToolSpec(
            name: 'app_version',
            description: 'Versão da aplicação e do runtime.',
            category: 'device',
            deferLoading: true,
            params: []),
        ToolSpec(
            name: 'log_event',
            description: 'Regista um evento de diagnóstico local.',
            category: 'device',
            deferLoading: true,
            params: [
              ParamSpec(name: 'event', type: 'string', description: 'Evento')
            ]),
      ])
        LocalTool(
          spec: spec,
          handler: (args) async => 'ok: ${spec.name} (demo offline no telemóvel)',
        ),
    ];

List<LocalTool> _textTools() => [
      for (final spec in const [
        ToolSpec(
            name: 'convert_units',
            description: 'Converte unidades de comprimento, massa ou temperatura.',
            category: 'math',
            deferLoading: true,
            params: [
              ParamSpec(name: 'value', type: 'number', description: 'Valor'),
              ParamSpec(name: 'from', type: 'string', description: 'Unidade origem'),
              ParamSpec(name: 'to', type: 'string', description: 'Unidade destino'),
            ]),
        ToolSpec(
            name: 'convert_currency',
            description: 'Converte moeda com taxas fixas de demonstração.',
            category: 'math',
            deferLoading: true,
            params: [
              ParamSpec(name: 'amount', type: 'number', description: 'Montante'),
              ParamSpec(name: 'from', type: 'string', description: 'Moeda origem'),
              ParamSpec(name: 'to', type: 'string', description: 'Moeda destino'),
            ]),
        ToolSpec(
            name: 'word_count',
            description: 'Conta palavras e caracteres de um texto.',
            category: 'text',
            deferLoading: true,
            params: [
              ParamSpec(name: 'text', type: 'string', description: 'Texto')
            ]),
        ToolSpec(
            name: 'char_count',
            description: 'Conta caracteres de um texto.',
            category: 'text',
            deferLoading: true,
            params: [
              ParamSpec(name: 'text', type: 'string', description: 'Texto')
            ]),
        ToolSpec(
            name: 'text_summary',
            description: 'Resume um texto curto em duas frases.',
            category: 'text',
            deferLoading: true,
            params: [
              ParamSpec(name: 'text', type: 'string', description: 'Texto')
            ]),
        ToolSpec(
            name: 'text_translate',
            description: 'Traduz palavras comuns PT/EN/ES (dicionário local).',
            category: 'text',
            deferLoading: true,
            params: [
              ParamSpec(name: 'text', type: 'string', description: 'Texto'),
              ParamSpec(name: 'to', type: 'string', description: 'Idioma destino'),
            ]),
        ToolSpec(
            name: 'base64_encode',
            description: 'Codifica texto em Base64.',
            category: 'text',
            deferLoading: true,
            params: [
              ParamSpec(name: 'text', type: 'string', description: 'Texto')
            ]),
        ToolSpec(
            name: 'base64_decode',
            description: 'Descodifica Base64 para texto.',
            category: 'text',
            deferLoading: true,
            params: [
              ParamSpec(name: 'text', type: 'string', description: 'Base64')
            ]),
        ToolSpec(
            name: 'sha256_text',
            description: 'Calcula SHA-256 de um texto.',
            category: 'text',
            deferLoading: true,
            params: [
              ParamSpec(name: 'text', type: 'string', description: 'Texto')
            ]),
        ToolSpec(
            name: 'uuid_v4',
            description: 'Gera um UUID determinístico de demonstração.',
            category: 'text',
            deferLoading: true,
            params: []),
        ToolSpec(
            name: 'random_int',
            description: 'Gera um inteiro pseudoaleatório com seed fixa.',
            category: 'math',
            deferLoading: true,
            params: [
              ParamSpec(name: 'min', type: 'integer', description: 'Mínimo'),
              ParamSpec(name: 'max', type: 'integer', description: 'Máximo'),
            ]),
        ToolSpec(
            name: 'search_web',
            description: 'Pesquisa web (offline: devolve no_results).',
            category: 'web',
            deferLoading: true,
            params: [
              ParamSpec(name: 'query', type: 'string', description: 'Consulta')
            ]),
        ToolSpec(
            name: 'weather_local',
            description: 'Meteorologia local (offline: dados de demonstração).',
            category: 'web',
            deferLoading: true,
            params: [
              ParamSpec(name: 'city', type: 'string', description: 'Cidade')
            ]),
      ])
        LocalTool(
          spec: spec,
          handler: (args) async {
            final text = (args['text'] ?? '').toString();
            return switch (spec.name) {
              'word_count' =>
                'ok: ${text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length} palavras',
              'char_count' => 'ok: ${text.length} caracteres',
              'text_summary' =>
                'ok: ${text.length <= 120 ? text : '${text.substring(0, 120)}…'}',
              'base64_encode' => 'ok: ${base64Encode(utf8.encode(text))}',
              'base64_decode' => () {
                  try {
                    return 'ok: ${utf8.decode(base64Decode(text))}';
                  } catch (_) {
                    return 'error: Base64 inválido';
                  }
                }(),
              'random_int' => 'ok: ${Random(42).nextInt(100)}',
              'uuid_v4' => 'ok: 00000000-0000-4000-8000-000000000001',
              'search_web' => 'no_results: pesquisa web offline',
              'weather_local' => 'ok: 22 °C, céu limpo (demo)',
              _ => 'ok: ${spec.name} (demo determinística)',
            };
          },
        ),
    ];

List<LocalTool> _mediaTools() => [
      for (final spec in const [
        ToolSpec(
            name: 'take_photo',
            description: 'Tira uma fotografia com a câmara.',
            category: 'media',
            deferLoading: true,
            params: []),
        ToolSpec(
            name: 'record_audio',
            description: 'Grava um clipe de áudio a 16 kHz.',
            category: 'media',
            deferLoading: true,
            params: [
              ParamSpec(name: 'seconds', type: 'integer', description: 'Duração')
            ]),
        ToolSpec(
            name: 'play_audio',
            description: 'Reproduz um ficheiro de áudio local.',
            category: 'media',
            deferLoading: true,
            params: [
              ParamSpec(name: 'path', type: 'string', description: 'Caminho')
            ]),
        ToolSpec(
            name: 'get_location',
            description: 'Devolve a localização aproximada.',
            category: 'media',
            deferLoading: true,
            params: []),
      ])
        LocalTool(
          spec: spec,
          handler: (args) async => 'ok: ${spec.name} requer permissão (demo)',
        ),
    ];

List<LocalTool> _timeTools() => [
      for (final spec in const [
        ToolSpec(
            name: 'get_time',
            description: 'Hora local atual.',
            category: 'time',
            deferLoading: true,
            params: []),
        ToolSpec(
            name: 'get_date',
            description: 'Data local atual em ISO 8601.',
            category: 'time',
            deferLoading: true,
            params: []),
        ToolSpec(
            name: 'timer_start',
            description: 'Inicia um temporizador.',
            category: 'time',
            deferLoading: true,
            params: [
              ParamSpec(name: 'seconds', type: 'integer', description: 'Duração')
            ]),
        ToolSpec(
            name: 'timer_stop',
            description: 'Para o temporizador ativo.',
            category: 'time',
            deferLoading: true,
            params: []),
        ToolSpec(
            name: 'stopwatch_start',
            description: 'Inicia o cronómetro.',
            category: 'time',
            deferLoading: true,
            params: []),
        ToolSpec(
            name: 'stopwatch_stop',
            description: 'Para o cronómetro e devolve o tempo.',
            category: 'time',
            deferLoading: true,
            params: []),
        ToolSpec(
            name: 'calendar_today',
            description: 'Eventos de hoje no calendário local.',
            category: 'time',
            deferLoading: true,
            params: []),
        ToolSpec(
            name: 'contacts_search',
            description: 'Pesquisa contactos locais.',
            category: 'time',
            deferLoading: true,
            params: [
              ParamSpec(name: 'query', type: 'string', description: 'Nome')
            ]),
        ToolSpec(
            name: 'send_sms',
            description: 'Envia um SMS (requer confirmação).',
            category: 'time',
            deferLoading: true,
            params: [
              ParamSpec(name: 'to', type: 'string', description: 'Número'),
              ParamSpec(name: 'text', type: 'string', description: 'Texto'),
            ]),
        ToolSpec(
            name: 'make_call',
            description: 'Inicia uma chamada (requer confirmação).',
            category: 'time',
            deferLoading: true,
            params: [
              ParamSpec(name: 'to', type: 'string', description: 'Número')
            ]),
      ])
        LocalTool(
          spec: spec,
          handler: (args) async {
            if (spec.name == 'calendar_today') {
              return 'no_results: sem eventos hoje (demo)';
            }
            if (spec.name == 'contacts_search') {
              return 'no_results: contactos não disponíveis (demo)';
            }
            return 'ok: ${spec.name} (demo offline)';
          },
        ),
    ];

/// Avaliador aritmético SEGURO e determinístico (parser recursivo descendente
/// mínimo — sem `eval`, sem regex ambíguas). Erros devolvem `error:` com
/// motivo explícito.
String safeEval(String expression) {
  try {
    final p = _ExprParser(expression.replaceAll(',', '.'));
    final value = p.parse();
    if (!p.atEnd) {
      return 'error: símbolo inesperado na posição ${p.pos} '
          '("${expression.substring(p.pos)}")';
    }
    if (value == value.roundToDouble() && value.abs() < 1e15) {
      return value.round().toString();
    }
    return value.toStringAsFixed(6).replaceAll(RegExp(r'0+$'), '');
  } on FormatException catch (e) {
    return 'error: ${e.message}';
  }
}

class _ExprParser {
  final String src;
  int pos = 0;
  _ExprParser(this.src);

  bool get atEnd => _skipWs() >= src.length;

  double parse() => _expr();

  int _skipWs() {
    while (pos < src.length && src[pos] == ' ') {
      pos++;
    }
    return pos;
  }

  double _expr() {
    var v = _term();
    while (true) {
      final i = _skipWs();
      if (i < src.length && (src[i] == '+' || src[i] == '-')) {
        pos++;
        final r = _term();
        v = (src[i] == '+') ? v + r : v - r;
      } else {
        return v;
      }
    }
  }

  double _term() {
    var v = _factor();
    while (true) {
      final i = _skipWs();
      if (i < src.length && (src[i] == '*' || src[i] == '/' || src[i] == '%')) {
        pos++;
        final r = _factor();
        if ((src[i] == '/' || src[i] == '%') && r == 0) {
          throw const FormatException('divisão por zero');
        }
        v = switch (src[i]) {
          '*' => v * r,
          '/' => v / r,
          _ => v % r,
        };
      } else {
        return v;
      }
    }
  }

  double _factor() {
    final i = _skipWs();
    if (i >= src.length) throw const FormatException('expressão incompleta');
    if (src[i] == '(') {
      pos++;
      final v = _expr();
      if (_skipWs() >= src.length || src[pos] != ')') {
        throw const FormatException('parêntese sem fecho');
      }
      pos++;
      return v;
    }
    if (src[i] == '-') {
      pos++;
      return -_factor();
    }
    final start = pos;
    while (pos < src.length && (RegExp(r'[0-9.]').hasMatch(src[pos]))) {
      pos++;
    }
    if (pos == start) {
      throw FormatException('símbolo inesperado "${src[pos]}" na posição $pos');
    }
    return double.parse(src.substring(start, pos));
  }
}

/// Executa uma ferramenta com timeout e devolve SEMPRE um [ToolResult]
/// estruturado — nunca exceção para o modelo.
Future<ToolResult> runTool(
  LocalTool tool,
  Map<String, dynamic> args, {
  void Function(ToolValidationError)? onValidationError,
}) async {
  final sw = Stopwatch()..start();
  try {
    validateToolArgs(tool.spec, args);
  } on ToolValidationError catch (e) {
    onValidationError?.call(e);
    return ToolResult(
      name: tool.spec.name,
      ok: false,
      output: 'error: ${e.message}',
      durationMs: sw.elapsedMilliseconds,
      errorKind: 'schema-invalid',
    );
  }
  try {
    final raw = await tool.handler(args).timeout(tool.timeout);
    return ToolResult(
      name: tool.spec.name,
      ok: !raw.startsWith('error') && !raw.startsWith('no_results'),
      output: truncateToolOutput(raw),
      durationMs: sw.elapsedMilliseconds,
    );
  } on TimeoutException {
    return ToolResult(
      name: tool.spec.name,
      ok: false,
      output: 'error: timeout após ${tool.timeout.inSeconds}s',
      durationMs: sw.elapsedMilliseconds,
      errorKind: 'timeout',
    );
  } catch (e) {
    return ToolResult(
      name: tool.spec.name,
      ok: false,
      output: 'error: falha na execução ($e)',
      durationMs: sw.elapsedMilliseconds,
      errorKind: 'tool-error',
    );
  }
}

/// Ferramenta de CONCLUSÃO: sinal explícito de saída.
const ToolSpec finalAnswerSpec = ToolSpec(
  name: 'final_answer',
  description:
      'Termina a tarefa e entrega a resposta final ao utilizador. Chama-a '
      'quando tiveres a resposta — é a ÚLTIMA ação.',
  category: 'control',
  params: [
    ParamSpec(
      name: 'answer',
      type: 'string',
      description: 'A resposta final para o utilizador',
    ),
  ],
);

/// Seed determinística auxiliar.
final Random deterministicRandom = Random(0);
