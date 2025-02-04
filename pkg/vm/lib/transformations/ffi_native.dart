// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// @dart=2.12

import 'package:kernel/ast.dart';
import 'package:kernel/library_index.dart' show LibraryIndex;
import 'package:kernel/reference_from_index.dart'
    show IndexedLibrary, ReferenceFromIndex;

/// Transform @FfiNative annotated functions into FFI native function pointer
/// functions.
void transformLibraries(Component component, List<Library> libraries,
    ReferenceFromIndex referenceFromIndex) {
  final index = LibraryIndex(component, ['dart:ffi']);
  // Skip if dart:ffi isn't loaded (e.g. during incremental compile).
  if (index.tryGetClass('dart:ffi', 'FfiNative') == null) {
    return;
  }
  final transformer = FfiNativeTransformer(index, referenceFromIndex);
  libraries.forEach(transformer.visitLibrary);
}

class FfiNativeTransformer extends Transformer {
  Library? currentLibrary;
  IndexedLibrary? currentLibraryIndex;

  final ReferenceFromIndex? referenceFromIndex;
  final Class ffiNativeClass;
  final Class nativeFunctionClass;
  final Field ffiNativeNameField;
  final Field resolverField;
  final Procedure asFunctionProcedure;
  final Procedure fromAddressInternal;

  FfiNativeTransformer(LibraryIndex index, this.referenceFromIndex)
      : ffiNativeClass = index.getClass('dart:ffi', 'FfiNative'),
        nativeFunctionClass = index.getClass('dart:ffi', 'NativeFunction'),
        ffiNativeNameField =
            index.getField('dart:ffi', 'FfiNative', 'nativeName'),
        resolverField = index.getTopLevelField('dart:ffi', '_ffi_resolver'),
        asFunctionProcedure = index.getProcedure(
            'dart:ffi', 'NativeFunctionPointer', 'asFunction'),
        fromAddressInternal =
            index.getTopLevelProcedure('dart:ffi', '_fromAddress') {}

  @override
  TreeNode visitLibrary(Library node) {
    assert(currentLibrary == null);
    currentLibrary = node;
    currentLibraryIndex = referenceFromIndex?.lookupLibrary(node);
    // We only transform top-level, external procedures:
    transformList(node.procedures, node);
    currentLibrary = null;
    return node;
  }

  InstanceConstant? _tryGetFfiNativeAnnotation(Member node) {
    for (final Expression annotation in node.annotations) {
      if (annotation is ConstantExpression) {
        if (annotation.constant is InstanceConstant) {
          final instConst = annotation.constant as InstanceConstant;
          if (instConst.classNode == ffiNativeClass) {
            return instConst;
          }
        }
      }
    }
    return null;
  }

  // Transform:
  //   @FfiNative<Double Function(Double)>('Math_sqrt')
  //   external double _sqrt(double x);
  //
  // Into:
  //   final _@FfiNative_Math_sqrt =
  //       Pointer<NativeFunction<Double Function(Double)>>
  //           .fromAddress(_ffi_resolver('dart:math', 'Math_sqrt'))
  //           .asFunction<double Function(double)>();
  //   double _sqrt(double x) => _@FfiNative_Math_sqrt(x);
  Statement transformFfiNative(
      Procedure node, InstanceConstant annotationConst) {
    assert(currentLibrary != null);
    final params = node.function.positionalParameters;
    final functionName = annotationConst
        .fieldValues[ffiNativeNameField.getterReference] as StringConstant;

    // double Function(double)
    final DartType dartType =
        node.function.computeThisFunctionType(Nullability.nonNullable);
    // Double Function(Double)
    final nativeType = annotationConst.typeArguments[0];
    // InterfaceType(NativeFunction<Double Function(Double)>*)
    final DartType nativeInterfaceType =
        InterfaceType(nativeFunctionClass, Nullability.legacy, [nativeType]);

    // TODO(dartbug.com/31579): Add `..fileOffset`s once we can handle these in
    // patch files.

    // _ffi_resolver('dart:math', 'Math_sqrt')
    final resolverInvocation = MethodInvocation(
        StaticGet(resolverField),
        Name('call'),
        Arguments([
          ConstantExpression(
              StringConstant(currentLibrary!.importUri.toString())),
          ConstantExpression(functionName)
        ]));

    // _fromAddress<NativeFunction<Double Function(Double)>>(...)
    final fromAddressInvocation = StaticInvocation(fromAddressInternal,
        Arguments([resolverInvocation], types: [nativeInterfaceType]));

    // NativeFunctionPointer.asFunction
    //     <Double Function(Double), double Function(double)>(...)
    final asFunctionInvocation = StaticInvocation(asFunctionProcedure,
        Arguments([fromAddressInvocation], types: [nativeType, dartType]));

    // final _@FfiNative_Math_sqrt = ...
    final fieldName = Name('_@FfiNative_${functionName.value}', currentLibrary);
    final funcPtrField = Field.immutable(fieldName,
        type: dartType,
        initializer: asFunctionInvocation,
        isStatic: true,
        isFinal: true,
        fileUri: currentLibrary!.fileUri,
        getterReference: currentLibraryIndex?.lookupGetterReference(fieldName));
    currentLibrary!.addField(funcPtrField);

    // _@FfiNative_Math_sqrt(x)
    final callFuncPtrInvocation = MethodInvocation(StaticGet(funcPtrField),
        Name('call'), Arguments(params.map((p) => VariableGet(p)).toList()));

    return ReturnStatement(callFuncPtrInvocation);
  }

  @override
  visitProcedure(Procedure node) {
    // Only transform functions that are external and have FfiNative annotation:
    //   @FfiNative<Double Function(Double)>('Math_sqrt')
    //   external double _sqrt(double x);
    if (!node.isExternal) {
      return node;
    }
    InstanceConstant? ffiNativeAnnotation = _tryGetFfiNativeAnnotation(node);
    if (ffiNativeAnnotation == null) {
      return node;
    }

    node.isExternal = false;
    node.function.body = transformFfiNative(node, ffiNativeAnnotation)
      ..parent = node.function;

    return node;
  }
}
