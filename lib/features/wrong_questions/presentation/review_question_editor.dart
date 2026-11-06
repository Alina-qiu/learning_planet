import 'package:flutter/material.dart';
import 'dart:typed_data';
import '../domain/pinyin_import.dart';
import '../domain/error_reason.dart';
import '../domain/ocr_fields.dart';
import '../../ai/presentation/ai_analysis_screen.dart';

class ReviewQuestionEditor extends StatefulWidget {
  const ReviewQuestionEditor({
    required this.pinyin,
    this.initial,
    this.ocrResult,
    this.fromImage = false,
    this.originalImage,
    this.processedImage,
    this.fromQuestion = false,
    this.onDraftChanged,
    this.familyId,
    this.childId,
    this.collectErrorReasons = true,
    this.childSubmission = false,
    this.imageUrls = const [],
    super.key,
  });
  final bool pinyin;
  final bool collectErrorReasons;
  final bool childSubmission;
  final List<String> imageUrls;
  final String? familyId, childId;
  final Map<String, dynamic>? initial;
  final Map<String, dynamic>? ocrResult;
  final bool fromImage;
  final bool fromQuestion;
  final ValueChanged<Map<String, dynamic>>? onDraftChanged;
  final Uint8List? originalImage, processedImage;
  @override
  State<ReviewQuestionEditor> createState() => _ReviewQuestionEditorState();
}

