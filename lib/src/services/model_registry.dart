/// Catálogo de artefactos descarregáveis (NENHUM modelo vem embutido).
///
/// A suíte Liquid AI LFM3 + d1 é publicada em bundles multi-ficheiro: o modelo
/// principal + o projetor mmproj, ou os subgrafos ONNX + tokenizer/processor.
/// Os tamanhos e SHA-256 abaixo foram verificados na API do Hugging Face
/// (`?blobs=true`, LFS oid) em 2026-11-06; os ficheiros ONNX cujo sidecar
/// ainda não foi confirmado ficam com `sha256 == null` e são verificados por
/// tamanho + SHA calculado no momento da instalação (ver `manifest.json`).
///
/// Espelho: o repo público `frederico-kluser/lfm3-mobile-models` publica a
/// release `models-lfm3-suite-v1`. Se o espelho falhar, o downloader usa a
/// origem oficial no Hugging Face.
library;

/// Base do espelho GitHub (o downloader tenta primeiro, depois a origem).
const String kModelMirrorBase =
    'https://github.com/frederico-kluser/lfm3-mobile-models/releases/download/models-lfm3-suite-v1';

/// Família do artefacto (d1-omni-600M é legado LFM2, não LFM3).
enum ModelFamily { lfm3, lfm2Legacy }

extension ModelFamilyX on ModelFamily {
  String get label => switch (this) {
        ModelFamily.lfm3 => 'Liquid AI LFM3',
        ModelFamily.lfm2Legacy => 'LFM2 legado (fallback)',
      };
}

/// Papel do ficheiro no bundle.
enum ModelFileRole {
  weights,
  mmproj,
  decoder,
  decoderData,
  sidecar,
  visionEncoder,
  audioEncoder,
  tokenizer,
  processorConfig,
  chatTemplate,
  config,
  license,
}

class RemoteFile {
  final String filename;

  /// URL oficial (Hugging Face).
  final String url;
  final int bytes;
  final String? sha256;
  final ModelFileRole role;

  /// Alguns subgrafos ONNX têm o mesmo nome em bundles diferentes
  /// (`vision_encoder_fp16.onnx`); o espelho GitHub usa nomes prefixados.
  /// Quando `false`, o downloader salta o espelho e usa a origem oficial.
  final bool mirrorEnabled;

  const RemoteFile({
    required this.filename,
    required this.url,
    required this.bytes,
    this.sha256,
    required this.role,
    this.mirrorEnabled = true,
  });

  /// URL no espelho GitHub, se o ficheiro foi publicado.
  String? mirrorUrl() =>
      mirrorEnabled ? '$kModelMirrorBase/$filename' : null;

  String get sizeLabel => formatBytesCatalog(bytes);
}

class ModelBundle {
  final String id;
  final String label;
  final String description;
  final ModelFamily family;

  /// `gguf` | `onnx`.
  final String kind;
  final List<RemoteFile> files;
  final String localDirName;

  /// Ficheiro principal (pesos ou decoder).
  final String mainFilename;

  /// Projetor multimodal (GGUF).
  final String? mmprojFilename;

  /// Caminhos ONNX (quando aplicável).
  final String? visionEncoderFilename;
  final String? audioEncoderFilename;
  final String? tokenizerFilename;
  final String? processorConfigFilename;

  /// Perfil de hardware mínimo (RAM livre) e espaço em disco.
  final int minFreeRamMb;
  final int minFreeDiskMb;
  final int tier;

  final bool supportsVision;
  final bool supportsVideo;
  final bool supportsAudio;
  final bool supportsThinking;
  final bool supportsTools;
  final String license;
  final String notes;

  const ModelBundle({
    required this.id,
    required this.label,
    required this.description,
    required this.family,
    required this.kind,
    required this.files,
    required this.localDirName,
    required this.mainFilename,
    this.mmprojFilename,
    this.visionEncoderFilename,
    this.audioEncoderFilename,
    this.tokenizerFilename,
    this.processorConfigFilename,
    required this.minFreeRamMb,
    required this.minFreeDiskMb,
    required this.tier,
    this.supportsVision = false,
    this.supportsVideo = false,
    this.supportsAudio = false,
    this.supportsThinking = false,
    this.supportsTools = false,
    this.license = 'LFM Open License v1.0',
    this.notes = '',
  });

