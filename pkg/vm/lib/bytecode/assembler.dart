// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library vm.bytecode.assembler;

import 'dart:typed_data';

import 'package:kernel/ast.dart' show TreeNode;

import 'dbc.dart';
import 'exceptions.dart' show ExceptionsTable;
import 'source_positions.dart' show SourcePositions;

class Label {
  final bool allowsBackwardJumps;
  List<int> _jumps = <int>[];
  int offset = -1;

  Label({this.allowsBackwardJumps: false});

  bool get isBound => offset >= 0;

  int jumpOperand(int jumpOffset) {
    if (isBound) {
      if (offset <= jumpOffset && !allowsBackwardJumps) {
        throw 'Backward jump to this label is not allowed';
      }
      // Jump instruction takes an offset in DBC words.
      return (offset - jumpOffset) >> BytecodeAssembler.kLog2BytesPerBytecode;
    }
    _jumps.add(jumpOffset);
    return 0;
  }

  List<int> bind(int offset) {
    assert(!isBound);
    this.offset = offset;
    final jumps = _jumps;
    _jumps = null;
    return jumps;
  }
}

class BytecodeAssembler {
  static const int kBitsPerInt = 64;
  static const int kLog2BytesPerBytecode = 2;

  // TODO(alexmarkov): figure out more efficient storage for generated bytecode.
  final List<int> bytecode = new List<int>();
  final Uint32List _encodeBufferIn;
  final Uint8List _encodeBufferOut;
  final ExceptionsTable exceptionsTable = new ExceptionsTable();
  final SourcePositions sourcePositions = new SourcePositions();
  bool isUnreachable = false;
  int currentSourcePosition = TreeNode.noOffset;

  BytecodeAssembler._(this._encodeBufferIn, this._encodeBufferOut);

  factory BytecodeAssembler() {
    final buf = new Uint32List(1);
    return new BytecodeAssembler._(buf, new Uint8List.view(buf.buffer));
  }

  int get offset => bytecode.length;
  int get offsetInWords => bytecode.length >> kLog2BytesPerBytecode;

  void bind(Label label) {
    final List<int> jumps = label.bind(offset);
    for (int jumpOffset in jumps) {
      patchJump(jumpOffset, label.jumpOperand(jumpOffset));
    }
    if (jumps.isNotEmpty || label.allowsBackwardJumps) {
      isUnreachable = false;
    }
  }

  void emitSourcePosition() {
    if (currentSourcePosition != TreeNode.noOffset && !isUnreachable) {
      sourcePositions.add(offsetInWords, currentSourcePosition);
    }
  }

  void emitWord(int word) {
    if (isUnreachable) {
      return;
    }
    _encodeBufferIn[0] = word; // TODO(alexmarkov): Which endianness to use?
    bytecode.addAll(_encodeBufferOut);
  }

  int _getOpcodeAt(int pos) {
    return bytecode[pos]; // TODO(alexmarkov): Take endianness into account.
  }

  void _setWord(int pos, int word) {
    _encodeBufferIn[0] = word; // TODO(alexmarkov): Which endianness to use?
    bytecode.setRange(pos, pos + _encodeBufferOut.length, _encodeBufferOut);
  }

  int _unsigned(int v, int bits) {
    assert(bits < kBitsPerInt);
    final int mask = (1 << bits) - 1;
    if ((v & mask) != v) {
      throw 'Value $v is out of unsigned $bits-bit range';
    }
    return v;
  }

  int _signed(int v, int bits) {
    assert(bits < kBitsPerInt);
    final int shift = kBitsPerInt - bits;
    if (((v << shift) >> shift) != v) {
      throw 'Value $v is out of signed $bits-bit range';
    }
    final int mask = (1 << bits) - 1;
    return v & mask;
  }

  int _uint8(int v) => _unsigned(v, 8);
  int _uint16(int v) => _unsigned(v, 16);

//  int _int8(int v) => _signed(v, 8);
  int _int16(int v) => _signed(v, 16);
  int _int24(int v) => _signed(v, 24);

  int _encode0(Opcode opcode) => _uint8(opcode.index);

  int _encodeA(Opcode opcode, int ra) =>
      _uint8(opcode.index) | (_uint8(ra) << 8);

  int _encodeAD(Opcode opcode, int ra, int rd) =>
      _uint8(opcode.index) | (_uint8(ra) << 8) | (_uint16(rd) << 16);

  int _encodeAX(Opcode opcode, int ra, int rx) =>
      _uint8(opcode.index) | (_uint8(ra) << 8) | (_int16(rx) << 16);

