library js_wrapper_generator;

import 'package:analyzer_experimental/src/generated/ast.dart';
import 'package:analyzer_experimental/src/generated/error.dart';
import 'package:analyzer_experimental/src/generated/parser.dart';
import 'package:analyzer_experimental/src/generated/scanner.dart';

final wrapper = const _Wrapper();
class _Wrapper {
  const _Wrapper();
}

final keepAbstract = const _KeepAbstract();
class _KeepAbstract {
  const _KeepAbstract();
}

final customCast = const _CustomCast();
class _CustomCast {
  const _CustomCast();
}

final forMethods = const _ForMethods();
class _ForMethods {
  const _ForMethods();
}

String transform(String code) {
  final unit = _parseCompilationUnit(code);
  final transformations = _buildTransformations(unit, code);
  return _applyTransformations(code, transformations);
}

List<_Transformation> _buildTransformations(CompilationUnit unit, String code) {
  final result = new List<_Transformation>();
  for (var declaration in unit.declarations) {
    if (declaration is ClassDeclaration && _hasAnnotation(declaration, 'wrapper')) {
      // remove @wrapper
      _removeMetadata(result, declaration, (m) => m.name.name == 'wrapper');

      // @forMethods on class
      final forMethodsOnClass = _hasAnnotation(declaration, 'forMethods');
      _removeMetadata(result, declaration, (m) => m.name.name == 'forMethods');

      // remove @keepAbstract or abstract
      if (_hasAnnotation(declaration, 'keepAbstract')){
        _removeMetadata(result, declaration, (m) => m.name.name == 'keepAbstract');
      } else if (declaration.abstractKeyword != null) {
        final abstractKeyword = declaration.abstractKeyword;
        _removeToken(result, abstractKeyword);
      }

      // custom cast
      final customCast = declaration.members.any((m) => m is MethodDeclaration && _hasAnnotation(m, 'customCast') && m.name.name == 'cast');

      // add cast and constructor
      final name = declaration.name;
      final position = declaration.leftBracket.offset;
      final alreadyExtends = declaration.extendsClause != null;
      result.add(new _Transformation(position, position + 1,
          (alreadyExtends ? '' : 'extends jsw.TypedProxy ') + '{' +
          (customCast ? '' : '\n  static $name cast(js.Proxy proxy) => proxy == null ? null : new $name.fromProxy(proxy);' +
          '\n  $name.fromProxy(js.Proxy proxy) : super.fromProxy(proxy);')));

      // generate member
      declaration.members.forEach((m){
        final forMethods = forMethodsOnClass || _hasAnnotation(m, 'forMethods');
        if (m is FieldDeclaration) {
          final content = new StringBuffer();
          final type = m.fields.type;
          for (final v in m.fields.variables) {
            final name = v.name.name;
            _writeSetter(content, name, type, forMethods: forMethods);
            content.write('\n');
            _writeGetter(content, name, type, forMethods: forMethods);
            content.write('\n');
          }
          result.add(new _Transformation(m.offset, m.endToken.next.offset, content.toString()));
        } else if (customCast && m is MethodDeclaration) {
          _removeMetadata(result, m, (m) => m.name.name == 'customCast');
        } else if (!customCast && m is MethodDeclaration && m.name.name == 'cast') {
          _removeNode(result, m);
        } else if (m is MethodDeclaration && m.isAbstract() && !m.isStatic() && !m.isOperator() && !_hasAnnotation(m, 'keepAbstract')) {
          final method = new StringBuffer();
          if (m.isSetter()){
            final SimpleFormalParameter param = m.parameters.parameters.first;
            _writeSetter(method, m.name.name, param.type, forMethods: forMethods, paramName: param.identifier.name);
          } else if (m.isGetter()) {
            _writeGetter(method, m.name.name, m.returnType, forMethods: forMethods);
          } else {
            if (m.returnType != null) {
              method..write(m.returnType)..write(' ');
            }
            method..write(m.name)..write(m.parameters)..write(_handleReturn('\$unsafe.${m.name.name}(${m.parameters.parameters.map(_handleFormalParameter).join(', ')})', m.returnType));
          }
          result.add(new _Transformation(m.offset, m.end, method.toString()));
        }
      });
    }
  }
  return result;
}