  int get totalBytes => files.fold(0, (s, f) => s + f.bytes);

  String get sizeLabel => formatBytesCatalog(totalBytes);

  bool get isOnnx => kind == 'onnx';

  bool get isD1 => id.startsWith('d1-');

  /// Todos os ficheiros têm SHA-256 publicado?
  bool get fullyVerified => files.every((f) => f.sha256 != null);
}

/// Formata bytes de forma estável (sem locale).
String formatBytesCatalog(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(i == 0 ? 0 : 2)} ${units[i]}';
}

const String _hf = 'https://huggingface.co';

ModelBundle _ggufBundle({
  required String id,
  required String label,
  required String description,
  required String repo,
  required String weights,
  required int weightsBytes,
  required String weightsSha,
  String? mmproj,
  int mmprojBytes = 0,
  String? mmprojSha,
  required int minRam,
  required int disk,
  required int tier,
  bool vision = false,
  bool video = false,
  bool audio = false,
  bool thinking = false,
  bool tools = true,
  ModelFamily family = ModelFamily.lfm3,
  String notes = '',
  String license = 'LFM Open License v1.0',
}) {
  final files = <RemoteFile>[
    RemoteFile(
      filename: weights,
      url: '$_hf/$repo/resolve/main/$weights',
      bytes: weightsBytes,
      sha256: weightsSha,
      role: ModelFileRole.weights,
    ),
    if (mmproj != null)
      RemoteFile(
        filename: mmproj,
        url: '$_hf/$repo/resolve/main/$mmproj',
        bytes: mmprojBytes,
        sha256: mmprojSha,
        role: ModelFileRole.mmproj,
      ),
  ];
  return ModelBundle(
    id: id,
    label: label,
    description: description,
    family: family,
    kind: 'gguf',
    files: files,
    localDirName: 'models/$id',
    mainFilename: weights,
    mmprojFilename: mmproj,
    minFreeRamMb: minRam,
    minFreeDiskMb: disk,
    tier: tier,
    supportsVision: vision,
    supportsVideo: video,
    supportsAudio: audio,
    supportsThinking: thinking,
    supportsTools: tools,
    license: license,
    notes: notes,
  );
}

