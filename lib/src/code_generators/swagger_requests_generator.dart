import 'dart:convert';

import 'package:swagger_dart_code_generator/src/extensions/file_name_extensions.dart';
import 'package:swagger_dart_code_generator/src/models/generator_options.dart';
import 'package:swagger_dart_code_generator/src/code_generators/swagger_models_generator.dart';
import 'package:swagger_dart_code_generator/src/extensions/string_extension.dart';
import 'package:swagger_dart_code_generator/src/swagger_models/requests/swagger_request.dart';
import 'package:swagger_dart_code_generator/src/swagger_models/requests/swagger_request_parameter.dart';
import 'package:swagger_dart_code_generator/src/swagger_models/responses/swagger_response.dart';
import 'package:swagger_dart_code_generator/src/swagger_models/swagger_root.dart';
import 'package:recase/recase.dart';
import 'package:swagger_dart_code_generator/src/exception_words.dart';
import 'package:collection/collection.dart';

class RequestWithPath {
  final String path;
  final SwaggerRequest request;
  RequestWithPath(this.request, this.path);
}

abstract class SwaggerRequestsGenerator {
  static const String defaultBodyParameter = 'Object';
  static const String requestTypeOptions = 'options';
  static final List<String> successResponseCodes = [
    '200',
    '201',
  ];
  static final List<String> successDescriptions = [
    'Success',
    'OK',
    'default response'
  ];

  String generate(
      String code, String className, String fileName, GeneratorOptions options);

  String generateFileContent(String classContent, String chopperClientContent,
      String allMethodsContent) {
    final result = '''
$classContent
{
$chopperClientContent
$allMethodsContent
}''';

    return result;
  }

  String getFileContent(
    SwaggerRoot swaggerRoot,
    String dartCode,
    String _,
    String fileName,
    GeneratorOptions options,
    bool hasModels,
    List<String> allEnumNames,
    List<String> dynamicResponses,
    Map<String, String> basicTypesMap,
  ) {
    final tagToRequestWithPath = <String, List<RequestWithPath>>{};
    for (final path in swaggerRoot.paths) {
      for (final request in path.requests) {
        for (final tag in request.tags) {
          tagToRequestWithPath[tag] ??= [];
          request.parameters.add(SwaggerRequestParameter(
            inParameter: 'header',
            isRequired: false,
            description: 'OTP Code',
            type: 'string',
            name: 'Grpc-Metadata-X-OTP',
          ));
          request.parameters.add(SwaggerRequestParameter(
            inParameter: 'header',
            isRequired: false,
            description: 'Auth Token',
            type: 'string',
            name: 'Grpc-Metadata-Authorization',
          ));
          tagToRequestWithPath[tag]!.add(RequestWithPath(request, path.path));
        }
      }
    }
    var concatedResult = '';
    for (final service in tagToRequestWithPath.entries) {
      final className = getClassNameFromFileName(service.key);
      final root = SwaggerRoot(
        basePath: swaggerRoot.basePath,
        components: swaggerRoot.components,
        host: swaggerRoot.host,
        info: swaggerRoot.info,
        parameters: swaggerRoot.parameters,
        tags: swaggerRoot.tags,
        schemes: swaggerRoot.schemes,
        paths: swaggerRoot.paths,
      );
      final classContent =
          getRequestClassContent(root.host, className, fileName, options);
      final chopperClientContent = getChopperClientContent(
          '${formatServiceName(className)}',
          root.host,
          root.basePath,
          options,
          hasModels);

      final allMethodsContent = getAllMethodsContent(
        root,
        dartCode,
        options,
        allEnumNames,
        dynamicResponses,
        service.value,
        basicTypesMap,
        excludeFromMethodName: 'api/${service.key}',
      );

      final result = generateFileContent(
          classContent, chopperClientContent, allMethodsContent);

      concatedResult += result;
    }

    final services = tagToRequestWithPath.keys
        .map((e) => getClassNameFromFileName(e))
        .toList();

    final getters = services
        .map((e) =>
            '${formatServiceName(e)} get ${e.camelCase} => getService<${formatServiceName(e)}>();')
        .join('\n');
    concatedResult += '''
extension ${getClassNameFromFileName(fileName)}SwaggerExtension on ChopperClient {
  $getters
}    
''';

    final createServiceLines = services
        .map((e) => '${formatServiceName(e)}.createService(),')
        .join('\n');

    concatedResult += '''
List<ChopperService> get ${getClassNameFromFileName(fileName).camelCase}Services => [
  $createServiceLines
];''';

    return concatedResult;
  }

