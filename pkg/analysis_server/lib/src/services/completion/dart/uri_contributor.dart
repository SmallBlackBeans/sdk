// Copyright (c) 2014, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:core';

import 'package:analysis_server/src/protocol_server.dart'
    show CompletionSuggestion, CompletionSuggestionKind;
import 'package:analysis_server/src/provisional/completion/dart/completion_dart.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/file_system/file_system.dart';
import 'package:analyzer/src/generated/sdk.dart';
import 'package:analyzer/src/generated/source.dart';
import 'package:path/path.dart' show posix;
import 'package:path/src/context.dart';

/// A contributor for calculating uri suggestions for import and part
/// directives.
class UriContributor extends DartCompletionContributor {
  /// A flag indicating whether file: and package: URI suggestions should
  /// be included in the list of completion suggestions.
  // TODO(danrubel): remove this flag and related functionality
  // once the UriContributor limits file: and package: URI suggestions
  // to only those paths within context roots.
  static bool suggestFilePaths = true;

  _UriSuggestionBuilder builder;

  @override
  Future<List<CompletionSuggestion>> computeSuggestions(
      DartCompletionRequest request) async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    builder = _UriSuggestionBuilder(request);
    request.target.containingNode.accept(builder);
    return builder.suggestions;
  }
}

class _UriSuggestionBuilder extends SimpleAstVisitor<void> {
  final DartCompletionRequest request;
  final List<CompletionSuggestion> suggestions = <CompletionSuggestion>[];

  _UriSuggestionBuilder(this.request);

  @override
  void visitExportDirective(ExportDirective node) {
    visitNamespaceDirective(node);
  }

  @override
  void visitImportDirective(ImportDirective node) {
    visitNamespaceDirective(node);
  }

  void visitNamespaceDirective(NamespaceDirective node) {
    StringLiteral uri = node.uri;
    if (uri is SimpleStringLiteral) {
      int offset = request.offset;
      int start = uri.offset;
      int end = uri.end;
      if (offset > start) {
        if (offset < end) {
          // Quoted non-empty string
          visitSimpleStringLiteral(uri);
        } else if (offset == end) {
          if (end == start + 1) {
            // Quoted empty string
            visitSimpleStringLiteral(uri);
          } else {
            String data = request.sourceContents;
            if (end == data.length) {
              String ch = data[end - 1];
              if (ch != '"' && ch != "'") {
                // Insertion point at end of file
                // and missing closing quote on non-empty string
                visitSimpleStringLiteral(uri);
              }
            }
          }
        }
      } else if (offset == start && offset == end) {
        String data = request.sourceContents;
        if (end == data.length) {
          String ch = data[end - 1];
          if (ch == '"' || ch == "'") {
            // Insertion point at end of file
            // and missing closing quote on empty string
            visitSimpleStringLiteral(uri);
          }
        }
      }
    }
  }

  @override
  void visitSimpleStringLiteral(SimpleStringLiteral node) {
    AstNode parent = node.parent;
    if (parent is NamespaceDirective && parent.uri == node) {
      String partialUri = _extractPartialUri(node);
      if (partialUri != null) {
        _addDartSuggestions();
        if (UriContributor.suggestFilePaths) {
          _addPackageSuggestions(partialUri);
          _addFileSuggestions(partialUri);
        }
      }
    } else if (parent is PartDirective && parent.uri == node) {
      String partialUri = _extractPartialUri(node);
      if (partialUri != null) {
        if (UriContributor.suggestFilePaths) {
          _addFileSuggestions(partialUri);
        }
      }
    }
  }

  void _addDartSuggestions() {
    _addSuggestion('dart:');
    SourceFactory factory = request.sourceFactory;
    for (SdkLibrary lib in factory.dartSdk.sdkLibraries) {
      if (!lib.isInternal && !lib.isImplementation) {
        if (!lib.shortName.startsWith('dart:_')) {
          _addSuggestion(lib.shortName,
              relevance: lib.shortName == 'dart:core'
                  ? DART_RELEVANCE_LOW
                  : DART_RELEVANCE_DEFAULT);
        }
      }
    }
  }

