/// Ponto de entrada: laboratório offline da suíte Liquid AI LFM3 (texto,
/// visão, áudio e omni) e do decisor tipado d1.
library;

import 'package:flutter/material.dart';

import 'src/services/store.dart';
import 'src/ui/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = await AppStore.load();
  runApp(OfflineAiApp(store: store));
}