  int _encodeD(Opcode opcode, int rd) =>
      _uint8(opcode.index) | (_uint16(rd) << 16);

  int _encodeX(Opcode opcode, int rx) =>
      _uint8(opcode.index) | (_int16(rx) << 16);

  int _encodeABC(Opcode opcode, int ra, int rb, int rc) =>
      _uint8(opcode.index) |
      (_uint8(ra) << 8) |
      (_uint8(rb) << 16) |
      (_uint8(rc) << 24);

// TODO(alexmarkov) This format is currently unused. Restore it if needed, or
// remove it once bytecode instruction set is finalized.
//
//  int _encodeABY(Opcode opcode, int ra, int rb, int ry) =>
//      _uint8(opcode.index) |
//      (_uint8(ra) << 8) |
//      (_uint8(rb) << 16) |
//      (_int8(ry) << 24);

  int _encodeT(Opcode opcode, int rt) =>
      _uint8(opcode.index) | (_int24(rt) << 8);

  void emitBytecode0(Opcode opcode) {
    assert(BytecodeFormats[opcode].encoding == Encoding.k0);
    emitSourcePosition();
    emitWord(_encode0(opcode));
  }

  void _emitJumpBytecode(Opcode opcode, Label label) {
    assert(isJump(opcode));
    if (!isUnreachable) {
      // Do not use label if not generating instruction.
      emitWord(_encodeT(opcode, label.jumpOperand(offset)));
    }
  }

  void emitTrap() {
    emitWord(_encode0(Opcode.kTrap));
    isUnreachable = true;
  }

  void emitDrop1() {
    emitWord(_encode0(Opcode.kDrop1));
  }

  void emitJump(Label label) {
    _emitJumpBytecode(Opcode.kJump, label);
    isUnreachable = true;
  }

  void emitJumpIfNoAsserts(Label label) {
    _emitJumpBytecode(Opcode.kJumpIfNoAsserts, label);
  }

  void emitJumpIfNotZeroTypeArgs(Label label) {
    _emitJumpBytecode(Opcode.kJumpIfNotZeroTypeArgs, label);
  }

  void emitJumpIfEqStrict(Label label) {
    _emitJumpBytecode(Opcode.kJumpIfEqStrict, label);
  }

  void emitJumpIfNeStrict(Label label) {
    _emitJumpBytecode(Opcode.kJumpIfNeStrict, label);
  }

  void emitJumpIfTrue(Label label) {
    _emitJumpBytecode(Opcode.kJumpIfTrue, label);
  }

  void emitJumpIfFalse(Label label) {
    _emitJumpBytecode(Opcode.kJumpIfFalse, label);
  }

  void emitJumpIfNull(Label label) {
    _emitJumpBytecode(Opcode.kJumpIfNull, label);
  }

  void emitJumpIfNotNull(Label label) {
    _emitJumpBytecode(Opcode.kJumpIfNotNull, label);
  }

  void patchJump(int pos, int rt) {
    final Opcode opcode = Opcode.values[_getOpcodeAt(pos)];
    assert(isJump(opcode));
    _setWord(pos, _encodeT(opcode, rt));
  }

  void emitReturnTOS() {
    emitWord(_encode0(Opcode.kReturnTOS));
    isUnreachable = true;
  }

  void emitPush(int rx) {
    emitWord(_encodeX(Opcode.kPush, rx));
  }

