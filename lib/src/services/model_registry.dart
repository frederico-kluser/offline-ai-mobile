/// Catálogo de artefactos descarregáveis (NENHUM modelo vem embutido na app).
///
/// Ficheiros verificados contra os repositórios oficiais/comunitários: GGUF do
/// MiniCPM5-2B (bartowski) e o kit ONNX do Laya typed-decisions — **export fp32
/// oficial** (`convaiinnovations/laya-typed-decisions`) gerado por
/// `tools/laya_export_fp32.py` e publicado como release deste repo (o checkpoint
/// fp32 não cabe nos repositórios HF). Todos os ficheiros do kit Laya levam
/// sha256 fixado; o download verifica-o sempre.
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
    label: 'Laya typed-decisions oficial · ONNX fp32',
    description: 'Decisor tipado (noul/choice/score) SEM compressão: export fp32 '
        'de 1,69 GB do checkpoint oficial Convai Innovations, head fundida '
        '(5 inputs → logits + act_logits). Calibração oficial '
        '(max_len 1024 · head_max_len 256) + tokenizer BPE ByteLevel.',
    kind: 'laya-onnx-kit',
    localDirName: 'models/laya-typed-onnx',
    mainFilename: 'model.onnx',
    files: [
      RemoteFile(
        url:
            'https://github.com/frederico-kluser/offline-ai-mobile/releases/download/models-laya-typed-decisions-fp32-v1/laya-typed-decisions-fp32.onnx',
        filename: 'model.onnx',
        bytes: 1688700355,
        sha256:
            '0ef200f93f07fe1ea1a78d30d765384e53d1de17faee97a3f2f995e1be1d4d0b',
      ),
      RemoteFile(
        url:
            'https://huggingface.co/convaiinnovations/laya-typed-decisions/resolve/main/tokenizer/tokenizer.json',
        filename: 'tokenizer.json',
        bytes: 3583228,
        sha256:
            '6c8aaa9a542084f2457eab775d4eeb51f92a70c0fd9de28d5edb0ddec3c08d30',
      ),
      RemoteFile(
        url:
            'https://huggingface.co/convaiinnovations/laya-typed-decisions/resolve/main/tokenizer/tokenizer_config.json',
        filename: 'tokenizer_config.json',
        bytes: 337,
        sha256:
            '08d4cf3ac4dca381759441b85b91a6d40e688471dcd33d15d6649eb0a9a854d1',
      ),
      RemoteFile(
        url:
            'https://huggingface.co/convaiinnovations/laya-typed-decisions/resolve/main/rl_agent_config.json',
        filename: 'rl_agent_config.json',
        bytes: 847,
        sha256:
            'ebf0cd524d92342a6be5e48e9fca3d7c2babfb5a56ccd79d2171ef5d8c7f7be8',
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