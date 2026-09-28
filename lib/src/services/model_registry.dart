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

/// MODELO ÚNICO — apenas o melhor (filosofia: qualidade acima de tudo):
/// Q8_0 ≈ F16 (tabela oficial OpenBMB: "~indistinguishable from F16") e pensado
/// para o modo thinking (int4 não fecha raciocínios longos; int8 fecha).
/// ~2,7 GB em disco; ~3,5 GB em RAM a contexto 8k — confortável em 8 GB.
final List<ModelArtifact> kModelCatalog = [
  const ModelArtifact(
    id: 'minicpm5-q80',
    label: 'MiniCPM5-2B · GGUF Q8_0',
    description: 'O MELHOR: qualidade ≈F16 (tabela oficial OpenBMB), thinking '
        'fiável. ~2,7 GB em disco; ~3,5 GB em RAM a contexto 8k.',
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