  void emitLoadConstant(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kLoadConstant, ra, rd));
  }

  void emitPushConstant(int rd) {
    emitWord(_encodeD(Opcode.kPushConstant, rd));
  }

  void emitPushNull() {
    emitWord(_encode0(Opcode.kPushNull));
  }

  void emitPushTrue() {
    emitWord(_encode0(Opcode.kPushTrue));
  }

  void emitPushFalse() {
    emitWord(_encode0(Opcode.kPushFalse));
  }

  void emitPushInt(int rx) {
    emitWord(_encodeX(Opcode.kPushInt, rx));
  }

  void emitStoreLocal(int rx) {
    emitWord(_encodeX(Opcode.kStoreLocal, rx));
  }

  void emitPopLocal(int rx) {
    emitWord(_encodeX(Opcode.kPopLocal, rx));
  }

  void emitIndirectStaticCall(int ra, int rd) {
    emitSourcePosition();
    emitWord(_encodeAD(Opcode.kIndirectStaticCall, ra, rd));
  }

  void emitInterfaceCall(int ra, int rd) {
    emitSourcePosition();
    emitWord(_encodeAD(Opcode.kInterfaceCall, ra, rd));
  }

  void emitDynamicCall(int ra, int rd) {
    emitSourcePosition();
    emitWord(_encodeAD(Opcode.kDynamicCall, ra, rd));
  }

  void emitNativeCall(int rd) {
    emitSourcePosition();
    emitWord(_encodeD(Opcode.kNativeCall, rd));
  }

  void emitStoreStaticTOS(int rd) {
    emitSourcePosition();
    emitWord(_encodeD(Opcode.kStoreStaticTOS, rd));
  }

  void emitPushStatic(int rd) {
    emitWord(_encodeD(Opcode.kPushStatic, rd));
  }

  void emitCreateArrayTOS() {
    emitWord(_encode0(Opcode.kCreateArrayTOS));
  }

  void emitAllocate(int rd) {
    emitSourcePosition();
    emitWord(_encodeD(Opcode.kAllocate, rd));
  }

  void emitAllocateT() {
    emitSourcePosition();
    emitWord(_encode0(Opcode.kAllocateT));
  }

  void emitStoreIndexedTOS() {
    emitWord(_encode0(Opcode.kStoreIndexedTOS));
  }

  void emitStoreFieldTOS(int rd) {
    emitSourcePosition();
    emitWord(_encodeD(Opcode.kStoreFieldTOS, rd));
  }

  void emitStoreContextParent() {
    emitWord(_encode0(Opcode.kStoreContextParent));
  }

  void emitStoreContextVar(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kStoreContextVar, ra, rd));
  }

  void emitLoadFieldTOS(int rd) {
    emitWord(_encodeD(Opcode.kLoadFieldTOS, rd));
  }

  void emitLoadTypeArgumentsField(int rd) {
    emitWord(_encodeD(Opcode.kLoadTypeArgumentsField, rd));
  }

  void emitLoadContextParent() {
    emitWord(_encode0(Opcode.kLoadContextParent));
  }

  void emitLoadContextVar(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kLoadContextVar, ra, rd));
  }

  void emitBooleanNegateTOS() {
    emitWord(_encode0(Opcode.kBooleanNegateTOS));
  }

  void emitThrow(int ra) {
    emitSourcePosition();
    emitWord(_encodeA(Opcode.kThrow, ra));
    isUnreachable = true;
  }

  void emitEntry(int rd) {
    emitWord(_encodeD(Opcode.kEntry, rd));
  }

  void emitFrame(int rd) {
    emitWord(_encodeD(Opcode.kFrame, rd));
  }

  void emitSetFrame(int ra) {
    emitWord(_encodeA(Opcode.kSetFrame, ra));
  }

  void emitAllocateContext(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kAllocateContext, ra, rd));
  }

  void emitCloneContext(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kCloneContext, ra, rd));
  }

  void emitMoveSpecial(SpecialIndex ra, int rx) {
    emitWord(_encodeAX(Opcode.kMoveSpecial, ra.index, rx));
  }

  void emitInstantiateType(int rd) {
    emitSourcePosition();
    emitWord(_encodeD(Opcode.kInstantiateType, rd));
  }

  void emitInstantiateTypeArgumentsTOS(int ra, int rd) {
    emitSourcePosition();
    emitWord(_encodeAD(Opcode.kInstantiateTypeArgumentsTOS, ra, rd));
  }

  void emitAssertAssignable(int ra, int rd) {
    emitSourcePosition();
    emitWord(_encodeAD(Opcode.kAssertAssignable, ra, rd));
  }

  void emitAssertSubtype() {
    emitSourcePosition();
    emitWord(_encode0(Opcode.kAssertSubtype));
  }

  void emitAssertBoolean(int ra) {
    emitSourcePosition();
    emitWord(_encodeA(Opcode.kAssertBoolean, ra));
  }

  void emitCheckStack(int ra) {
    emitSourcePosition();
    emitWord(_encodeA(Opcode.kCheckStack, ra));
  }

  void emitCheckFunctionTypeArgs(int ra, int rd) {
    emitSourcePosition();
    emitWord(_encodeAD(Opcode.kCheckFunctionTypeArgs, ra, rd));
  }

  void emitEntryFixed(int ra, int rd) {
    emitWord(_encodeAD(Opcode.kEntryFixed, ra, rd));
  }

  void emitEntryOptional(int ra, int rb, int rc) {
    emitWord(_encodeABC(Opcode.kEntryOptional, ra, rb, rc));
  }
}