  void _addFileSuggestions(String partialUri) {
    ResourceProvider resProvider = request.resourceProvider;
    Context resContext = resProvider.pathContext;
    Source source = request.source;

    String parentUri;
    if ((partialUri.endsWith('/'))) {
      parentUri = partialUri;
    } else {
      parentUri = posix.dirname(partialUri);
      if (parentUri != '.' && !parentUri.endsWith('/')) {
        parentUri = '$parentUri/';
      }
    }
    String uriPrefix = parentUri == '.' ? '' : parentUri;

    // Only handle file uris in the format file:///xxx or /xxx
    String parentUriScheme = Uri.parse(parentUri).scheme;
    if (!parentUri.startsWith('file://') && parentUriScheme != '') {
      return;
    }

    String dirPath = resProvider.pathContext.fromUri(parentUri);
    dirPath = resContext.normalize(dirPath);

    if (resContext.isRelative(dirPath)) {
      String sourceDirPath = resContext.dirname(source.fullName);
      if (resContext.isAbsolute(sourceDirPath)) {
        dirPath = resContext.normalize(resContext.join(sourceDirPath, dirPath));
      } else {
        return;
      }
      // Do not suggest relative paths reaching outside the 'lib' directory.
      bool srcInLib = resContext.split(sourceDirPath).contains('lib');
      bool dstInLib = resContext.split(dirPath).contains('lib');
      if (srcInLib && !dstInLib) {
        return;
      }
    }
    if (dirPath.endsWith('\\.')) {
      dirPath = dirPath.substring(0, dirPath.length - 1);
    }

    Resource dir = resProvider.getResource(dirPath);
    if (dir is Folder) {
      try {
        for (Resource child in dir.getChildren()) {
          String completion;
          if (child is Folder) {
            if (!child.shortName.startsWith('.')) {
              completion = '$uriPrefix${child.shortName}/';
            }
          } else if (child is File) {
            if (child.shortName.endsWith('.dart')) {
              completion = '$uriPrefix${child.shortName}';
            }
          }
          if (completion != null && completion != source.shortName) {
            _addSuggestion(completion);
          }
        }
      } on FileSystemException {
        // Guard against I/O exceptions.
      }
    }
  }

  void _addPackageFolderSuggestions(
      String partial, String prefix, Folder folder) {
    try {
      for (Resource child in folder.getChildren()) {
        if (child is Folder) {
          String childPrefix = '$prefix${child.shortName}/';
          _addSuggestion(childPrefix);
          if (partial.startsWith(childPrefix)) {
            _addPackageFolderSuggestions(partial, childPrefix, child);
          }
        } else {
          _addSuggestion('$prefix${child.shortName}');
        }
      }
    } on FileSystemException {
      // Guard against I/O exceptions.
      return;
    }
  }

  void _addPackageSuggestions(String partial) {
    SourceFactory factory = request.sourceFactory;
    Map<String, List<Folder>> packageMap = factory.packageMap;
    if (packageMap != null) {
      _addSuggestion('package:');
      packageMap.forEach((String pkgName, List<Folder> folders) {
        String prefix = 'package:$pkgName/';
        _addSuggestion(prefix);
        for (Folder folder in folders) {
          if (folder.exists) {
            _addPackageFolderSuggestions(partial, prefix, folder);
          }
        }
      });
    }
  }

  void _addSuggestion(String completion,
      {int relevance = DART_RELEVANCE_DEFAULT}) {
    suggestions.add(CompletionSuggestion(CompletionSuggestionKind.IMPORT,
        relevance, completion, completion.length, 0, false, false));
  }

  String _extractPartialUri(SimpleStringLiteral node) {
    if (request.offset < node.contentsOffset) {
      return null;
    }
    return node.literal.lexeme.substring(
        node.contentsOffset - node.offset, request.offset - node.offset);
  }
}
