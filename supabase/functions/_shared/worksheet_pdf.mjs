import { PDFDocument, rgb } from 'pdf-lib';
import fontkit from '@pdf-lib/fontkit';

export const RENDERER_VERSION = 'a4-v2';
const MM = 72 / 25.4;
const A4 = [210 * MM, 297 * MM];
const ink = rgb(0.12, 0.15, 0.19), muted = rgb(0.45, 0.48, 0.51), rule = rgb(0.7, 0.72, 0.74);

export function validateWorksheetConfig(input = {}) {
  const config = {
    title: input.title ?? '学习星球练习卷', orientation: input.orientation ?? 'portrait',
    margin_mm: input.margin_mm ?? 12, blank_lines: input.blank_lines ?? 3,
    repeats: input.repeats ?? 1, pinyin_mode: input.pinyin_mode ?? 'word_to_pinyin',
    grid: input.grid ?? 'both', include_questions: input.include_questions ?? true,
    include_answers: input.include_answers ?? false, include_explanations: input.include_explanations ?? false,
  };
  if (typeof config.title !== 'string' || !config.title.trim() || [...config.title].length > 60 ||
      !['portrait', 'landscape'].includes(config.orientation) ||
      !Number.isInteger(config.margin_mm) || config.margin_mm < 12 || config.margin_mm > 25 ||
      !Number.isInteger(config.blank_lines) || config.blank_lines < 0 || config.blank_lines > 12 ||
      !Number.isInteger(config.repeats) || config.repeats < 1 || config.repeats > 5 ||
      !['word_to_pinyin', 'pinyin_to_word', 'mixed'].includes(config.pinyin_mode) ||
      !['four_lines', 'tianzige', 'both', 'none'].includes(config.grid) ||
      ['include_questions', 'include_answers', 'include_explanations'].some(key => typeof config[key] !== 'boolean') ||
      !config.include_questions && !config.include_answers && !config.include_explanations) {
    throw new Error('INVALID_WORKSHEET_CONFIG');
  }
  config.title = config.title.trim().normalize('NFC');
  return config;
}

export function pinyinDirection(item, index, config, seed) {
  if (config.pinyin_mode !== 'mixed') return config.pinyin_mode;
  let hash = 2166136261;
  for (const char of `${seed}:${item.question_id}:${index}`) hash = Math.imul(hash ^ char.codePointAt(0), 16777619);
  return hash & 1 ? 'word_to_pinyin' : 'pinyin_to_word';
}

export function printablePinyin(value) {
  return String(value).normalize('NFC').toLowerCase().replace(/u:/g,'ü').replace(/v/g,'ü')
    .replace(/([0-5])/g,'$1 ').trim().split(/\s+/).map(token => {
      const tone = /[0-5]$/.test(token) ? Number(token.at(-1)) : null;
      if (tone === null) return token;
      const syllable = token.slice(0,-1);
      if (tone === 0 || tone === 5) return syllable;
      let position = syllable.indexOf('a');
      if (position < 0) position = syllable.indexOf('e');
      if (position < 0 && syllable.includes('ou')) position = syllable.indexOf('o');
      if (position < 0) for (let i=0;i<syllable.length;i++) if ('aeiouü'.includes(syllable[i])) position=i;
      if (position < 0) return syllable;
      const accents = { a:'āáǎà', e:'ēéěè', i:'īíǐì', o:'ōóǒò', u:'ūúǔù', ü:'ǖǘǚǜ' };
      return syllable.slice(0,position)+accents[syllable[position]][tone-1]+syllable.slice(position+1);
    }).join(' ');
}

