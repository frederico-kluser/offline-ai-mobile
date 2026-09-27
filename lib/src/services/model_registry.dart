/// Catálogo de artefactos descarregáveis (NENHUM modelo vem embutido na app).
///
/// Ficheiros verificados contra os repositórios oficiais/comunitários (dossiês
/// Q3/Q5): GGUF do MiniCPM5-2B (bartowski — nomes de ficheiro confirmados) e o
/// kit ONNX do Laya typed-decisions (m1rhan). Os tamanhos são os publicados e
/// servem para planear armazenamento; o download verifica sha256 quando
/// disponível.
library;

class RemoteFile {
  final String url;
  final String filename;
  final int bytes;
  final String? sha256;

  const RemoteFile({
    required this.url,
    required this.filename,
    required this.bytes,
    this.sha256,
  });
}

class ModelArtifact {
  final String id;
  final String label;
  final String description;

  /// 'llm-gguf' | 'laya-onnx-kit'
  final String kind;
  final List<RemoteFile> files;
  final String localDirName;

  /// Nome do ficheiro principal (o que os motores carregam).
  final String mainFilename;

  const ModelArtifact({
    required this.id,
    required this.label,
    required this.description,
    required this.kind,
    required this.files,
    required this.localDirName,
    required this.mainFilename,
  });

  int get totalBytes => files.fold(0, (s, f) => s + f.bytes);

  String get sizeLabel {
    const gb = 1024 * 1024 * 1024;
    const mb = 1024 * 1024;
    final b = totalBytes;
    return b >= gb
        ? '${(b / gb).toStringAsFixed(2)} GB'
        : '${(b / mb).toStringAsFixed(0)} MB';
  }
}

/// Recomendação para 8 GB de RAM: Q4_K_M (download 1,62 GB; ~2,3 GB em RAM com
/// contexto 8k). Q5_K_M se a qualidade pesar mais; Q8_0 para máxima qualidade.
/// EVITAR ≤Q3_K (colapso de qualidade medido — dossiê Q3).
final List<ModelArtifact> kModelCatalog = [
  const ModelArtifact(
    id: 'minicpm5-q4km',
    label: 'MiniCPM5-2B · GGUF Q4_K_M',
    description: 'LLM local (tool calling + thinking). Recomendado para 8 GB '
        'de RAM: 1,62 GB em disco, ~2,3 GB em RAM a 8k de contexto. '
        'Contexto prático 8k–16k (o KV cache custa ~42 KB/token).',
    kind: 'llm-gguf',
    localDirName: 'models/minicpm5-q4km',
    mainFilename: 'MiniCPM5-2B-Q4_K_M.gguf',
    files: [
      RemoteFile(
        url:
            'https://huggingface.co/bartowski/MiniCPM5-2B-GGUF/resolve/main/MiniCPM5-2B-Q4_K_M.gguf',
        filename: 'MiniCPM5-2B-Q4_K_M.gguf',
        bytes: 1620000000,
      ),
    ],
  ),
  const ModelArtifact(
    id: 'minicpm5-q5km',
    label: 'MiniCPM5-2B · GGUF Q5_K_M',
    description: 'Mais qualidade que o Q4_K_M (quase sem perdas face ao F16). '
        'Cabe em 8 GB se o contexto ficar ≤8k.',
    kind: 'llm-gguf',
    localDirName: 'models/minicpm5-q5km',
    mainFilename: 'MiniCPM5-2B-Q5_K_M.gguf',
    files: [
      RemoteFile(
        url:
            'https://huggingface.co/bartowski/MiniCPM5-2B-GGUF/resolve/main/MiniCPM5-2B-Q5_K_M.gguf',
        filename: 'MiniCPM5-2B-Q5_K_M.gguf',
        bytes: 1920000000,
      ),
    ],
  ),
  const ModelArtifact(
    id: 'minicpm5-q80',
    label: 'MiniCPM5-2B · GGUF Q8_0',
    description: 'Qualidade máxima quantizada (2,68 GB). Com contexto longo o '
        'KV cache empurra o total para >5 GB — usar só com contexto médio.',
    kind: 'llm-gguf',
    localDirName: 'models/minicpm5-q80',
    mainFilename: 'MiniCPM5-2B-Q8_0.gguf',
    files: [
      RemoteFile(
        url:
            'https://huggingface.co/bartowski/MiniCPM5-2B-GGUF/resolve/main/MiniCPM5-2B-Q8_0.gguf',
        filename: 'MiniCPM5-2B-Q8_0.gguf',
        bytes: 2680000000,
      ),
    ],
  ),
  const ModelArtifact(
    id: 'laya-typed-onnx',
    label: 'Laya typed-decisions · ONNX 4-bit',
    description: 'Decisor tipado (noul/choice/score), 428 MB, head fundida '
        '(5 inputs → logits + act_logits). Re-export de terceiros: verificar '
        'checksum e fixtures (doc §11). Inclui tokenizer WordPiece.',
    kind: 'laya-onnx-kit',
    localDirName: 'models/laya-typed-onnx',
    mainFilename: 'model_q4.onnx',
    files: [
      RemoteFile(
        url:
            'https://huggingface.co/m1rhan/laya-typed-decisions-ONNX/resolve/main/onnx/model_q4.onnx',
        filename: 'model_q4.onnx',
        bytes: 428000000,
      ),
      RemoteFile(
        url:
            'https://huggingface.co/m1rhan/laya-typed-decisions-ONNX/resolve/main/tokenizer.json',
        filename: 'tokenizer.json',
        bytes: 2000000,
      ),
      RemoteFile(
        url:
            'https://huggingface.co/m1rhan/laya-typed-decisions-ONNX/resolve/main/tokenizer_config.json',
        filename: 'tokenizer_config.json',
        bytes: 20000,
      ),
      RemoteFile(
        url:
            'https://huggingface.co/m1rhan/laya-typed-decisions-ONNX/resolve/main/config.json',
        filename: 'config.json',
        bytes: 10000,
      ),
    ],
  ),
];

ModelArtifact? modelById(String id) {
  for (final m in kModelCatalog) {
    if (m.id == id) return m;
  }
  return null;
}