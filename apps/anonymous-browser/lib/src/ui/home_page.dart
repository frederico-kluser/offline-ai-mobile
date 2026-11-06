/// Página inicial: missões gravadas (retomar/apagar) + nova missão.
library;

import 'package:flutter/material.dart';

import '../domain/mission.dart';
import '../park.dart';
import '../settings.dart';
import 'run_page.dart';
import 'settings_page.dart';

class HomePage extends StatefulWidget {
  final AppSettings settings;
  const HomePage({super.key, required this.settings});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final Park _park = Park();
  List<MissionRunState> _runs = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final runs = await _park.listRuns();
    if (!mounted) return;
    setState(() {
      _runs = runs;
      _loading = false;
    });
  }

  Future<void> _newMission() async {
    final spec = await Navigator.of(context).push<MissionSpec>(
      MaterialPageRoute(
          builder: (_) => NewMissionPage(settings: widget.settings)),
    );
    if (spec == null) return;
    final run = MissionRunState(spec: spec);
    await _park.saveRun(run);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
          builder: (_) => RunPage(run: run, settings: widget.settings)),
    );
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('anonymous-browser mobile'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () async {
              await Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => SettingsPage(settings: widget.settings)));
              setState(() {});
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _newMission,
        icon: const Icon(Icons.add),
        label: const Text('nova missão'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _runs.isEmpty
              ? const Center(
                  child: Text('sem missões — toca em "nova missão"'))
              : ListView.builder(
                  itemCount: _runs.length,
                  itemBuilder: (_, i) {
                    final run = _runs[i];
                    return ListTile(
                      leading: Icon(switch (run.outcome) {
                        RunOutcome.ok => Icons.check_circle,
                        RunOutcome.running => Icons.play_circle,
                        RunOutcome.needsInput => Icons.help,
                        _ => Icons.history,
                      }),
                      title: Text(run.spec.goal,
                          maxLines: 2, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                          '${run.outcome.name} · passo ${run.step} · ${run.spec.decisionMode.name}/${run.spec.textMode.name}'),
                      onTap: () async {
                        await Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) =>
                                RunPage(run: run, settings: widget.settings)));
                        _refresh();
                      },
                      onLongPress: () async {
                        await _park.deleteRun(run.spec.id);
                        _refresh();
                      },
                    );
                  },
                ),
    );
  }
}

/// Formulário de nova missão (objetivo, URL, variáveis, saídas, modos).
class NewMissionPage extends StatefulWidget {
  final AppSettings settings;
  const NewMissionPage({super.key, required this.settings});

  @override
  State<NewMissionPage> createState() => _NewMissionPageState();
}

class _NewMissionPageState extends State<NewMissionPage> {
  final _goal = TextEditingController();
  final _url = TextEditingController(text: 'https://');
  final _vars = TextEditingController();
  final _secretVars = TextEditingController();
  final _extract = TextEditingController();
  DecisionMode _decisionMode = DecisionMode.jevOnline;
  TextMode _textMode = TextMode.mimoOnline;
  int _minutes = 15;

  @override
  void initState() {
    super.initState();
    _decisionMode = widget.settings.decisionMode;
    _textMode = widget.settings.textMode;
    _minutes = widget.settings.defaultMaxMinutes;
  }

  @override
  void dispose() {
    _goal.dispose();
    _url.dispose();
    _vars.dispose();
    _secretVars.dispose();
    _extract.dispose();
    super.dispose();
  }

  Map<String, String> _parseVars(String raw) {
    final out = <String, String>{};
    for (final line in raw.split('\n')) {
      final i = line.indexOf('=');
      if (i <= 0) continue;
      out[line.substring(0, i).trim()] = line.substring(i + 1).trim();
    }
    return out;
  }

  List<ExtractSpec> _parseExtract(String raw) {
    final out = <ExtractSpec>[];
    for (final line in raw.split('\n')) {
      final i = line.indexOf(':');
      if (i <= 0) continue;
      final name = line.substring(0, i).trim();
      final rest = line.substring(i + 1).trim();
      // formato: nome: descricao | regex
      final parts = rest.split('|');
      out.add(ExtractSpec(
        name: name,
        desc: parts.first.trim(),
        regex: parts.length > 1 ? parts[1].trim() : null,
      ));
    }
    return out;
  }

  void _create() {
    final goal = _goal.text.trim();
    if (goal.isEmpty || _url.text.trim().isEmpty) return;
    final spec = MissionSpec(
      id: 'm-${DateTime.now().millisecondsSinceEpoch}',
      goal: goal,
      startUrl: _url.text.trim(),
      variables: _parseVars(_vars.text),
      secretVariables: {
        for (final s in _secretVars.text.split(','))
          if (s.trim().isNotEmpty) s.trim()
      },
      extract: _parseExtract(_extract.text),
      decisionMode: _decisionMode,
      textMode: _textMode,
      maxTime: Duration(minutes: _minutes),
    );
    Navigator.of(context).pop(spec);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('nova missão')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _goal,
            maxLines: 3,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'objetivo',
              hintText:
                  'ex.: regista-me no site X com o email {{email}} e confirma o código {{code}}',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _url,
            decoration: const InputDecoration(
                border: OutlineInputBorder(), labelText: 'URL inicial'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _vars,
            maxLines: 3,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'variáveis (uma por linha: nome=valor)',
              hintText: 'email=fulano@example.invalid',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _secretVars,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'variáveis secretas (separadas por vírgula)',
              hintText: 'password,code',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _extract,
            maxLines: 3,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'saídas (nome: descrição | regex)',
              hintText: r'price: preço visível | R\$\s?[0-9.,]+',
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<DecisionMode>(
            initialValue: _decisionMode,
            decoration: const InputDecoration(
                border: OutlineInputBorder(), labelText: 'decisor'),
            items: const [
              DropdownMenuItem(
                  value: DecisionMode.jevOnline, child: Text('Jev online')),
              DropdownMenuItem(
                  value: DecisionMode.layaLocal, child: Text('Laya local (telemóvel)')),
            ],
            onChanged: (v) => setState(() => _decisionMode = v!),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<TextMode>(
            initialValue: _textMode,
            decoration: const InputDecoration(
                border: OutlineInputBorder(), labelText: 'modelo de texto'),
            items: const [
              DropdownMenuItem(
                  value: TextMode.mimoOnline, child: Text('MiMo online')),
              DropdownMenuItem(
                  value: TextMode.minicpmLocal,
                  child: Text('MiniCPM5-2B local (telemóvel)')),
            ],
            onChanged: (v) => setState(() => _textMode = v!),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Text('orçamento: '),
              Expanded(
                child: Slider(
                  value: _minutes.toDouble(),
                  min: 2,
                  max: 60,
                  divisions: 58,
                  label: '$_minutes min',
                  onChanged: (v) => setState(() => _minutes = v.round()),
                ),
              ),
              Text('$_minutes min'),
            ],
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _create,
            icon: const Icon(Icons.play_arrow),
            label: const Text('criar e correr'),
          ),
        ],
      ),
    );
  }
}
