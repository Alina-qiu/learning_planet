import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const source = resolve(root, 'docs/demo');
const output = resolve(root, 'build/demo/learning-planet.html');
async function readSource(name) {
  const content = await readFile(resolve(source, name), 'utf8');
  return content.replace(/\r\n?/g, '\n');
}
let page = await readSource('index.html');
const css = await readSource('demo.css');
page = page.replace('<link rel="stylesheet" href="demo.css">', () => '<style>\n' + css + '\n</style>');

// Inline scripts execute immediately. Place them after the controls they bind.
const scripts = [];
for (const tag of page.matchAll(/<script defer src="([\w-]+\.js)"><\/script>/g)) {
  const script = await readSource(tag[1]);
  scripts.push('<script>\n' + script.replace(/<\/script/gi, '<\\/script') + '\n</script>');
  page = page.replace(tag[0], '');
}
if (!scripts.length || /<(?:script\b[^>]+src|link\b[^>]+href)=/i.test(page)) {
  throw new Error('The demo has an external script or stylesheet that cannot be packed.');
}
page = page.replace('</body>', () => scripts.join('\n') + '\n</body>');
await mkdir(dirname(output), { recursive: true });
await writeFile(output, page);
console.log(output);
