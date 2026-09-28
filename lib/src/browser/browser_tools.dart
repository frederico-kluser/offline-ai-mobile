/// Ferramentas `browser_*` para o [ToolLoop] do MiniCPM5-2B — o caminho
/// "System Two" do controlo do browser (o Laya é o "System One").
///
/// Regras do projeto (tools.dart): resultados NUNCA vazios nem ambíguos —
/// prefixo `ok:`/`no_results:`/`error:` + motivo — e truncagem com marcador.
/// As ações são validadas pelo executor ([BrowserController]) e o vocabulário
/// do agente exclui `eval`/`stop` (escape hatch é só do humano).
library;

import '../agent/tools.dart';
import '../domain/tool_spec.dart';
import 'browser_action.dart';
import 'browser_controller.dart';

/// System prompt do agente-browser (fluxo determinístico: observar → agir →
/// observar; uma ação de cada vez; nunca repetir chamadas).
const String kBrowserAgentSystemPrompt =
    'És um agente que controla um browser para concluir a tarefa do '
    'utilizador. Fluxo: browser_snapshot para ver os elementos e refs; '
    'escolhe UM alvo; browser_click/browser_type/browser_select para agir; '
    'browser_snapshot de novo para ver o efeito; browser_extract para ler o '
    'conteúdo quando precisares de informação. Uma ferramenta de cada vez. '
    'Nunca repitas a mesma chamada com os mesmos argumentos (se falhar, '
    'faz snapshot e tenta outro alvo). Quando tiveres a resposta, chama '
    'final_answer uma única vez. Responde em português.';

/// Truncagem com marcador explícito para o contexto do modelo.
String _clip(String s, {int maxChars = 2000}) => truncateToolOutput(s,
    maxChars: maxChars);

String _formatResult(ActionResult r) {
  final head = switch (r.status) {
    'ok' => 'ok',
    'no_results' => 'no_results',
    _ => 'error (${r.errorKind ?? 'unknown'})',
  };
  return '$head: ${_clip(r.output)}';
}

/// Catálogo de tools do browser ligado a um [BrowserController].
///
/// `typeText` é o texto por defeito para `browser_type` quando o modelo não
/// fornece `text` (vem do input flutuante do humano).
List<LocalTool> browserTools(
  BrowserController controller, {
  String Function()? typeText,
}) =>
    [
      LocalTool(
        spec: const ToolSpec(
          name: 'browser_snapshot',
          description:
              'Captura o mapa da página atual (URL, título, elementos '
              'interativos com refs e texto). Chama SEMPRE antes de clicar ou '
              'escrever, para obter as refs válidas.',
          params: [],
        ),
        handler: (args) async {
          final r = await controller.execute(const BrowserSnapshot());
          return _formatResult(r);
        },
      ),
      LocalTool(
        spec: const ToolSpec(
          name: 'browser_goto',
          description: 'Navega para um URL http/https.',
          params: [
            ParamSpec(
              name: 'url',
              type: 'string',
              description: 'URL completo, ex.: "https://example.com"',
            ),
          ],
        ),
        handler: (args) async {
          final url = (args['url'] ?? '').toString().trim();
          if (url.isEmpty) return 'error (bad-args): falta o parâmetro "url"';
          final r = await controller.execute(BrowserNavigate(url));
          return _formatResult(r);
        },
      ),
      LocalTool(
        spec: const ToolSpec(
          name: 'browser_click',
          description:
              'Clica no elemento indicado pela ref do snapshot (ex.: "e3").',
          params: [
            ParamSpec(
              name: 'ref',
              type: 'string',
              description: 'Ref do elemento do snapshot, ex.: "e3"',
            ),
          ],
        ),
        handler: (args) async {
          final ref = (args['ref'] ?? '').toString().trim();
          if (ref.isEmpty) return 'error (bad-args): falta o parâmetro "ref"';
          final r = await controller.execute(BrowserTap(ref));
          return _formatResult(r);
        },
      ),
      LocalTool(
        spec: const ToolSpec(
          name: 'browser_type',
          description:
              'Escreve texto no campo indicado pela ref e, com submit=true, '
              'envia o formulário.',
          params: [
            ParamSpec(
              name: 'ref',
              type: 'string',
              description: 'Ref do campo do snapshot, ex.: "e5"',
            ),
            ParamSpec(
              name: 'text',
              type: 'string',
              description: 'Texto a escrever',
              required: false,
            ),
            ParamSpec(
              name: 'submit',
              type: 'boolean',
              description: 'Submeter o formulário depois de escrever',
              required: false,
            ),
          ],
        ),
        handler: (args) async {
          final ref = (args['ref'] ?? '').toString().trim();
          if (ref.isEmpty) return 'error (bad-args): falta o parâmetro "ref"';
          var text = (args['text'] ?? '').toString();
          if (text.isEmpty && typeText != null) text = typeText();
          if (text.isEmpty) {
            return 'error (bad-args): falta o parâmetro "text" e não há texto '
                'do utilizador para usar';
          }
          final submit = args['submit'] == true || args['submit'] == 'true';
          final r = await controller.execute(
              BrowserType(ref: ref, text: text, submit: submit));
          return _formatResult(r);
        },
      ),
      LocalTool(
        spec: const ToolSpec(
          name: 'browser_select',
          description:
              'Seleciona uma opção de um menu <select> pelo valor ou texto.',
          params: [
            ParamSpec(name: 'ref', type: 'string', description: 'Ref do select'),
            ParamSpec(
              name: 'value',
              type: 'string',
              description: 'Valor ou texto da opção',
            ),
          ],
        ),
        handler: (args) async {
          final ref = (args['ref'] ?? '').toString().trim();
          final value = (args['value'] ?? '').toString().trim();
          if (ref.isEmpty || value.isEmpty) {
            return 'error (bad-args): faltam "ref" e/ou "value"';
          }
          final r = await controller.execute(BrowserSelect(ref, value));
          return _formatResult(r);
        },
      ),
      LocalTool(
        spec: const ToolSpec(
          name: 'browser_scroll',
          description:
              'Rola a página (fração do ecrã). direction: "down" | "up".',
          params: [
            ParamSpec(
              name: 'direction',
              type: 'enum',
              description: 'Direção da rolagem',
              enumValues: ['down', 'up'],
            ),
          ],
        ),
        handler: (args) async {
          final dir = (args['direction'] ?? 'down').toString();
          final dy = dir == 'up' ? -0.6 : 0.6;
          final r = await controller.execute(BrowserScroll(0, dy));
          return _formatResult(r);
        },
      ),
      LocalTool(
        spec: const ToolSpec(
          name: 'browser_extract',
          description:
              'Lê o texto principal da página (sem boilerplate) — usa para '
              'obter informação para a resposta final.',
          params: [],
        ),
        handler: (args) async {
          final r = await controller.execute(const BrowserExtract());
          return _formatResult(r);
        },
      ),
    ];