void _writeSetter(StringBuffer sb, String name, TypeName type, {forMethods: false, paramName: null}) {
  paramName = paramName != null ? paramName : name;
  if (forMethods) {
    final nameCapitalized = _capitalize(name);
    sb.write("set ${name}(${type} ${paramName})${_handleReturn("\$unsafe.set${nameCapitalized}(${_handleParameter(paramName, type)})", null)}");
  } else {
    sb.write("set ${name}(${type} ${paramName})${_handleReturn("\$unsafe['${name}'] = ${_handleParameter(paramName, type)}", null)}");
  }
}

void _writeGetter(StringBuffer content, String name, TypeName type, {forMethods: false}) {
  if (forMethods) {
    final nameCapitalized = _capitalize(name);
    content..write("${type} get ${name}${_handleReturn("\$unsafe.get${nameCapitalized}()", type)}");
  } else {
    content..write("${type} get ${name}${_handleReturn("\$unsafe['${name}']", type)}");
  }
}

String _handleFormalParameter(FormalParameter fp) => _handleParameter(fp.identifier.name, fp is SimpleFormalParameter ? fp.type : null);

String _handleParameter(String name, TypeName type) {
  if (type != null) {
    if (type.name.name == 'List') {
      return "${name} is js.Serializable<js.Proxy> ? ${name} : js.array(${name})";
    }
  }
  return name;
}

String _handleReturn(String content, TypeName returnType) {
  var wrap = (String s) => ' => $s;';
  if (returnType != null) {
    if (returnType.name.name == 'void') {
      wrap = (String s) => ' { $s; }';
    } else if (_isTransferableType(returnType)) {
    } else if (returnType.name.name == 'List') {
      if (returnType.typeArguments == null || _isTransferableType(returnType.typeArguments.arguments.first)) {
        wrap = (String s) => ' => jsw.JsArrayToListAdapter.cast($s);';
      } else {
        wrap = (String s) => ' => jsw.JsArrayToListAdapter.castListOfSerializables($s, ${returnType.typeArguments.arguments.first}.cast);';
      }
    } else {
      wrap = (String s) => ' => ${returnType}.cast($s);';
    }
  }
  return wrap(content);
}

bool _isTransferableType(TypeName typeName){
  switch (typeName.name.name) {
    case 'bool':
    case 'String':
    case 'num':
    case 'int':
    case 'double':
      return true;
  }
  return false;
}

void _removeMetadata(List<_Transformation> transformations, AnnotatedNode n, bool testMetadata(Annotation a)) {
  n.metadata.where(testMetadata).forEach((a){
    _removeNode(transformations, a);
  });
}
void _removeNode(List<_Transformation> transformations, ASTNode n) {
  transformations.add(new _Transformation(n.offset, n.endToken.next.offset, ''));
}
void _removeToken(List<_Transformation> transformations, Token t) {
  transformations.add(new _Transformation(t.offset, t.next.offset, ''));
}

bool _hasAnnotation(AnnotatedNode node, String name) => node.metadata.any((m) => m.name.name == name && m.constructorName == null && m.arguments == null);

String _applyTransformations(String code, List<_Transformation> transformations) {
  int padding = 0;
  for (final t in transformations) {
    code = code.substring(0, t.begin + padding) + t.replace + code.substring(t.end + padding);
    padding += t.replace.length - (t.end - t.begin);
  }
  return code;
}

String _capitalize(String s) => s.length == 0 ? '' : (s.substring(0, 1).toUpperCase() + s.substring(1));

CompilationUnit _parseCompilationUnit(String code) {
  var errorListener = new _ErrorCollector();
  var scanner = new StringScanner(null, code, errorListener);
  var token = scanner.tokenize();
  var parser = new Parser(null, errorListener);
  var unit = parser.parseCompilationUnit(token);
  return unit;
}

class _ErrorCollector extends AnalysisErrorListener {
  final errors = new List<AnalysisError>();
  onError(error) => errors.add(error);
}

class _Transformation {
  final int begin;
  final int end;
  final String replace;
  _Transformation(this.begin, this.end, this.replace);
}