  static List<String> getAllDynamicResponses(String dartCode) {
    final dynamic map = jsonDecode(dartCode);

    final components = map['components'] as Map<String, dynamic>?;
    final responses = components == null
        ? null
        : components['responses'] as Map<String, dynamic>?;

    if (responses == null) {
      return [];
    }

    var results = <String>[];

    responses.keys.forEach((key) {
      final response = responses[key] as Map<String, dynamic>?;

      final content = response == null
          ? null
          : response['content'] as Map<String, dynamic>?;

      if (content != null && content.entries.length > 1) {
        results.add(key.capitalize);
      }
    });

    return results;
  }

  String getAllMethodsContent(
    SwaggerRoot swaggerRoot,
    String dartCode,
    GeneratorOptions options,
    List<String> allEnumNames,
    List<String> dynamicResponses,
    List<RequestWithPath> requests,
    Map<String, String> basicTypesMap, {
    String? excludeFromMethodName,
  }) {
    final methods = StringBuffer();

    final dynamic map = dartCode.isNotEmpty ? jsonDecode(dartCode) : {};
    final components = map['components'] as Map<String, dynamic>?;
    final requestBodies =
        components == null ? null : components['requestBodies'];

    requests.forEach((r) {
      final path = r.path;
      final swaggerRequest = r.request;
      if (options.excludePaths.isNotEmpty &&
          options.excludePaths
              .any((exclPath) => RegExp(exclPath).hasMatch(path))) {
        return;
      }

      if (options.includePaths.isNotEmpty &&
          !options.includePaths
              .any((inclPath) => RegExp(inclPath).hasMatch(path))) {
        return;
      }

      if (swaggerRequest.type.toLowerCase() == requestTypeOptions) {
        return;
      }

      swaggerRequest.parameters = swaggerRequest.parameters
          .where((element) => element.inParameter.isNotEmpty)
          .toList()
          .asMap()
          .map(
            (key, value) => MapEntry(
              '${value.name.toLowerCase()}@#@${value.type.toLowerCase()}',
              value,
            ),
          )
          .values
          .toList();

      final hasFormData = swaggerRequest.parameters.any(
          (SwaggerRequestParameter swaggerRequestParameter) =>
              swaggerRequestParameter.inParameter == 'formData');

      String methodName;
      if (options.usePathForRequestNames ||
          swaggerRequest.operationId.isEmpty) {
        var correctPath = path;
        if (excludeFromMethodName != null) {
          correctPath = correctPath.replaceFirst(excludeFromMethodName, '');
        }
        methodName = SwaggerModelsGenerator.generateRequestName(
            correctPath, swaggerRequest.type);
      } else {
        methodName = swaggerRequest.operationId.camelCase;
      }

      if (swaggerRequest.requestBody?.content != null &&
          swaggerRequest.parameters
              .every((parameter) => parameter.inParameter != 'body')) {
        final additionalParameter = swaggerRequest.requestBody?.content;
        swaggerRequest.parameters.add(SwaggerRequestParameter(
            inParameter: 'body',
            name: 'body',
            isRequired: true,
            type: _getBodyParameterType(additionalParameter, options),
            ref: additionalParameter?.ref ??
                additionalParameter?.items?.ref ??
                ''));
      }

      final requestBody = swaggerRequest.requestBody?.ref;
      if (requestBody?.isNotEmpty == true) {
        var requestBodyType = requestBody!.split('/').last;

        final bodySchema =
            requestBodies == null ? null : requestBodies[requestBodyType];

        if (bodySchema?.isNotEmpty == true) {
          final content = bodySchema['content'] as Map?;
          final firstContent =
              content == null ? null : content[content.keys.first];
          final schema = firstContent['schema'] as Map;
          if (schema.containsKey('\$ref')) {
            requestBodyType = schema['\$ref'].split('/').last.toString();
          }
        }

        swaggerRequest.parameters.add(SwaggerRequestParameter(
            inParameter: 'body',
            name: 'body',
            isRequired: true,
            type: requestBodyType.capitalize));
      }

      if (swaggerRequest.parameters
              .every((parameter) => parameter.inParameter != 'body') &&
          (swaggerRequest.type.toLowerCase() == 'post' ||
              swaggerRequest.type.toLowerCase() == 'put')) {
        swaggerRequest.parameters.add(SwaggerRequestParameter(
            inParameter: 'body', name: 'body', isRequired: true));
      }

      final allParametersContent = getAllParametersContent(
        listParameters: swaggerRequest.parameters,
        ignoreHeaders: options.ignoreHeaders,
        path: path,
        allEnumNames: allEnumNames,
        requestType: swaggerRequest.type,
        useRequiredAttribute: options.useRequiredAttributeForHeaders,
        options: options,
      );

      final hasEnums = swaggerRequest.parameters.any((parameter) =>
          parameter.items?.enumValues.isNotEmpty == true ||
          parameter.item?.enumValues.isNotEmpty == true ||
          parameter.schema?.enumValues.isNotEmpty == true ||
          allEnumNames.contains(
              'enums.${parameter.ref.isEmpty ? "" : parameter.ref.split("/").last.pascalCase}'));

      final enumInBodyName = swaggerRequest.parameters.firstWhereOrNull(
        (parameter) =>
            parameter.inParameter == 'body' &&
            (parameter.items?.enumValues.isNotEmpty == true ||
                parameter.item?.enumValues.isNotEmpty == true ||
                parameter.schema?.enumValues.isNotEmpty == true),
      );

      final parameterCommentsForMethod =
          getParameterCommentsForMethod(swaggerRequest.parameters, options);

      final returnTypeName = getReturnTypeName(
        swaggerRequest.responses,
        path,
        swaggerRequest.type,
        options.responseOverrideValueMap,
        dynamicResponses,
        basicTypesMap,
        options,
      );

      final generatedMethod = getMethodContent(
          summary: swaggerRequest.summary,
          typeRequest: swaggerRequest.type,
          methodName: methodName,
          parametersContent: allParametersContent,
          parametersComments: parameterCommentsForMethod,
          requestPath: path,
          hasFormData: hasFormData,
          returnType: returnTypeName,
          hasEnums: hasEnums,
          enumInBodyName: enumInBodyName?.name ?? '',
          ignoreHeaders: options.ignoreHeaders,
          allEnumNames: allEnumNames,
          parameters: swaggerRequest.parameters);

      methods.writeln(generatedMethod);
    });

    return methods.toString();
  }