class _ReviewQuestionEditorState extends State<ReviewQuestionEditor> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _prompt,
      _answers,
      _context,
      _knowledge,
      _reason,
      _explanation,
      _options,
      _imageAnswer,
      _annotation;
  late final Map<String, dynamic> _rawFields;
  final _fieldConfirmed = <String>{};
  bool get _hasFields =>
      widget.fromImage && widget.ocrResult != null && !widget.pinyin;
  Map<String, TextEditingController> get _fieldControllers => {
    'prompt': _prompt,
    'options': _options,
    'answer': _imageAnswer,
    'annotation': _annotation,
  };
  Map<String, dynamic> get _corrections => {
    for (final e in _fieldControllers.entries) e.key: e.value.text.trim(),
  };
  List<String> get _neededFields => ocrFieldLabels.keys
      .where(
        (key) =>
            (_rawFields[key]?['text'] as String? ?? '').trim().isNotEmpty ||
            _fieldControllers[key]!.text.trim().isNotEmpty,
      )
      .toList();
  late String _subject;
  late final Set<String> _reasonTags;
  bool _confirmed = false;
  bool _ocrConfirmed = false;
  bool _sandhi = false;
  String? _candidateHint;
  @override
  void initState() {
    super.initState();
    final row = widget.initial;
    _rawFields = _hasFields ? questionOcrFields(widget.ocrResult!) : {};
    final corrected = row?['ocr_corrections'] as Map?;
    String field(String key) =>
        corrected?[key] as String? ?? _rawFields[key]?['text'] as String? ?? '';
    _prompt = TextEditingController(
      text:
          corrected?['prompt'] as String? ??
          row?['final_text'] as String? ??
          field('prompt'),
    );
    _options = TextEditingController(
      text: corrected != null || row?['final_text'] == null
          ? field('options')
          : '',
    );
    _imageAnswer = TextEditingController(text: field('answer'));
    _annotation = TextEditingController(text: field('annotation'));
    _fieldConfirmed.addAll(
      (row?['ocr_field_confirmations'] as List? ?? [])
          .whereType<String>()
          .where(ocrFieldLabels.containsKey),
    );
    _answers = TextEditingController(
      text: (row?['answers'] as List?)?.join('\n'),
    );
    _context = TextEditingController(
      text: row?['pronunciation_context'] as String?,
    );
    _knowledge = TextEditingController(
      text: row?['knowledge_point'] as String?,
    );
    _explanation = TextEditingController(text: row?['explanation'] as String?);
    _reason = TextEditingController(text: row?['error_reason'] as String?);
    _reasonTags = questionErrorReasons(row ?? {}).toSet();
    _subject = widget.pinyin ? 'chinese' : row?['subject'] as String? ?? 'math';
    for (final controller in [
      _answers,
      _context,
      _knowledge,
      _reason,
      _explanation,
    ]) {
      controller.addListener(_draftChanged);
    }
    for (final entry in _fieldControllers.entries) {
      entry.value.addListener(() {
        if (_hasFields) {
          setState(() {
            _fieldConfirmed.remove(entry.key);
            _ocrConfirmed = false;
          });
        }
        _draftChanged();
      });
    }
    _answers.addListener(() {
      if (widget.fromImage && _ocrConfirmed) {
        setState(() => _ocrConfirmed = false);
      }
    });
  }

  void _draftChanged() => widget.onDraftChanged?.call({
    'final_text': _prompt.text,
    'answers': _answers.text.split('\n'),
    'pronunciation_context': _context.text,
    'knowledge_point': _knowledge.text,
    if (widget.collectErrorReasons) ...{
      'error_reason': _reason.text,
      if (!widget.pinyin) 'error_reason_tags': _orderedReasonTags,
    },
    'explanation': _explanation.text,
    'subject': _subject,
    if (_hasFields) ...{
      'ocr_corrections': _corrections,
      'ocr_field_confirmations': _fieldConfirmed.toList(),
    },
  });

  List<String> get _orderedReasonTags =>
      errorReasonLabels.keys.where(_reasonTags.contains).toList();

  @override
  void dispose() {
    for (final controller in [
      _prompt,
      _answers,
      _context,
      _knowledge,
      _reason,
      _explanation,
      _options,
      _imageAnswer,
      _annotation,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  String? _required(String? value) =>
      value == null || value.trim().isEmpty ? '不能为空' : null;
  Widget _fieldEvidence(String key) {
    final raw = _rawFields[key] as Map? ?? {},
        score = _rawFields[key]?['confidence'];
    final text = raw['text'] as String? ?? '';
    final needsReview = score is! num || score < 0.8;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (text.isNotEmpty)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            leading: Icon(
              needsReview ? Icons.warning_amber : Icons.text_snippet_outlined,
            ),
            title: Text('原始识别 · ${ocrFieldLabels[key]}'),
            subtitle: Text(
              score is! num
                  ? '置信度未知，请按原图核对'
                  : score < 0.8
                  ? '置信度低于80%，请逐字核对'
                  : '文字识别置信度 ${(score * 100).round()}%；字段归属仍需核对',
            ),
            children: [SelectableText(text)],
          ),
        if (_neededFields.contains(key))
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('已核对${ocrFieldLabels[key]}的文字与字段归属'),
            value: _fieldConfirmed.contains(key),
            onChanged: (checked) {
              setState(() {
                checked == true
                    ? _fieldConfirmed.add(key)
                    : _fieldConfirmed.remove(key);
                _ocrConfirmed = false;
              });
              _draftChanged();
            },
          ),
      ],
    );
  }

  Future<void> _analyze() async {
    if (_prompt.text.trim().isEmpty || _prompt.text.length > 2000) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先填写并校对题目文字')));
      return;
    }
    final input = <String, dynamic>{
      'text': _hasFields
          ? composeOcrQuestion(_corrections)
          : _prompt.text.trim(),
      'subject': _subject,
    };
    final suggestion = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) => AiAnalysisScreen(
          familyId: widget.familyId!,
          childId: widget.childId!,
          input: input,
        ),
      ),
    );
    if (!mounted ||
        suggestion == null ||
        (_hasFields ? composeOcrQuestion(_corrections) : _prompt.text.trim()) !=
            input['text'] ||
        _subject != input['subject']) {
      return;
    }
    final output = (suggestion['result'] as Map)['structured_output'] as Map;
    _knowledge.text = (output['knowledge_points'] as List).join('、');
    _reason.text = (output['error_reasons'] as List)
        .map((v) => aiReasonLabels[v])
        .join('；');
    _draftChanged();
  }

  void _suggest() {
    try {
      final suggestion = suggestPinyin(
        _prompt.text,
        _context.text,
        toneSandhi: _sandhi,
      );
      setState(() {
        _answers.text = suggestion.reading;
        _confirmed = false;
        _candidateHint = suggestion.alternatives.isEmpty
            ? '候选已填入，请按教材核对轻声及读音'
            : '多音字候选：${suggestion.alternatives.entries.map((e) => '${e.key} ${e.value.join('/')}').join('；')}';
      });
    } catch (error) {
      setState(() => _candidateHint = '$error');
    }
  }

  void _save() {
    if (!_form.currentState!.validate()) return;
    if (_prompt.text.trim().isEmpty ||
        _prompt.text.length > 2000 ||
        (widget.pinyin && _context.text.trim().isEmpty)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请填写题目或词语，以及拼音词语所需的语境')));
      return;
    }
    if (widget.fromImage && !_ocrConfirmed) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请核对题目及低置信识别文字，并勾选确认')));
      return;
    }
    if (_hasFields &&
        _neededFields.any((key) => !_fieldConfirmed.contains(key))) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请逐字段核对题干、选项、图片作答和批注，并勾选确认')),
      );
      return;
    }
    final prompt = _hasFields
        ? composeOcrQuestion(_corrections)
        : _prompt.text.trim();
    if (prompt.length > 2000) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('题干与选项合计不得超过2000字')));
      return;
    }
    if (widget.pinyin && !_confirmed) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先确认语境及标准读音')));
      return;
    }
    final answers = _answers.text
        .split('\n')
        .map((v) => v.trim())
        .where((v) => v.isNotEmpty)
        .toList();
    if ((!widget.childSubmission && answers.isEmpty) || answers.length > 5) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('标准答案须为1至5行')));
      return;
    }
    Navigator.pop(context, <String, dynamic>{
      'kind': widget.pinyin ? 'pinyin' : 'question',
      'subject': _subject,
      'prompt': prompt,
      'answers': answers,
      'context': _context.text.trim(),
      'knowledge_point': _knowledge.text.trim(),
      'explanation': _explanation.text.trim(),
      if (widget.collectErrorReasons) ...{
        'error_reason': _reason.text.trim(),
        if (!widget.pinyin) 'error_reason_tags': _orderedReasonTags,
      },
      'pronunciation_confirmed': _confirmed,
      if (widget.fromImage) 'ocr_confirmed': _ocrConfirmed,
      if (_hasFields) ...{
        'ocr_corrections': _corrections,
        'ocr_field_confirmations': _neededFields,
      },
      if (widget.initial?['content_version'] != null)
        'expected_version': widget.initial!['content_version'],
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.childSubmission
            ? '校对错题并交家长确认'
            : widget.pinyin
            ? '拼音词语配置'
            : widget.fromImage
            ? '识别校对与答案配置'
            : widget.initial?['ai_generated'] == true
            ? '审核 AI 生成题目'
            : '手工录入错题',
      ),
    ),
    body: Form(
      key: _form,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (widget.childSubmission)
            const Text('可以先留空参考答案。家长确认标准答案前，这道题不会加入奖励复习。'),
          if (widget.initial?['ai_generated'] == true)
            const Text('AI 生成题目：请核对题干、全部标准答案与解析。编辑后保留 AI 来源标记。'),
          if (widget.fromQuestion)
            const Text(
              '将当前语文错题转为拼音词条，保留原图片与历史复习快照。请提取要练习的词语并填写语境；保存后重置此条未来复习进度，不发放奖励。',
            ),
          if (widget.fromImage) ...[
            for (final url in widget.imageUrls)
              SizedBox(
                height: 240,
                child: InteractiveViewer(
                  child: Image.network(
                    url,
                    errorBuilder: (_, _, _) => const Text('图片加载失败，请返回刷新后再核对'),
                  ),
                ),
              ),
            for (final item in [widget.originalImage, widget.processedImage])
              if (item != null)
                SizedBox(
                  height: 240,
                  child: InteractiveViewer(child: Image.memory(item)),
                ),
            const Text('图片中的作答可能是错误答案，不会自动作为判题标准。请按原图核对，并由家长确认标准答案。'),
            if (_hasFields)
              const Text(
                '已按明确标签尝试区分题干、选项、作答和批注。无标签续行沿用前一字段，初始归入题干；归属不正确时请在下方字段间调整。',
              ),
            if (widget.ocrResult != null)
              ExpansionTile(
                title: const Text('原始识别结果（只读）'),
                children: [
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: SelectableText(
                      widget.ocrResult!['text'] as String? ?? '',
                    ),
                  ),
                  for (final line
                      in (widget.ocrResult!['lines'] as List? ?? []))
                    if (line['confidence'] == null ||
                        (line['confidence'] as num) < 0.8)
                      ListTile(
                        leading: const Icon(Icons.warning_amber),
                        title: Text(line['text'] as String),
                        subtitle: Text(
                          line['confidence'] == null
                              ? '置信度未知，必须核对'
                              : '置信度低于80%，必须核对',
                        ),
                      ),
                ],
              ),
          ],
          if (!widget.pinyin)
            DropdownButtonFormField<String>(
              initialValue: _subject,
              decoration: const InputDecoration(labelText: '学科'),
              items: const [
                DropdownMenuItem(value: 'math', child: Text('数学')),
                DropdownMenuItem(value: 'chinese', child: Text('语文')),
                DropdownMenuItem(value: 'english', child: Text('英语')),
              ],
              onChanged: (v) {
                setState(() => _subject = v!);
                _draftChanged();
              },
            ),
          TextFormField(
            controller: _prompt,
            onChanged: (_) {
              if (widget.pinyin) setState(() => _confirmed = false);
            },
            validator: _required,
            maxLength: 2000,
            maxLines: 3,
            decoration: InputDecoration(
              labelText: widget.pinyin ? '词语/句中词语' : '题目',
            ),
          ),
          if (_hasFields) ...[
            _fieldEvidence('prompt'),
            for (final key in ['options', 'answer', 'annotation']) ...[
              TextFormField(
                controller: _fieldControllers[key],
                maxLength: 2000,
                maxLines: 3,
                decoration: InputDecoration(
                  labelText: ocrFieldLabels[key],
                  helperText: key == 'answer'
                      ? '保留图片中的作答；不是判题标准答案'
                      : '可修正文字、移动归属或补充遗漏',
                  helperMaxLines: 4,
                ),
              ),
              _fieldEvidence(key),
            ],
          ],
          if (widget.pinyin) ...[
            TextFormField(
              controller: _context,
              onChanged: (_) => setState(() => _confirmed = false),
              validator: _required,
              decoration: const InputDecoration(labelText: '语境/例句（多音字必须明确语境）'),
            ),
            const Text(
              '按音节空格分隔，例如 zhōng guó 或 zhong1 guo2。ü可输入v或u:，轻声为5/0或不标调。',
            ),
            SwitchListTile(
              title: const Text('候选考虑“一、不”的变调'),
              value: _sandhi,
              onChanged: (value) => setState(() {
                _sandhi = value;
                _confirmed = false;
              }),
            ),
            OutlinedButton(onPressed: _suggest, child: const Text('填入本地候选读音')),
            if (_candidateHint != null) Text(_candidateHint!),
            const Text('本地词典只提供候选，不联网发送词语。轻声、变调、多音字及教材标注仍需家长审核。'),
          ],
          TextFormField(
            controller: _answers,
            onChanged: (_) {
              if (widget.pinyin) setState(() => _confirmed = false);
            },
            validator: widget.childSubmission ? null : _required,
            maxLines: 5,
            decoration: InputDecoration(
              label: Text(
                widget.childSubmission
                    ? '参考答案（可选，待家长确认）'
                    : widget.pinyin
                    ? '家长确认的标准拼音（一行一个可接受答案）'
                    : '标准答案（一行一个可接受答案）',
                maxLines: 3,
              ),
            ),
          ),
          TextFormField(
            controller: _knowledge,
            decoration: const InputDecoration(labelText: '知识点'),
          ),
          if (!widget.pinyin &&
              !widget.childSubmission &&
              widget.familyId != null &&
              widget.childId != null)
            OutlinedButton(
              onPressed: _analyze,
              child: const Text('AI 分类建议（家长审核）'),
            ),
          TextFormField(
            controller: _explanation,
            maxLines: 3,
            decoration: const InputDecoration(
              label: Text('答案解析（提交后展示）', maxLines: 3),
            ),
          ),
          if (widget.collectErrorReasons) ...[
            if (!widget.pinyin) ...[
              const Text('错误原因标签（可多选）'),
              const Text('核对实际作答后选择，也可以暂不设置。AI 候选和原有备注不会自动归类。'),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final entry in errorReasonLabels.entries)
                    FilterChip(
                      label: Text(entry.value),
                      selected: _reasonTags.contains(entry.key),
                      onSelected: (selected) {
                        setState(() {
                          if (selected) {
                            _reasonTags.add(entry.key);
                          } else {
                            _reasonTags.remove(entry.key);
                          }
                        });
                        _draftChanged();
                      },
                    ),
                ],
              ),
            ],
            TextFormField(
              controller: _reason,
              maxLength: 500,
              decoration: const InputDecoration(labelText: '错误原因备注（可选）'),
            ),
          ],
          if (widget.pinyin)
            CheckboxListTile(
              value: _confirmed,
              onChanged: (v) {
                setState(() => _confirmed = v!);
                ScaffoldMessenger.of(context).hideCurrentSnackBar();
              },
              title: const Text('我已根据语境确认标准读音，不接受未经确认的多音字猜测'),
            ),
          if (widget.fromImage)
            CheckboxListTile(
              value: _ocrConfirmed,
              onChanged: (value) {
                setState(() => _ocrConfirmed = value!);
                ScaffoldMessenger.of(context).hideCurrentSnackBar();
              },
              title: Text(
                widget.childSubmission
                    ? '我已核对原图和所有题目文字（含低置信/未知置信内容）；标准答案交给家长确认'
                    : '我已逐项核对原图、所有题目文字（含低置信/未知置信内容）及标准答案',
              ),
            ),
          FilledButton(
            onPressed: _save,
            child: Text(widget.childSubmission ? '保存给家长确认' : '保存'),
          ),
        ],
      ),
    ),
  );
}
