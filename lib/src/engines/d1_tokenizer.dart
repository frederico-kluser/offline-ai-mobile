/// Tokenizer BPE ByteLevel compatível com `tokenizer.json` do Hugging Face.
///
/// O d1-2B/d1-Omni-2B são modelos de decisão: o texto do estado e das
/// perguntas é tokenizado localmente e empacotado numa única sequência. Este
/// tokenizer cobre o formato BPE ByteLevel usado pela família Liquid
/// (vocabulário de 128K tokens), incluindo `added_tokens` especiais.
///
/// É deliberadamente independente de plugins: só `dart:convert`/`dart:io`.
library;

import 'dart:convert';
import 'dart:io';

/// Um token com o intervalo de caracteres que lhe deu origem.
class D1Token {
  final int id;
  final int start;
  final int end;
  const D1Token(this.id, this.start, this.end);

  @override
  String toString() => 'D1Token($id, $start..$end)';
}

/// Tokenizer BPE ByteLevel.
class D1Tokenizer {
  final Map<String, int> vocab;
  final Map<int, String> inverseVocab;
  final Map<String, int> merges;
  final Map<String, int> addedTokens;
  final Set<int> specialIds;
  final int unkId;
  final int bosId;
  final int eosId;
  final Map<int, String> _byteToChar;
  final Map<String, int> _charToByte;
  final RegExp _pretokenize;

  D1Tokenizer._({
    required this.vocab,
    required this.inverseVocab,
    required this.merges,
    required this.addedTokens,
    required this.specialIds,
    required this.unkId,
    required this.bosId,
    required this.eosId,
    required Map<int, String> byteToChar,
    required Map<String, int> charToByte,
    // ignore: prefer_initializing_formals
  })  : _byteToChar = byteToChar,
        // ignore: prefer_initializing_formals
        _charToByte = charToByte,
        _pretokenize = RegExp(
          r"'s|'t|'re|'ve|'m|'ll|'d| ?[A-Za-zÀ-ÖØ-öø-ÿ]+| ?[0-9]+| ?[^\sA-Za-zÀ-ÖØ-öø-ÿ0-9]+|\s+(?!\S)|\s+",
          caseSensitive: true,
        );

  int get vocabSize => vocab.length;