  String _getBodyParameterType(
      RequestContent? content, GeneratorOptions options) {
    if (content == null) {
      return 'Object';
    }

    if (content.type.toLowerCase() == 'array') {
      if (content.items?.ref == null || content.items!.ref.isEmpty) {
        return 'Object';
      }

      final type =
          content.items!.ref.split('/').last.capitalize + options.modelPostfix;

      return 'List<$type>';
    }

    return content.type;
  }

  String getParameterCommentsForMethod(
          List<SwaggerRequestParameter> listParameters,
          GeneratorOptions options) =>
      listParameters
          .map((SwaggerRequestParameter parameter) => createSummaryParameters(
              parameter.name,
              parameter.description,
              parameter.inParameter,
              options))
          .where((String element) => element.isNotEmpty)
          .join('\n');

  String createSummaryParameters(
      String parameterName,
      String parameterDescription,
      String inParameter,
      GeneratorOptions options) {
    if (inParameter == 'header' && options.ignoreHeaders) {
      return '';
    }
    if (parameterDescription.isNotEmpty) {
      parameterDescription =
          parameterDescription.replaceAll(RegExp(r'\n|\r|\t'), ' ');
    } else {
      parameterDescription = '';
    }

    final comments = '''\t///@param $parameterName $parameterDescription''';
    return comments;
  }

