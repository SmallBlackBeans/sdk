// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
/*
DON'T EDIT. GENERATED. DON'T EDIT.
This file has been generated by 'publish.dart' in the dart_messages package.

Messages are maintained in `lib/shared_messages.dart` of that same package.
After any change to that file, run `bin/publish.dart` to generate a new version
of the json, dart2js and analyzer representations.
*/
import '../messages.dart' show MessageTemplate;

enum SharedMessageKind {
  exampleMessage
}

const Map<SharedMessageKind, MessageTemplate> TEMPLATES = const <SharedMessageKind, MessageTemplate>{ 
  SharedMessageKind.exampleMessage: const MessageTemplate(
    SharedMessageKind.exampleMessage,
    "#use #named #arguments",
    howToFix: "an explanation on how to fix things",
    examples: const [
      r'''
      Some multiline example;
      That generates the bug.''',
      const {
      'fileA.dart': r'''
        or a map from file to content.
        again multiline''',
      'fileB.dart': r'''
        with possibly multiple files.
        muliline too''',
      },
    ]
  ),  // Generated. Don't edit.
};