/// Catálogo completo (LFM3 + d1 + fallback legado).
final List<ModelBundle> kModelCatalog = [
  // ------------------------------------------------------------------ texto
  _ggufBundle(
    id: 'lfm3-1.7b-q4_0',
    label: 'LFM3-1.7B · QAD-Q4_0 (essencial)',
    description:
        'Agente de texto, raciocínio <think> e tool search. 1,05 GB em disco; '
        '~1,35 GB de RAM a 8K. O melhor rácio qualidade/RAM para telemóvel.',
    repo: 'LiquidAI/LFM3-1.7B-GGUF',
    weights: 'LFM3-1.7B-QAD-Q4_0.gguf',
    weightsBytes: 1049615680,
    weightsSha: '43a7d09a0e9cba91b63eb7052488b9564569bddfd65754d2e426465e572a7452',
    minRam: 1350,
    disk: 1100,
    tier: 1,
    thinking: true,
    notes: 'QAD = Quantization-Aware Distillation; receita de agente '
        'temp 0.1 · top_k 50 · top_p 1.0 · min_p 0 · repeat 1.1.',
  ),
  _ggufBundle(
    id: 'lfm3-1.7b-q4_k_m',
    label: 'LFM3-1.7B · Q4_K_M (qualidade+)',
    description:
        'Variante K-quant de 1,10 GB; ligeiramente melhor em texto longo. '
        'Boa escolha se sobrarem ~200 MB de disco.',
    repo: 'LiquidAI/LFM3-1.7B-GGUF',
    weights: 'LFM3-1.7B-Q4_K_M.gguf',
    weightsBytes: 1099627808,
    weightsSha: '3793e1e6e2266919d6e015287221b41100175a98eddaba92e111aed3b05c93c4',
    minRam: 1400,
    disk: 1150,
    tier: 1,
    thinking: true,
  ),
  _ggufBundle(
    id: 'lfm3-1.7b-q8_0',
    label: 'LFM3-1.7B · Q8_0 (máxima qualidade)',
    description:
        '1,85 GB; qualidade ≈F16. Recomendado em telemóveis Tier 3 (8 GB+) '
        'para raciocínio/tool calling exigente.',
    repo: 'LiquidAI/LFM3-1.7B-GGUF',
    weights: 'LFM3-1.7B-Q8_0.gguf',
    weightsBytes: 1846238496,
    weightsSha: '8f6b24182258205e9e01e21f1f24a1f208c1e8115578825d202ce39976af20b6',
    minRam: 2400,
    disk: 1900,
    tier: 3,
    thinking: true,
  ),

  // ------------------------------------------------------------------ visão
  _ggufBundle(
    id: 'lfm3-vl-2b-q4_k_m',
    label: 'LFM3-VL-2B · Q4_K_M + mmproj Q8_0',
    description:
        'Visão nativa, OCR, pointing/grounding e vídeo a 2 fps. '
        '1,30 GB em disco (1,10 GB + 203 MB); ~1,80 GB de RAM a 8K.',
    repo: 'LiquidAI/LFM3-VL-2B-GGUF',
    weights: 'LFM3-VL-2B-Q4_K_M.gguf',
    weightsBytes: 1099627808,
    weightsSha: '56dac2e192ff0d9ab8507f4f1aeb4aed0463449bbbefaac79497f041c95f21eb',
    mmproj: 'mmproj-LFM3-VL-2B-Q8_0.gguf',
    mmprojBytes: 203031872,
    mmprojSha: 'c5c5b58d544a18da919172d2d0368090ea1a4a351b6feb7f8a326a264a5918ab',
    minRam: 1900,
    disk: 1400,
    tier: 2,
    vision: true,
    video: true,
    thinking: true,
    notes: 'Projetor lfm3vl; o template de vídeo agrupa pares de frames e '
        'antecipa cada par com <X.X seconds>.',
  ),

  // ------------------------------------------------------------------ áudio
  _ggufBundle(
    id: 'lfm3-audio-2b-q4_k_m',
    label: 'LFM3-Audio-2B · Q4_K_M + mmproj Q8_0',
    description:
        'ASR, LiveASR, TTS a 24 kHz e conversação voz-texto entrelaçada. '
        '1,40 GB em disco; ~2,0 GB de RAM a 8K.',
    repo: 'LiquidAI/LFM3-Audio-2B-GGUF',
    weights: 'LFM3-Audio-2B-Q4_K_M.gguf',
    weightsBytes: 1099626016,
    weightsSha: '9a773289bd321ed879cd3a76545f6aca506e403851a45fb315420aee45625be2',
    mmproj: 'mmproj-LFM3-Audio-2B-Q8_0.gguf',
    mmprojBytes: 303811840,
    mmprojSha: '2b6648b1fd48af16aa0877b0592b144d15070783673e038a379fdbc51d40e365',
    minRam: 2100,
    disk: 1500,
    tier: 2,
    audio: true,
    notes: 'Entrada 16 kHz mono; saída LiquidCodec 24 kHz. Projetor lfm3a.',
  ),

  // ------------------------------------------------------------------ omni
  _ggufBundle(
    id: 'lfm3-omni-2b-q4_k_m',
    label: 'LFM3-Omni-2B · Q4_K_M + mmproj Q4_K_M',
    description:
        'Texto + imagem + vídeo com banda sonora + áudio. Sem <think>. '
        '1,39 GB em disco; ~1,95 GB de RAM a 8K.',
    repo: 'LiquidAI/LFM3-Omni-2B-GGUF',
    weights: 'LFM3-Omni-2B-Q4_K_M.gguf',
    weightsBytes: 1099630080,
    weightsSha: '9f8d30e9d4fd7a9349d586e077988229b3ca0a0e4ad730897563d1eccc9893e2',
    mmproj: 'mmproj-LFM3-Omni-2B-Q4_K_M.gguf',
    mmprojBytes: 291586720,
    mmprojSha: '0a746c0794782a16d4456b230c2a0b5888a2d94a6677211edbed7d7a4177a39a',
    minRam: 2050,
    disk: 1500,
    tier: 2,
    vision: true,
    video: true,
    audio: true,
    thinking: false,
    notes: 'Template MTMD_VIDEO_TEMPLATE_LFM3_OMNI: intercala o segmento '
        'da banda sonora após cada par de frames.',
  ),

  // -------------------------------------------------------------- d1 GGUF
  _ggufBundle(
    id: 'd1-2b-q4_k_m',
    label: 'd1-2B · Q4_K_M + mmproj Q8_0 (System One)',
    description:
        'Decisor tipado visual/documental. Via GGUF do llama.cpp: apenas '
        'noul/choice/score. 1,30 GB em disco.',
    repo: 'LiquidAI/d1-2B-GGUF',
    weights: 'd1-2B-Q4_K_M.gguf',
    weightsBytes: 1099629888,
    weightsSha: 'adca5789ad30ae6027e8e936749bb9f19673097492ab26fa1c5b69643ca50b4b',
    mmproj: 'mmproj-d1-2B-Q8_0.gguf',
    mmprojBytes: 203031584,
    mmprojSha: '62cc6d74fd1e5b1d6b48518566bf4c0cfd2468079a0c096ea323b74eed01e0d1',
    minRam: 1450,
    disk: 1350,
    tier: 2,
    vision: true,
    video: true,
    thinking: false,
    tools: false,
    notes: 'O /v1/systemone só aceita noul/choice/score; para spans/range/box '
        'usa o bundle ONNX. Issue #31150 (router+concorrência) continua aberto.',
  ),
  _ggufBundle(
    id: 'd1-omni-2b-q8_0',
    label: 'd1-Omni-2B · Q8_0 + mmproj Q8_0',
    description:
        'Decisor com áudio e voz. Via GGUF: noul/choice/score. '
        '2,17 GB em disco; alternativa leve é o d1-omni-600M legado.',
    repo: 'LiquidAI/d1-Omni-2B-GGUF',
    weights: 'd1-Omni-2B-Q8_0.gguf',
    weightsBytes: 1846241184,
    weightsSha: 'aedf1a7c341b4281979423dbc39e9c3d3ad1da8834156c8e75af5399ca3b0861',
    mmproj: 'mmproj-d1-Omni-2B-Q8_0.gguf',
    mmprojBytes: 326104096,
    mmprojSha: '31778160ac0ec70f9b59f296aa1c8e70cbd1eb7e3a3ff873d695aaa4c7b8d674',
    minRam: 2600,
    disk: 2250,
    tier: 3,
    vision: true,
    video: true,
    audio: true,
    thinking: false,
    tools: false,
    notes: 'A via GGUF do d1-Omni ainda não expõe as primitivas tipadas; '
        'usa d1-Omni-2B-ONNX para o contrato completo.',
  ),
  _ggufBundle(
    id: 'd1-omni-600m-legacy-q8_0',
    label: 'd1-omni-600M · Q8_0 (legado LFM2)',
    description:
        'Fallback compacto para 4 GB de RAM. NÃO é um modelo LFM3: o GGUF '
        'declara architecture=lfm2 (lançado com a família d1-3B).',
    repo: 'LiquidAI/d1-omni-600M-GGUF',
    weights: 'd1-omni-600M-Q8_0.gguf',
    weightsBytes: 407207584,
    weightsSha: 'cd94463f4cac9c700ec6750df8df005bb6846de410e159d1f5e985e1171693d3',
    mmproj: 'mmproj-d1-omni-600M-Q8_0.gguf',
    mmprojBytes: 262791232,
    mmprojSha: 'df887978550cdbb45f0f57d7b436a0f844689f9f561395a144ced500606c3a89',
    minRam: 1100,
    disk: 700,
    tier: 1,
    vision: true,
    video: true,
    audio: true,
    thinking: false,
    tools: false,
    family: ModelFamily.lfm2Legacy,
    license: 'LFM Open License v1.0 (modelo LFM2 legado)',
    notes: 'Não emparelhar com a suíte LFM3; serve apenas de fallback de '
        'baixa RAM.',
  ),

  // ---------------------------------------------------------------- d1 ONNX
  ModelBundle(
    id: 'd1-2b-onnx-q4',
    label: 'd1-2B-ONNX · q4 + visão q8 (todas as primitivas)',
    description:
        'Decisor completo: noul, choice, multiple, score, spans, range, box e '
        'boxes. 1,96 GB de disco (decoder q4 + vision q8); ~2,4 GB de RAM. '
        'Validado no iOS Simulator; o q4f16 oficial crasha no kernel MLAS '
        'int8 do simulador.',
    family: ModelFamily.lfm3,
    kind: 'onnx',
    localDirName: 'models/d1-2b-onnx-q4',
    mainFilename: 'decoder_q4.onnx',
    visionEncoderFilename: 'vision_encoder_q8.onnx',
    tokenizerFilename: 'tokenizer.json',
    processorConfigFilename: 'processor_config.json',
    minFreeRamMb: 2400,
    minFreeDiskMb: 2250,
    tier: 3,
    supportsVision: true,
    supportsVideo: false,
    supportsAudio: false,
    supportsThinking: false,
    supportsTools: false,
    notes: 'Contrato completo (prompt.py/slots.py/pointer.py). O decoder tem '
        '7 inputs e devolve logits [slots,128000] + hidden_states [1,seq,2048]. '
        'q4 evita o kernel int8 do q4f16; q8 reduz o vision encoder.',
    files: [
      _onnxFile('LiquidAI/d1-2B-ONNX', 'onnx/decoder_q4.onnx',
          358945, '00b77894a36d92c0d455db07f39743c0fa814f5855aa060b75b8dace1654065f',
          ModelFileRole.decoder),
      _onnxFile('LiquidAI/d1-2B-ONNX', 'onnx/decoder_q4.onnx_data',
          1741806592, 'e72031f1b00e3273e286b4125d1b58c20b59c7e031bd791796277e0fab65b14b',
          ModelFileRole.decoderData),
      _onnxFile('LiquidAI/d1-2B-ONNX', 'onnx/vision_encoder_q8.onnx',
          126353, 'ea9421f2a7fa8bc401bee96b1077be522b8d448e82e46c9117f2bc90eb01caac',
          ModelFileRole.visionEncoder),
      _onnxFile('LiquidAI/d1-2B-ONNX', 'onnx/vision_encoder_q8.onnx_data',
          196153344, 'baff3c8cf1dd0b4d8dd3108850558a7f26fafb55367be7bcf98d02739c162d1d',
          ModelFileRole.sidecar),
      _onnxFile('LiquidAI/d1-2B-ONNX', 'tokenizer.json', 17908258,
          'a39eed58008cbcbc09e5b629b81338a654269c64cd13348aaa6090f4db75c7e7',
          ModelFileRole.tokenizer),
      _onnxFile('LiquidAI/d1-2B-ONNX', 'processor_config.json', 1254,
          '37396ef3370083a04381ef25f9e1b50dec184b8cdcf08cf718feb8944ad8f3bc',
          ModelFileRole.processorConfig),
      _onnxFile('LiquidAI/d1-2B-ONNX', 'chat_template.jinja', 12762,
          '17f33d44f7bd01aa94623dd8bf8e4e0ef80580a725ef8b71dc6b78f6bcc11700',
          ModelFileRole.chatTemplate),
      _onnxFile('LiquidAI/d1-2B-ONNX', 'config.json', 2903,
          'ffdc4c996152d23dbe8a2659a8c6aabe2992aa3fa3a41601dd0fca8771d6f332',
          ModelFileRole.config),
    ],
  ),
  ModelBundle(
    id: 'd1-omni-2b-onnx-q4',
    label: 'd1-Omni-2B-ONNX · q4 + visão/áudio (áudio + voz)',
    description:
        'Todas as primitivas + áudio 16 kHz e perguntas faladas. '
        '2,39 GB de disco; ~2,65 GB de RAM. q4 evita o kernel int8 do q4f16.',
    family: ModelFamily.lfm3,
    kind: 'onnx',
    localDirName: 'models/d1-omni-2b-onnx-q4',
    mainFilename: 'decoder_q4.onnx',
    visionEncoderFilename: 'vision_encoder_q8.onnx',
    audioEncoderFilename: 'audio_encoder_fp16.onnx',
    tokenizerFilename: 'tokenizer.json',
    processorConfigFilename: 'processor_config.json',
    minFreeRamMb: 2650,
    minFreeDiskMb: 2500,
    tier: 3,
    supportsVision: true,
    supportsVideo: false,
    supportsAudio: true,
    supportsThinking: false,
    supportsTools: false,
    notes: 'O decoder tem 8 inputs (audio_features [num_audio_tokens,2048]); '
        'o audio_encoder exige log-mel [1,128,frames] a 16 kHz. '
        'q4 evita o crash int8 do q4f16 no iOS Simulator.',
    files: [
      _onnxFile('LiquidAI/d1-Omni-2B-ONNX', 'onnx/decoder_q4.onnx',
          360831, 'd3d54dfb740c761e21ffc4eec0e3546c2f0b7453d4514f357191786585a67681',
          ModelFileRole.decoder),
      _onnxFile('LiquidAI/d1-Omni-2B-ONNX', 'onnx/decoder_q4.onnx_data',
          1741806592, '59df2ee2430b3973edab00ba14771e3da849f476251ada487949cd09e8314d10',
          ModelFileRole.decoderData),
      _onnxFile('LiquidAI/d1-Omni-2B-ONNX', 'onnx/vision_encoder_q8.onnx',
          126353, '5447beba4d5c66315fc561372d71f7d56c6a201c966639c8f029e53f6c0dd483',
          ModelFileRole.visionEncoder),
      _onnxFile('LiquidAI/d1-Omni-2B-ONNX', 'onnx/vision_encoder_q8.onnx_data',
          196153344, 'f55c525bd4502ad0f748836bc119e02e7126d6e7c698ca74365c2785d3cd2122',
          ModelFileRole.sidecar),
      _onnxFile('LiquidAI/d1-Omni-2B-ONNX', 'onnx/audio_encoder_fp16.onnx',
          163115, '20a7c84d1f3b5ca39e6f1903b9482ec68bc16a841b637d4684b72c679036110e',
          ModelFileRole.audioEncoder),
      _onnxFile('LiquidAI/d1-Omni-2B-ONNX', 'onnx/audio_encoder_fp16.onnx_data',
          255173120, 'd7d67ea09bda583fe346097af9f06ba03c92e47870e475f1c65604677581b878',
          ModelFileRole.sidecar),
      _onnxFile('LiquidAI/d1-Omni-2B-ONNX', 'tokenizer.json', 17908634,
          '41927bd314d17d7d7fadb44e10cd0919f7b71528d7741596d8cbd15c6945ec44',
          ModelFileRole.tokenizer),
      _onnxFile('LiquidAI/d1-Omni-2B-ONNX', 'processor_config.json', 1928,
          '2288d34b7c0579593258b1c083de4ab8328a842fdb0190977363e573dbdcd0e5',
          ModelFileRole.processorConfig),
      _onnxFile('LiquidAI/d1-Omni-2B-ONNX', 'chat_template.jinja', 13363,
          null, ModelFileRole.chatTemplate),
      _onnxFile('LiquidAI/d1-Omni-2B-ONNX', 'config.json', 5802,
          null, ModelFileRole.config),
    ],
  ),
];