  String abbreviationToCamelCase(String word) {
    var isLastLetterUpper = false;
    final result = word.split('').map((String e) {
      if (e.isUpper && !isLastLetterUpper) {
        isLastLetterUpper = true;
        return e;
      }

      isLastLetterUpper = e.isUpper;
      return e.toLowerCase();
    }).join();

    return result;
  }

  String generatePublicMethod(
      String methodName,
      String returnTypeString,
      String parametersPart,
      String requestType,
      String requestPath,
      bool ignoreHeaders,
      List<SwaggerRequestParameter> parameters,
      List<String> allEnumNames) {
    final filteredParameters = parameters
        .where((parameter) =>
            ignoreHeaders ? parameter.inParameter != 'header' : true)
        .where((parameter) => parameter.inParameter != 'cookie')
        .toList();

    final enumParametersNames = parameters
        .where((parameter) => (parameter.items?.enumValues.isNotEmpty == true ||
            parameter.item?.enumValues.isNotEmpty == true ||
            parameter.schema?.enumValues.isNotEmpty == true ||
            allEnumNames.contains(
                'enums.${parameter.ref.isNotEmpty ? parameter.ref.split("/").last.pascalCase : ""}')))
        .map((e) => e.name)
        .toList();

    final newParametersPart = parametersPart
        .replaceAll(RegExp(r'@\w+\(\)'), '')
        .replaceAll(RegExp(r"@\w+\(\'\w+\'\)"), '')
        .trim();

    final result =
        '''\tFuture<Response$returnTypeString> ${abbreviationToCamelCase(methodName.camelCase)}($newParametersPart){
          return _${methodName.camelCase}(${filteredParameters.map((e) => "${validateParameterName(e.name)} : ${enumParametersNames.contains(e.name) ? getEnumParameter(requestPath, requestType, e.name, filteredParameters, e.ref) : validateParameterName(e.name)}").join(', ')});
          }'''
            .replaceAll('@required', '');

    return result;
  }

  String getEnumParameter(String requestPath, String requestType,
      String parameterName, List<SwaggerRequestParameter> parameters,
      [String ref = '']) {
    final enumListParametersNames = parameters
        .where((parameter) =>
            parameter.type == 'array' &&
            (parameter.items?.enumValues.isNotEmpty == true ||
                parameter.item?.enumValues.isNotEmpty == true ||
                parameter.schema?.enumValues.isNotEmpty == true))
        .map((e) => e.name)
        .toList();

    parameterName = validateParameterName(parameterName);

    final mapName = getMapName(requestPath, requestType, parameterName, ref);

    if (enumListParametersNames.contains(parameterName)) {
      return '$parameterName!.map((element) => $mapName[element]).toList()';
    }

    return '$mapName[$parameterName]';
  }

  String validateParameterName(String parameterName) {
    if (parameterName.isEmpty) {
      return parameterName;
    }

    parameterName = parameterName.replaceAll(',', '');
    parameterName = parameterName.split('.').last;

    var name = <String>[];
    exceptionWords.forEach((String element) {
      if (parameterName == element) {
        final result = '\$' + parameterName;
        name.add(result);
      }
    });
    if (name.isEmpty) {
      name =
          parameterName.split('-').map((String str) => str.capitalize).toList();
      name[0] = name[0].lower;
    }

    return name.join();
  }

