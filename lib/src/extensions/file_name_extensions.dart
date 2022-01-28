import 'package:swagger_dart_code_generator/src/extensions/string_extension.dart';

String getClassNameFromFileName(String file) {
  final name = file.split('.').first.replaceAll('-', '_');
  final result = name.split('_').map((String e) => e.capitalize);
  return result.join();
}

String formatServiceName(String serviceNameFromSwagger) {
  if (serviceNameFromSwagger.endsWith('Service')) return serviceNameFromSwagger;
  return '${serviceNameFromSwagger}Service';
}

String getFileNameWithoutExtension(String file) {
  return file.split('.').first;
}
