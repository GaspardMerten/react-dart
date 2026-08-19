/// Generates a props type for every `Component` function.
///
/// This is the half of dartx that makes markup type-safe. The emitter turns
/// `<StatCard value={3} />` into `StatCardProps(value: 3)`; this turns
///
/// ```dart
/// Component StatCard({required int value, String label = ''}) => …;
/// ```
///
/// into the `StatCardProps` that call site needs:
///
/// ```dart
/// final class StatCardProps extends ComponentProps {
///   const StatCardProps({required this.value, this.label = '', super.key});
///   final int value;
///   final String label;
///   @override String get name => 'StatCard';
///   @override VNode build() => StatCard(value: value, label: label);
///   @override List<Object?> get fields => [value, label];
/// }
/// ```
///
/// The point of generating it rather than asking you to write it is that there
/// is then exactly one place a component's arguments are declared — the
/// function's own parameter list, with Dart's `required`, defaults and types
/// doing the work they already do. Nothing is repeated, so nothing can drift.
///
/// The parse here is **syntactic only**: no resolution, no type inference, no
/// reading of other files. That is what keeps the builder fast and, more
/// importantly, acyclic — two `.dartx` files may use each other's components
/// freely, because neither needs the other to have been built first.
library;

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';

import 'css.dart';
import 'diagnostics.dart';

/// The generated props classes for [source], or `''` when it declares no
/// components.
///
/// [source] must be valid Dart — call this on the transpiler's *output*, after
/// markup has been compiled away.
String generatePropsClasses(String source, {String? scope}) {
  final unit = parseString(content: source, throwIfDiagnostics: false).unit;

  // Built from the *transpiled* source, because that is what the offsets below
  // index into. Line numbers survive transpilation by design, so a diagnostic
  // positioned here still points at the right line of the `.dartx`; byte
  // offsets do not, which is why the caller's map cannot be used.
  final lineMap = LineMap(source);

  // Anything already declared at the top level, so a generated class cannot
  // silently collide with it.
  final declared = <String>{
    for (final d in unit.declarations)
      if (d is NamedCompilationUnitMember) d.name.lexeme,
  };

  final styles = scope == null ? null : _scopedStylesheet(unit, source, scope);

  final classes = <String>[];
  for (final declaration in unit.declarations) {
    if (declaration is! FunctionDeclaration) continue;
    if (!_isComponent(declaration)) continue;
    classes.add(_classFor(declaration, lineMap, declared,
        styles: styles == null ? null : _stylesConstant));
  }

  if (classes.isEmpty) return styles ?? '';
  return '\n'
      '// ---------------------------------------------------------------------\n'
      '// Props types, generated from the Component functions above. Each one is\n'
      '// what its markup call sites construct, which is why a misspelled or\n'
      '// mistyped attribute is a compile error where you wrote it.\n'
      '// ---------------------------------------------------------------------\n'
      '\n${styles ?? ''}${classes.join('\n')}';
}

/// The name of the generated constant holding the scoped stylesheet.
const _stylesConstant = r'_$dartxStyles';

/// Rewrites the file's `@scoped` stylesheet so it can only reach this file's
/// markup, and emits it as a constant the generated props types return.
///
/// The author's own constant is left exactly as written — they wrote plain CSS
/// and that is what they should still see. What the components carry is this.
String? _scopedStylesheet(CompilationUnit unit, String source, String scope) {
  for (final declaration in unit.declarations) {
    if (declaration is! TopLevelVariableDeclaration) continue;
    if (!declaration.metadata.any((a) =>
        a.name.name == 'scoped' || a.name.name == 'Scoped')) {
      continue;
    }
    for (final variable in declaration.variables.variables) {
      final initializer = variable.initializer;
      if (initializer is! SimpleStringLiteral &&
          initializer is! AdjacentStrings) {
        continue;
      }
      final css = initializer is SimpleStringLiteral
          ? initializer.value
          : (initializer as AdjacentStrings)
              .strings
              .whereType<SimpleStringLiteral>()
              .map((s) => s.value)
              .join();
      final scoped = scopeCss(css, 'data-rx-$scope');
      return "const $_stylesConstant = '''\n$scoped''';\n\n";
    }
  }
  return null;
}

/// Whether [declaration] is a component — that is, whether it says so in its
/// return type.
///
/// A prefixed import (`reactx.Component`) counts, since it names the same type.
bool _isComponent(FunctionDeclaration declaration) {
  final returnType = declaration.returnType?.toSource();
  return returnType == 'Component' || returnType?.endsWith('.Component') == true;
}

/// Whether [declaration] carries `@memoized`.
bool _isMemoized(FunctionDeclaration declaration) => declaration.metadata.any(
    (annotation) =>
        annotation.name.name == 'memoized' ||
        annotation.name.name == 'Memoized');