  String getMethodContent({
    required String summary,
    required String typeRequest,
    required String methodName,
    required String parametersContent,
    required String parametersComments,
    required String requestPath,
    required bool hasFormData,
    required String returnType,
    required bool hasEnums,
    required String enumInBodyName,
    required bool ignoreHeaders,
    required List<SwaggerRequestParameter> parameters,
    required List<String> allEnumNames,
  }) {
    var typeReq = typeRequest.capitalize + "(path: '$requestPath')";
    if (hasFormData) {
      typeReq +=
          '\n  @FactoryConverter(request: FormUrlEncodedConverter.requestFactory)';
    }

    if (returnType.isNotEmpty && returnType != 'num') {
      returnType = returnType.pascalCase;
    }

    final returnTypeString = returnType.isNotEmpty ? '<$returnType>' : '';
    var parametersPart =
        parametersContent.isEmpty ? '' : '{$parametersContent}';

    if (summary.isNotEmpty) {
      summary = summary.replaceAll(RegExp(r'\n|\r|\t'), ' ');
    }

    //methodName = abbreviationToCamelCase(methodName.camelCase);
    var publicMethod = '';

    if (hasEnums) {
      publicMethod = generatePublicMethod(
              methodName,
              returnTypeString,
              parametersPart,
              typeRequest,
              requestPath,
              ignoreHeaders,
              parameters,
              allEnumNames)
          .trim();

      allEnumNames.forEach((element) {
        parametersPart = parametersPart.replaceFirst('$element? ', 'String? ');
        parametersPart = parametersPart.replaceFirst('$element>?', 'String?>?');
      });

      parametersPart = parametersPart
          .replaceAll('enums.', '')
          .replaceAll('List<enums.', 'List<');

      methodName = '_$methodName';
    }

    final generatedMethod = """
\t///$summary  ${parametersComments.isNotEmpty ? """\n$parametersComments""" : ''}
\t$publicMethod

\t@$typeReq
\tFuture<chopper.Response$returnTypeString> $methodName($parametersPart);
""";

    return generatedMethod;
  }

  String validateParameterType(String parameterName) {
    var isEnum = false;

    if (parameterName.isEmpty) {
      return 'dynamic';
    }

    if (parameterName.startsWith('enums.')) {
      isEnum = true;
      parameterName = parameterName.replaceFirst('enums.', '');
    }

    final result = parameterName
        .split('-')
        .map((String str) => str.capitalize)
        .toList()
        .join();

    if (isEnum) {
      return 'enums.$result';
    } else {
      return result;
    }
  }

  String getParameterTypeName(String parameter, [String itemsType = '']) {
    switch (parameter) {
      case 'integer':
      case 'int':
        return 'int';
      case 'boolean':
        return 'bool';
      case 'string':
        return 'String';
      case 'array':
        return 'List<${getParameterTypeName(itemsType)}>';
      case 'file':
        return 'List<int>';
      case 'number':
        return 'num';
      case 'object':
        return 'Object';
      default:
        return validateParameterType(parameter);
    }
  }

  String getBodyParameter(
    SwaggerRequestParameter parameter,
    String path,
    String requestType,
    List<String> allEnumNames,
    GeneratorOptions options,
  ) {
    String parameterType;
    if (parameter.type.isNotEmpty) {
      parameterType = parameter.type;
    } else if (parameter.schema?.enumValues.isNotEmpty ?? false) {
      parameterType =
          'enums.${SwaggerModelsGenerator.generateRequestEnumName(path, requestType, parameter.name)}';
    } else if (parameter.schema?.originalRef.isNotEmpty ?? false) {
      parameterType = SwaggerModelsGenerator.getValidatedClassName(
          parameter.schema!.originalRef.toString());
    } else if (parameter.ref.isNotEmpty) {
      parameterType = parameter.ref.split('/').last;
      parameterType = parameterType.split('_').map((e) => e.capitalize).join();

      if (allEnumNames.contains('enums.$parameterType')) {
        parameterType = 'enums.$parameterType';
      } else {
        parameterType += options.modelPostfix;
      }

      if (parameter.type == 'array') {
        parameterType = 'List<$parameterType>';
      }
    } else if (parameter.schema?.ref.isNotEmpty ?? false) {
      parameterType =
          parameter.schema!.ref.split('/').last + options.modelPostfix;
    } else {
      parameterType = defaultBodyParameter;
    }

    parameterType = validateParameterType(parameterType);

    return "@${parameter.inParameter.capitalize}() ${parameter.isRequired ? "@required" : ""} $parameterType? ${validateParameterName(parameter.name)}";
  }

