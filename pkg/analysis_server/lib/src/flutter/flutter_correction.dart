// Copyright (c) 2018, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:analysis_server/src/services/correction/util.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/src/dart/ast/utilities.dart';
import 'package:analyzer_plugin/protocol/protocol_common.dart' hide Element;
import 'package:analyzer_plugin/utilities/change_builder/change_builder_dart.dart';
import 'package:meta/meta.dart';

class FlutterCorrections {
  final ResolvedUnitResult resolveResult;
  final int selectionOffset;
  final int selectionLength;
  final int selectionEnd;

  final CorrectionUtils utils;

  AstNode node;

  FlutterCorrections(
      {@required this.resolveResult,
      @required this.selectionOffset,
      @required this.selectionLength})
      : assert(resolveResult != null),
        assert(selectionOffset != null),
        assert(selectionLength != null),
        selectionEnd = selectionOffset + selectionLength,
        utils = new CorrectionUtils(resolveResult) {
    node = new NodeLocator(selectionOffset, selectionEnd)
        .searchWithin(resolveResult.unit);
  }

  /**
   * Returns the EOL to use for this [CompilationUnit].
   */
  String get eol => utils.endOfLine;

  Future<SourceChange> addForDesignTimeConstructor() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    final node = this.node;
    if (node is ClassDeclaration) {
      var className = node.name.name;
      var location = utils.prepareNewConstructorLocation(node);
      var changeBuilder = new DartChangeBuilder(resolveResult.session);
      await changeBuilder.addFileEdit(resolveResult.path, (builder) {
        builder.addInsertion(location.offset, (builder) {
          builder.write(location.prefix);

          // If there are no constructors, we need to add also default.
          bool hasConstructors =
              node.members.any((m) => m is ConstructorDeclaration);
          if (!hasConstructors) {
            builder.writeln('$className();');
            builder.writeln();
            builder.write('  ');
          }

          builder.writeln('factory $className.forDesignTime() {');
          builder.writeln('    // TODO: add arguments');
          builder.writeln('    return new $className();');
          builder.write('  }');
          builder.write(location.suffix);
        });
      });
      return changeBuilder.sourceChange;
    }
    return null;
  }
}