String _classFor(FunctionDeclaration declaration, LineMap lineMap,
    Set<String> declared, {String? styles}) {
  final name = declaration.name.lexeme;
  final function = declaration.functionExpression;

  Never fail(String message, int offset) => throw DartxError(
        message,
        offset: offset,
        line: lineMap.lineAt(offset),
        column: lineMap.columnAt(offset),
      );

  if (function.typeParameters != null) {
    fail(
      'a component cannot have type parameters yet: `$name` would need a '
      'generic props type, and markup has nowhere to write the type argument.',
      declaration.offset,
    );
  }
  if (declared.contains('${name}Props')) {
    fail(
      '`${name}Props` is already declared in this file, and that is the name '
      "`$name`'s markup call sites use. Rename one of them.",
      declaration.offset,
    );
  }
  if (!_isCapitalised(name)) {
    fail(
      "a component's name must be capitalised: dartx reads a lowercase tag as "
      'an HTML element, so `<$name />` could never resolve to `$name`. Rename '
      'it, or return VNode if it is a helper rather than a component.',
      declaration.offset,
    );
  }

  final parameters = <_Param>[];
  for (final parameter in function.parameters?.parameters ?? <FormalParameter>[]) {
    if (!parameter.isNamed) {
      fail(
        'a component takes named parameters only — they are the attributes, '
        "and a positional one has no name to answer to. Wrap `$name`'s "
        'parameters in braces.',
        parameter.offset,
      );
    }
    final parameterName = parameter.name?.lexeme;
    if (parameterName == null) continue;
    if (parameterName == 'key') {
      fail(
        '`key` is reserved: every component already accepts one, and it '
        'identifies the element rather than describing it. Rename '
        "`$name`'s parameter.",
        parameter.offset,
      );
    }
    if (_reservedMembers.contains(parameterName)) {
      // The generated class declares these itself, so a field of the same name
      // is a duplicate member — an error in generated code, which is the one
      // place the reader cannot fix it.
      fail(
        '`$parameterName` is reserved: the generated `${name}Props` declares a '
        'member with that name. Rename `$name`\'s parameter.',
        parameter.offset,
      );
    }

    final inner = parameter is DefaultFormalParameter
        ? parameter.parameter
        : parameter;
    final defaultValue = parameter is DefaultFormalParameter
        ? parameter.defaultValue?.toSource()
        : null;

    parameters.add(_Param(
      name: parameterName,
      type: inner is SimpleFormalParameter
          ? inner.type?.toSource() ?? 'Object?'
          : _typeOfComplex(inner),
      required: parameter.isRequiredNamed,
      defaultValue: defaultValue,
    ));
  }

  final buffer = StringBuffer();
  final constructorArgs = [
    for (final p in parameters) p.constructorParameter,
    'super.key',
  ];

  // `const` only when every default could be one. A non-const default is
  // legal Dart; it just costs the constructor its constness, which nothing
  // here depends on.
  final isConst = parameters.every((p) => p.defaultIsConst);

  buffer
    ..writeln('final class ${name}Props extends ComponentProps {')
    ..writeln('  ${isConst ? 'const ' : ''}${name}Props('
        '{${constructorArgs.join(', ')}});');
  for (final p in parameters) {
    buffer.writeln('  final ${p.type} ${p.name};');
  }
  buffer
    ..writeln('  @override')
    ..writeln("  String get name => '$name';")
    ..writeln('  @override')
    ..writeln('  VNode build() => $name(${[
      for (final p in parameters) '${p.name}: ${p.name}'
    ].join(', ')});');
  if (parameters.isNotEmpty) {
    buffer
      ..writeln('  @override')
      ..writeln('  List<Object?> get fields => '
          '[${[for (final p in parameters) p.name].join(', ')}];');
  }
  if (_isMemoized(declaration)) {
    buffer
      ..writeln('  @override')
      ..writeln('  bool get memoized => true;');
  }
  if (styles != null) {
    buffer
      ..writeln('  @override')
      ..writeln('  String? get styles => $styles;');
  }
  buffer.writeln('}');
  return buffer.toString();
}

/// Names the generated props class uses for itself, so a parameter cannot.
const _reservedMembers = {
  'name',
  'build',
  'fields',
  'memoized',
  'hashCode',
  'runtimeType',
  'toString',
  'noSuchMethod',
};

/// Whether a name can be a markup tag: `Card`, `_Card`, but not `card`.
bool _isCapitalised(String name) {
  final bare = name.replaceFirst(RegExp(r'^_+'), '');
  if (bare.isEmpty) return false;
  final first = bare.codeUnitAt(0);
  return first >= 0x41 && first <= 0x5a;
}

/// The declared type of a parameter that is not a plain `Type name` — a
/// function-typed parameter, mostly.
String _typeOfComplex(FormalParameter parameter) => switch (parameter) {
      FieldFormalParameter() => 'Object?',
      // `void onTap()?` — the `?` lives on the parameter, not on the return
      // type, and dropping it makes the generated field non-nullable and
      // therefore impossible to leave unset.
      FunctionTypedFormalParameter p =>
        '${p.returnType?.toSource() ?? 'void'} Function'
            '${p.parameters.toSource()}${p.question != null ? '?' : ''}',
      SuperFormalParameter() => 'Object?',
      _ => 'Object?',
    };

class _Param {
  const _Param({
    required this.name,
    required this.type,
    required this.required,
    required this.defaultValue,
  });

  final String name;
  final String type;
  final bool required;
  final String? defaultValue;

  String get constructorParameter => required
      ? 'required this.$name'
      : defaultValue == null
          ? 'this.$name'
          : 'this.$name = ${_normalizedDefault!}';

  /// The default as it must appear in a `const` constructor: an empty
  /// collection literal has to say `const`, and writing that in the component's
  /// own signature would be noise.
  String? get _normalizedDefault => switch (defaultValue?.trim()) {
        '[]' => 'const []',
        '{}' => 'const {}',
        final other => other,
      };

  /// Whether this parameter's default lets the constructor be `const`.
  ///
  /// Only literals count. A bare identifier might name a const field or might
  /// not, and guessing wrong would put the error in generated code, which is
  /// the one place a reader cannot fix it.
  bool get defaultIsConst {
    final value = _normalizedDefault;
    if (value == null) return true;
    if (value.startsWith('const ')) return true;
    if (value == 'true' || value == 'false' || value == 'null') return true;
    if (_number.hasMatch(value)) return true;
    return value.startsWith("'") || value.startsWith('"');
  }
}

final _number = RegExp(r'^-?\d+(\.\d+)?$');