  String getDefaultParameter(
      SwaggerRequestParameter parameter, String path, String requestType) {
    String parameterType;
    if (parameter.schema?.enumValues.isNotEmpty ?? false) {
      parameterType =
          'enums.${SwaggerModelsGenerator.generateRequestEnumName(path, requestType, parameter.name)}';
    } else if (parameter.items?.enumValues.isNotEmpty ?? false) {
      final typeName =
          'enums.${SwaggerModelsGenerator.generateRequestEnumName(path, requestType, parameter.name)}';
      parameterType = 'List<$typeName>';
    } else {
      final neededType = parameter.type.isNotEmpty
          ? parameter.type
          : parameter.schema?.type ?? 'Object';

      parameterType =
          getParameterTypeName(neededType, parameter.items?.type ?? '');
    }

    return "@${parameter.inParameter.capitalize}('${parameter.name}') ${parameter.isRequired ? "@required" : ""} $parameterType? ${validateParameterName(parameter.name)}";
  }

  String getParameterContent({
    required SwaggerRequestParameter parameter,
    required bool ignoreHeaders,
    required String requestType,
    required String path,
    required List<String> allEnumNames,
    required bool useRequiredAttribute,
    required GeneratorOptions options,
  }) {
    final parameterType = validateParameterType(parameter.name);
    switch (parameter.inParameter) {
      case 'body':
        return getBodyParameter(
          parameter,
          path,
          requestType,
          allEnumNames,
          options,
        );
      case 'formData':
        final isEnum = parameter.schema?.enumValues.isNotEmpty ?? false;

        return "@Field('${parameter.name}') ${parameter.isRequired ? "@required" : ""} ${isEnum ? 'enums.$parameterType?' : getParameterTypeName(parameter.type)}? ${validateParameterName(parameter.name)}";
      case 'header':
        final needRequiredAttribute =
            parameter.isRequired && useRequiredAttribute;

        final defaultValue = options.defaultHeaderValuesMap.firstWhereOrNull(
            (element) =>
                element.headerName.toLowerCase() ==
                parameter.name.toLowerCase());

        final defaultValuePart =
            defaultValue == null ? '' : ' = \'${defaultValue.defaultValue}\'';

        return ignoreHeaders
            ? ''
            : "@Header('${parameter.name}') ${needRequiredAttribute ? "required" : ""} String? ${validateParameterName(parameter.name)}$defaultValuePart";
      case 'cookie':
        return '';
      default:
        return getDefaultParameter(parameter, path, requestType);
    }
  }

  String getChopperClientContent(String className, String host, String basePath,
      GeneratorOptions options, bool hadModels) {
    final baseUrlString = options.withBaseUrl
        ? "baseUrl:  'https://$host$basePath'"
        : '/*baseUrl: YOUR_BASE_URL*/';

    final converterString =
        options.withBaseUrl && options.withConverter && hadModels
            ? 'converter: JsonSerializableConverter(),'
            : 'converter: chopper.JsonConverter(),';

    final generatedChopperClient = '''
  static $className createService([ChopperClient? client]) {
    if(client!=null){
      return _\$$className(client);
    }

    final newClient = ChopperClient(
      services: [_\$$className()],
      $converterString
      $baseUrlString);
    return _\$$className(newClient);
  }

''';
    return generatedChopperClient;
  }

  String getRequestClassContent(String host, String className, String fileName,
      GeneratorOptions options) {
    final classWithoutChopper = '''
@ChopperApi()
abstract class ${formatServiceName(className)} extends ChopperService''';

    return classWithoutChopper;
  }

  String getAllParametersContent({
    required List<SwaggerRequestParameter> listParameters,
    required bool ignoreHeaders,
    required String path,
    required String requestType,
    required List<String> allEnumNames,
    required bool useRequiredAttribute,
    required GeneratorOptions options,
  }) {
    return listParameters
        .map((SwaggerRequestParameter parameter) => getParameterContent(
              parameter: parameter,
              ignoreHeaders: ignoreHeaders,
              path: path,
              allEnumNames: allEnumNames,
              requestType: requestType,
              useRequiredAttribute: useRequiredAttribute,
              options: options,
            ))
        .where((String element) => element.isNotEmpty)
        .join(', ');
  }

