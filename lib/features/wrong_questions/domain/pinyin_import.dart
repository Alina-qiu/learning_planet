import 'dart:convert';
import 'package:pinyin_pro_flutter/pinyin_pro_flutter.dart' as dictionary;

const pinyinImportTemplate =
    '词语,拼音,语境,知识点\n银行,yín háng,我去银行存钱,多音字\n妈妈,mā ma,妈妈回家了,轻声\n';
const pinyinImportMaxBytes = 256 * 1024;

class PinyinSuggestion {
  const PinyinSuggestion(this.reading, this.alternatives);
  final String reading;
  final Map<String, List<String>> alternatives;
}

/// Local dictionary candidates are never treated as confirmed answer keys.
PinyinSuggestion suggestPinyin(
  String word,
  String context, {
  bool toneSandhi = false,
}) {
  word = word.trim();
  if (!RegExp(r'^[\u3400-\u9fff〇]{1,80}$').hasMatch(word) ||
      context.length > 2000) {
    throw const FormatException('候选功能支持1至80个汉字；其他内容请手工填写读音');
  }
  // Convert the sentence when it contains the word, preserving context for polyphones.
  final source = context.contains(word) ? context : word;
  final start = source.indexOf(word);
  final converted =
      (dictionary.pinyin(
                source,
                options: dictionary.PinyinOptions(
                  returnType: dictionary.PinyinReturnType.array,
                  toneSandhi: toneSandhi,
                ),
              )
              as List)
          .cast<String>();
  if (converted.length != source.length) {
    throw const FormatException('当前语境无法可靠对齐，请简化例句或手工填写');
  }
  final reading = converted.sublist(start, start + word.length).join(' ');
  if (RegExp(r'[\u3400-\u9fff]').hasMatch(reading)) {
    throw const FormatException('词库未覆盖部分汉字，请手工填写读音');
  }
  final readings =
      (dictionary.polyphonic(
                word,
                options: const dictionary.PolyphonicOptions(
                  returnType: dictionary.PolyphonicReturnType.array,
                ),
              )
              as List)
          .map((item) => (item as List).cast<String>())
          .toList();
  return PinyinSuggestion(reading, {
    for (var i = 0; i < word.length; i++)
      if (readings[i].length > 1) word[i]: readings[i],
  });
}

class PinyinImportRow {
  const PinyinImportRow({
    required this.word,
    required this.reading,
    required this.context,
    this.knowledge = '',
  });
  final String word, reading, context, knowledge;
  Map<String, dynamic> toConfig({required bool confirmed}) => {
    'kind': 'pinyin',
    'subject': 'chinese',
    'prompt': word.trim(),
    'answers': [reading.trim()],
    'context': context.trim(),
    'knowledge_point': knowledge.trim(),
    'pronunciation_confirmed': confirmed,
  };
}

/// UTF-8 CSV/TSV with quoted delimiters, CRLF and escaped quotes. No formula evaluation.
List<PinyinImportRow> parsePinyinImport(String input) {
  if (utf8.encode(input).length > pinyinImportMaxBytes) {
    throw const FormatException('文件不能超过256 KiB');
  }
  input = input.replaceFirst(RegExp(r'^\uFEFF'), '');
  final firstLine = input.split(RegExp(r'\r?\n')).first;
  final delimiter = firstLine.contains('\t') ? '\t' : ',';
  final records = <List<String>>[], cells = <String>[];
  var value = StringBuffer(), quoted = false, closed = false;
  void cell() {
    cells.add(value.toString());
    value = StringBuffer();
    closed = false;
  }

  void row() {
    cell();
    if (cells.any((s) => s.trim().isNotEmpty)) records.add(List.of(cells));
    cells.clear();
  }

  for (var i = 0; i < input.length; i++) {
    final char = input[i];
    if (quoted) {
      if (char == '"') {
        if (i + 1 < input.length && input[i + 1] == '"') {
          value.write('"');
          i++;
        } else {
          quoted = false;
          closed = true;
        }
      } else {
        value.write(char);
      }
    } else if (char == delimiter) {
      cell();
    } else if (char == '\r' || char == '\n') {
      if (char == '\r' && i + 1 < input.length && input[i + 1] == '\n') i++;
      row();
    } else if (char == '"' && value.isEmpty && !closed) {
      quoted = true;
    } else if (closed || char == '"') {
      throw const FormatException('引号格式错误；字段内双引号请写成两个双引号');
    } else {
      value.write(char);
    }
    if (records.length > 101) throw const FormatException('每次最多导入100条词语');
  }
  if (quoted) throw const FormatException('CSV引号未闭合');
  if (value.isNotEmpty || cells.isNotEmpty || closed) row();
  if (records.isEmpty) throw const FormatException('请先填写带表头的词库');
  final header = records.removeAt(0).map((s) => s.trim()).toList();
  if (header.join(',') != '词语,拼音,语境' && header.join(',') != '词语,拼音,语境,知识点') {
    throw const FormatException('表头应为：词语,拼音,语境,知识点（知识点列可省略）');
  }
  if (records.isEmpty || records.length > 100) {
    throw const FormatException('每次须有1至100条词语');
  }
  return [
    for (var i = 0; i < records.length; i++)
      _parseRow(records[i], header.length, i + 2),
  ];
}

PinyinImportRow _parseRow(List<String> cells, int columns, int line) {
  if (cells.length != columns) {
    throw FormatException('第$line条记录列数不符，带逗号或换行的内容需用双引号包住');
  }
  final values = cells.map((s) => s.trim()).toList();
  if (values[0].isEmpty ||
      values[0].length > 80 ||
      values[1].length > 500 ||
      values[2].length > 2000 ||
      (columns == 4 && values[3].length > 200)) {
    throw FormatException('第$line条记录超出长度限制，词语须为1至80字');
  }
  return PinyinImportRow(
    word: values[0],
    reading: values[1],
    context: values[2],
    knowledge: columns == 4 ? values[3] : '',
  );
}
