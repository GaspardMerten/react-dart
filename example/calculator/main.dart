/// Browser client entrypoint for the calculator. Compile with:
///
/// ```
/// dart run build_runner build           # calculator.dartx -> Dart
/// dart compile js -O4 example/calculator/main.dart -o example/calculator/main.dart.js
/// ```
///
/// It hydrates the server-rendered markup in `#root`, adopting the existing
/// nodes instead of recreating them, and wires up the keypad and keyboard.
library;

import 'package:reactx/dom.dart';

import 'calculator.dartx.dart';

void main() => hydrateApp(CalculatorApp);