  SwaggerResponse? getSuccessedResponse(List<SwaggerResponse> responses) {
    return responses.firstWhereOrNull(
      (SwaggerResponse response) =>
          successDescriptions.contains(response.description) ||
          successResponseCodes.contains(response.code),
    );
  }

  String getResponseModelName(
      String url, String methodName, String modelPostfix) {
    final urlString = url.split('/').map((e) => e.pascalCase).join();
    final methodNamePart = methodName.pascalCase;
    final responseType = SwaggerModelsGenerator.getValidatedClassName(
        '$urlString$methodNamePart\$Response$modelPostfix');

    return responseType;
  }

  String getReturnTypeName(
    List<SwaggerResponse> responses,
    String url,
    String methodName,
    List<ResponseOverrideValueMap> overriddenRequests,
    List<String> dynamicResponses,
    Map<String, String> basicTypesMap,
    GeneratorOptions options,
  ) {
    if (overriddenRequests
            .any((ResponseOverrideValueMap element) => element.url == url) ==
        true) {
      final overriddenResponse = overriddenRequests
          .firstWhere((ResponseOverrideValueMap element) => element.url == url);

      if (overriddenResponse.method == methodName) {
        return overriddenResponse.overriddenValue;
      }
    }

    final neededResponse = getSuccessedResponse(responses);

    if (neededResponse == null) {
      return '';
    }

    if (neededResponse.schema?.type == 'object' &&
        neededResponse.schema?.properties.isNotEmpty == true) {
      return getResponseModelName(url, methodName, options.modelPostfix);
    }

    if (neededResponse.schema?.type.isNotEmpty ?? false) {
      var param = neededResponse.schema?.items?.originalRef.isNotEmpty == true
          ? neededResponse.schema?.items?.originalRef
          : neededResponse.schema?.items?.type ?? '';

      if (param!.isEmpty &&
          neededResponse.schema?.items?.ref.split('/').lastOrNull != null) {
        param = neededResponse.schema!.items!.ref.split('/').last +
            options.modelPostfix;
      }

      return getParameterTypeName(neededResponse.schema?.type ?? '', param);
    }

    if (neededResponse.schema?.ref.isNotEmpty ?? false) {
      return neededResponse.schema!.ref.split('/').last + options.modelPostfix;
    }

    if (neededResponse.ref.isNotEmpty) {
      final ref = neededResponse.ref.split('/').last.capitalize;

      if (neededResponse.ref.contains('/responses') &&
          dynamicResponses.contains(ref)) {
        return 'object';
      } else {
        return ref + options.modelPostfix;
      }
    }

    if (neededResponse.schema?.originalRef.isNotEmpty ?? false) {
      return neededResponse.schema?.originalRef ?? '';
    }

    if (neededResponse.content.isNotEmpty == true &&
        neededResponse.content.isNotEmpty) {
      if (neededResponse.content.first.ref.isNotEmpty) {
        var type = neededResponse.content.first.ref.split('/').last;

        if (!basicTypesMap.containsKey(type)) {
          type += options.modelPostfix;
        }

        if (basicTypesMap.containsKey(type.toString())) {
          return basicTypesMap[type] ?? '';
        }
        return type;
      }
      if (neededResponse.content.first.responseType.isNotEmpty) {
        final ref = neededResponse.content.firstOrNull?.items?.ref
            .split('/')
            .lastOrNull;
        if (ref?.isNotEmpty == true) {
          return getParameterTypeName(neededResponse.content.first.responseType,
              ref! + options.modelPostfix);
        }
        return getParameterTypeName(neededResponse.content.first.responseType,
            neededResponse.schema?.items?.originalRef ?? '');
      }
    }

    return '';
  }

  String getMapName(
      String path, String requestType, String parameterName, String ref) {
    if (ref.isNotEmpty) {
      return 'enums.\$${ref.split('/').lastOrNull?.pascalCase}Map';
    }

    final enumName = SwaggerModelsGenerator.generateRequestEnumName(
        path, requestType, parameterName);

    return 'enums.\$${enumName}Map';
  }
}