// Shared by Node regression tests and the Deno Edge worker. Font bytes are bundled assets.
export async function renderWorksheet(snapshot, fontBytes) {
  const config = validateWorksheetConfig(snapshot.config);
  if (!Array.isArray(snapshot.items) || snapshot.items.length < 1 || snapshot.items.length > 100) {
    throw new Error('INVALID_WORKSHEET_ITEMS');
  }
  const pdf = await PDFDocument.create();
  pdf.registerFontkit(fontkit);
  // Keep the complete fixed font: fontkit subsetting of CJK composite glyphs can
  // silently drop visible characters even when PDF text extraction succeeds.
  const font = await pdf.embedFont(fontBytes, { subset: false });
  const charset = new Set(font.getCharacterSet());
  const trace = [];
  const pageSections = [];
  const timestamp = new Date(snapshot.created_at);
  if (!Number.isFinite(timestamp.getTime())) throw new Error('INVALID_SNAPSHOT_DATE');
  pdf.setCreationDate(timestamp); pdf.setModificationDate(timestamp);
  pdf.setTitle(config.title); pdf.setAuthor('学习星球'); pdf.setCreator(RENDERER_VERSION);
  pdf.setProducer(`Learning Planet ${RENDERER_VERSION}`); pdf.setLanguage('zh-CN');
  const [width, height] = config.orientation === 'landscape' ? [...A4].reverse() : A4;
  const margin = config.margin_mm * MM, usable = width - 2 * margin, floor = margin + 25;
  let page, y, section, contentTop;
  const clean = value => {
    const result = String(value ?? '').normalize('NFC').replace(/\r\n?/g, '\n').replace(/\t/g, '    ');
    for (const char of result) {
      if (char === '\n') continue;
      if (char.codePointAt(0) < 32 || !charset.has(char.codePointAt(0))) throw new Error('UNSUPPORTED_FONT_GLYPH');
    }
    return result;
  };
  const wrap = (value, size, maxWidth = usable) => {
    const lines = [];
    for (const paragraph of clean(value).split('\n')) {
      let line = '';
      for (const char of paragraph) {
        if (line && font.widthOfTextAtSize(line + char, size) > maxWidth) { lines.push(line); line = ''; }
        line += char;
      }
      lines.push(line);
    }
    return lines;
  };
  const draw = (text, x, baseline, size = 12, color = ink) => {
    if (!text) return;
    page.drawText(text, { x, y: baseline, size, font, color });
    trace.push({ page: pdf.getPageCount(), section, text, x, baseline, size, text_width: font.widthOfTextAtSize(text, size) });
  };
  const line = (x1, y1, x2, y2, color = rule, thickness = 0.5, dashArray) => {
    page.drawLine({ start: { x: x1, y: y1 }, end: { x: x2, y: y2 }, color, thickness, dashArray });
  };
  function newPage(nextSection = section) {
    section = nextSection;
    page = pdf.addPage([width, height]);
    pageSections.push(section);
    y = height - margin - 18;
    for (const titleLine of wrap(config.title, 16, usable - 86)) { draw(titleLine, margin, y, 16); y -= 23; }
    draw(section === 'questions' ? '练习卷' : '参考答案', width - margin - 68, height - margin - 18, 11, muted);
    y -= 4;
    draw('姓名：________________    日期：________________', margin, y, 10, muted);
    y -= 14; line(margin, y, width - margin, y); y -= 25;
    contentTop = y;
  }
  const ensure = (space, continuation) => {
    if (y - space < floor) {
      newPage();
      if (continuation) { draw(continuation, margin, y, 10, muted); y -= 21; }
    }
  };
  const textBlock = (value, size = 12, color = ink, continuation) => {
    for (const text of wrap(value, size)) { ensure(21, continuation); draw(text, margin, y, size, color); y -= 21; }
  };
  const pinyinGrid = (type, continuation) => {
    ensure(34, continuation);
    if (type === 'four_lines') {
      for (let i = 0; i < 4; i++) line(margin, y - i * 7, width - margin, y - i * 7, i === 1 || i === 2 ? muted : rule);
    } else {
      const side = 28, count = Math.floor(usable / side);
      for (let cell = 0; cell < count; cell++) {
        const x = margin + cell * side;
        page.drawRectangle({ x, y: y - side, width: side, height: side, borderColor: rule, borderWidth: 0.5 });
        line(x + side / 2, y, x + side / 2, y - side, rule, 0.4, [2, 2]);
        line(x, y - side / 2, x + side, y - side / 2, rule, 0.4, [2, 2]);
      }
    }
    y -= 40;
  };
  const mixed = new Map(snapshot.items.map((item,index) => ({ item,index }))
    .filter(({item}) => item.review_kind === 'pinyin')
    .sort((a,b) => {
      const order = (entry) => {
        let hash=2166136261;
        for(const char of `${snapshot.id}:${entry.item.question_id}`) hash=Math.imul(hash^char.codePointAt(0),16777619);
        return hash>>>0;
      };
      return order(a)-order(b) || a.index-b.index;
    }).map(({index},rank) => [index,rank%2 ? 'pinyin_to_word' : 'word_to_pinyin']));
  const items = snapshot.items.map((item, index) => {
    if (typeof item.prompt !== 'string' || !item.prompt.trim() || item.prompt.length > 3000 ||
        !['question', 'pinyin'].includes(item.review_kind) ||
        !Array.isArray(item.accepted_answers) || item.accepted_answers.length < 1 || item.accepted_answers.length > 5 ||
        item.accepted_answers.some(answer => typeof answer !== 'string' || !answer.trim() || answer.length > 500) ||
        String(item.explanation ?? '').length > 3000) throw new Error('INVALID_WORKSHEET_ITEMS');
    return { ...item, direction: config.pinyin_mode === 'mixed' ? mixed.get(index) : pinyinDirection(item, index, config, snapshot.id) };
  });
  if (config.include_questions) {
    newPage('questions');
    for (const [index, item] of items.entries()) {
      const prompt = item.review_kind !== 'pinyin' ? item.prompt : item.direction === 'word_to_pinyin'
        ? `给词语写拼音：${item.prompt}` : `看拼音写词语：${printablePinyin(item.accepted_answers[0])}`;
      const context = item.review_kind === 'pinyin' && item.pronunciation_context
        ? `语境：${item.direction === 'pinyin_to_word' ? item.pronunciation_context.split(item.prompt).join('____') : item.pronunciation_context}` : null;
      const writingHeight = item.review_kind === 'pinyin' && config.grid !== 'none'
        ? config.repeats * (config.grid === 'both' ? 80 : 40) : config.blank_lines * config.repeats * 25;
      const blockHeight = (wrap(`${index + 1}. ${prompt}`,12).length + (context ? wrap(context,10).length : 0)) * 21 + 5 + writingHeight + 16;
      // Keep a short prompt with all of its writing grids. Large questions still
      // flow across pages through the existing continuation mechanism.
      ensure(blockHeight <= contentTop - floor ? blockHeight : 45);
      textBlock(`${index + 1}. ${prompt}`, 12, ink, `第 ${index + 1} 题（续）`);
      if (context) textBlock(context, 10, muted);
      y -= 5;
      if (item.review_kind === 'pinyin' && config.grid !== 'none') {
        for (let repetition = 0; repetition < config.repeats; repetition++) {
          if (config.grid === 'both' || config.grid === 'four_lines') pinyinGrid('four_lines', `第 ${index + 1} 题作答区（续）`);
          if (config.grid === 'both' || config.grid === 'tianzige') pinyinGrid('tianzige', `第 ${index + 1} 题作答区（续）`);
        }
      } else {
        for (let blank = 0; blank < config.blank_lines * config.repeats; blank++) {
          ensure(25, `第 ${index + 1} 题作答区（续）`); line(margin, y - 4, width - margin, y - 4); y -= 25;
        }
      }
      y -= 16;
    }
  }
  if (config.include_answers || config.include_explanations) {
    newPage('answers');
    for (const [index, item] of items.entries()) {
      ensure(45);
      textBlock(`${index + 1}.`, 12);
      if (config.include_answers) textBlock(`答案：${item.review_kind === 'pinyin' && item.direction === 'pinyin_to_word' ? item.prompt : item.accepted_answers.map(answer => item.review_kind === 'pinyin' ? printablePinyin(answer) : answer).join(' / ')}`, 12, ink, `第 ${index + 1} 题答案（续）`);
      if (config.include_explanations) textBlock(`解析：${item.explanation || '暂无解析'}`, 10, muted, `第 ${index + 1} 题解析（续）`);
      y -= 15;
    }
  }
  for (const [index, footerPage] of pdf.getPages().entries()) {
    page = footerPage;
    section = pageSections[index];
    draw(`学习星球 | 第 ${index + 1} / ${pdf.getPageCount()} 页`, margin, margin + 4, 9, muted);
  }
  const bytes = await pdf.save({ useObjectStreams: false, addDefaultPage: false, objectsPerTick: 100 });
  return { bytes, pages: pdf.getPageCount(), trace, size: { width, height, margin }, renderer_version: RENDERER_VERSION };
}