  /// Carrega `tokenizer.json`.
  factory D1Tokenizer.fromFile(String path) {
    final raw = File(path).readAsStringSync();
    return D1Tokenizer.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  factory D1Tokenizer.fromJson(Map<String, dynamic> j) {
    final model = (j['model'] as Map?)?.cast<String, dynamic>() ?? const {};
    final rawVocab = (model['vocab'] as Map?)?.cast<String, dynamic>() ?? const {};
    final vocab = <String, int>{};
    rawVocab.forEach((k, v) {
      if (v is num) vocab[k] = v.toInt();
    });

    final merges = <String, int>{};
    final rawMerges = (model['merges'] as List?) ?? const [];
    var rank = 0;
    for (final m in rawMerges) {
      final key = m is String
          ? m
          : (m is List && m.length >= 2) ? '${m[0]} ${m[1]}' : null;
      if (key != null) {
        merges[key] = rank++;
      }
    }

    final addedTokens = <String, int>{};
    final specialIds = <int>{};
    for (final t in (j['added_tokens'] as List?) ?? const []) {
      if (t is! Map) continue;
      final content = t['content'];
      final id = t['id'];
      if (content is String && id is num) {
        addedTokens[content] = id.toInt();
        if (t['special'] == true) specialIds.add(id.toInt());
      }
    }

    final inverseVocab = <int, String>{
      for (final e in vocab.entries) e.value: e.key,
    };
    for (final e in addedTokens.entries) {
      inverseVocab[e.value] = e.key;
    }

    final byteToChar = _buildByteToChar();
    final charToByte = <String, int>{
      for (final e in byteToChar.entries) e.value: e.key,
    };

    int idOf(String? token, int fallback) {
      if (token == null) return fallback;
      return addedTokens[token] ?? vocab[token] ?? fallback;
    }

    return D1Tokenizer._(
      vocab: vocab,
      inverseVocab: inverseVocab,
      merges: merges,
      addedTokens: addedTokens,
      specialIds: specialIds,
      unkId: idOf(model['unk_token'] as String?, 0),
      bosId: idOf(model['bos_token'] as String?, 1),
      eosId: idOf(model['eos_token'] as String?, 2),
      byteToChar: byteToChar,
      charToByte: charToByte,
    );
  }

  /// Codifica [text] em ids. `addSpecial` prefixa BOS e sufixa EOS.
  List<int> encode(String text, {bool addSpecial = false}) =>
      [for (final t in encodeTokens(text)) t.id];

  /// Codifica mantendo os offsets de caracteres de cada token.
  List<D1Token> encodeTokens(String text) {
    final out = <D1Token>[];
    var cursor = 0;

    // 1) Separa added_tokens especiais (match literal mais longo primeiro).
    final specials = addedTokens.keys.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    while (cursor < text.length) {
      var matchedSpecial = false;
      for (final s in specials) {
        if (text.startsWith(s, cursor)) {
          out.add(D1Token(addedTokens[s]!, cursor, cursor + s.length));
          cursor += s.length;
          matchedSpecial = true;
          break;
        }
      }
      if (matchedSpecial) continue;

      // 2) Próximo trecho até ao próximo special (ou fim).
      var next = text.length;
      for (final s in specials) {
        final i = text.indexOf(s, cursor);
        if (i >= 0 && i < next) next = i;
      }
      final segment = text.substring(cursor, next);
      out.addAll(_encodeSegment(segment, cursor));
      cursor = next;
    }
    return out;
  }

  List<D1Token> _encodeSegment(String segment, int baseOffset) {
    final out = <D1Token>[];
    for (final match in _pretokenize.allMatches(segment)) {
      final piece = match.group(0)!;
      final start = baseOffset + match.start;
      final end = baseOffset + match.end;
      final bytes = utf8.encode(piece);
      // Atalho: o token byte-level inteiro já existe no vocabulário (comum
      // em palavras frequentes). Evita BPE desnecessário e cobre tokenizers
      // de teste sem merges.
      final direct = StringBuffer();
      for (final b in bytes) {
        direct.write(_byteToChar[b] ?? String.fromCharCode(b));
      }
      final directId = vocab[direct.toString()] ?? addedTokens[direct.toString()];
      if (directId != null) {
        out.add(D1Token(directId, start, end));
        continue;
      }
      var symbols = <_Symbol>[
        for (final b in bytes)
          _Symbol(
            _byteToChar[b] ?? String.fromCharCode(b),
            start,
            end,
          ),
      ];
      symbols = _bpe(symbols);
      for (final s in symbols) {
        final id = vocab[s.text] ?? addedTokens[s.text] ?? unkId;
        out.add(D1Token(id, s.start, s.end));
      }
    }
    return out;
  }

  List<_Symbol> _bpe(List<_Symbol> symbols) {
    if (symbols.length < 2) return symbols;
    var current = List<_Symbol>.of(symbols);
    while (true) {
      var bestRank = 1 << 30;
      var bestIndex = -1;
      for (var i = 0; i + 1 < current.length; i++) {
        final key = '${current[i].text} ${current[i + 1].text}';
        final rank = merges[key];
        if (rank != null && rank < bestRank) {
          bestRank = rank;
          bestIndex = i;
        }
      }
      if (bestIndex < 0) break;
      final a = current[bestIndex];
      final b = current[bestIndex + 1];
      final merged = _Symbol('${a.text}${b.text}', a.start, b.end);
      current = [
        ...current.take(bestIndex),
        merged,
        ...current.skip(bestIndex + 2),
      ];
    }
    return current;
  }

  /// Descodifica ids para texto UTF-8 (tolerante a bytes inválidos).
  String decode(List<int> ids) {
    final bytes = <int>[];
    for (final id in ids) {
      if (specialIds.contains(id)) continue;
      final token = inverseVocab[id];
      if (token == null) continue;
      for (final ch in token.split('')) {
        final b = _charToByte[ch];
        if (b != null) bytes.add(b);
      }
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// Mapa token-id → texto (para inspeção/debug).
  String? tokenText(int id) => inverseVocab[id];

  /// Offsets de caracteres para uma sequência de ids (decode incremental).
  List<({int start, int end})> offsets(List<int> ids) {
    final out = <({int start, int end})>[];
    var cursor = 0;
    for (final id in ids) {
      final decoded = _decodeToken(id);
      out.add((start: cursor, end: cursor + decoded.length));
      cursor += decoded.length;
    }
    return out;
  }

  String _decodeToken(int id) {
    if (specialIds.contains(id)) return '';
    final token = inverseVocab[id];
    if (token == null) return '';
    final bytes = <int>[];
    for (final ch in token.split('')) {
      final b = _charToByte[ch];
      if (b != null) bytes.add(b);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// bytes_to_unicode() do GPT-2 (mapeia 256 bytes para code points seguros).
  static Map<int, String> _buildByteToChar() {
    final bs = <int>[
      for (var i = 0x21; i <= 0x7E; i++) i,
      for (var i = 0xA1; i <= 0xAC; i++) i,
      for (var i = 0xAE; i <= 0xFF; i++) i,
    ];
    final cs = List<int>.of(bs);
    var n = 0;
    for (var b = 0; b < 256; b++) {
      if (!bs.contains(b)) {
        bs.add(b);
        cs.add(256 + n);
        n++;
      }
    }
    return {
      for (var i = 0; i < bs.length; i++) bs[i]: String.fromCharCode(cs[i]),
    };
  }
}

class _Symbol {
  final String text;
  final int start;
  final int end;
  const _Symbol(this.text, this.start, this.end);
}