RemoteFile _onnxFile(
  String repo,
  String path,
  int bytes,
  String? sha,
  ModelFileRole role,
) =>
    RemoteFile(
      filename: path.split('/').last,
      url: '$_hf/$repo/resolve/main/$path',
      bytes: bytes,
      sha256: sha,
      role: role,
      // ONNX: nomes repetidos entre bundles → fallback à origem oficial.
      mirrorEnabled: false,
    );

ModelBundle? modelById(String id) {
  for (final m in kModelCatalog) {
    if (m.id == id) return m;
  }
  return null;
}

/// Bundles do modelo gerador de texto (não-d1).
List<ModelBundle> get kGeneratorBundles =>
    [for (final m in kModelCatalog) if (!m.isD1) m];

/// Bundles do decisor d1.
List<ModelBundle> get kD1Bundles =>
    [for (final m in kModelCatalog) if (m.isD1) m];

/// Escolhe o bundle gerador adequado aos anexos.
ModelBundle? selectGeneratorFor({
  required bool hasImage,
  required bool hasVideo,
  required bool hasAudio,
  bool preferQuality = false,
}) {
  if (hasAudio || (hasVideo && hasAudio)) {
    return _firstInstalledCapable(
      (b) => b.supportsAudio && b.supportsVideo && b.supportsVision,
    );
  }
  if (hasVideo || hasImage) {
    return _firstInstalledCapable((b) => b.supportsVision);
  }
  return _firstInstalledCapable((b) => b.supportsTools) ??
      _firstInstalledCapable((b) => b.family == ModelFamily.lfm3);
}

ModelBundle? _firstInstalledCapable(bool Function(ModelBundle) test) {
  for (final b in kModelCatalog) {
    if (b.isD1) continue;
    if (test(b)) return b;
  }
  return null;
}
