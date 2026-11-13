// Loopback SMTP sink for GoTrue integration. It never relays mail or saves message bodies.
import {createServer} from 'node:net';
import {listen} from './http_test_tools.mjs';

function htmlBody(message) {
  const split = message.indexOf('\r\n\r\n');
  if (split < 0) throw new Error('Test mail is missing MIME headers');
  const headers = message.slice(0, split), body = message.slice(split + 4);
  if (/content-transfer-encoding:\s*base64/i.test(headers)) return Buffer.from(body, 'base64').toString('utf8');
  if (/content-transfer-encoding:\s*quoted-printable/i.test(headers)) {
    return Buffer.from(body.replace(/=\r?\n/g, '').replace(/=([a-f0-9]{2})/gi,
      (_, hex) => String.fromCharCode(parseInt(hex, 16))), 'latin1').toString('utf8');
  }
  return body;
}

export async function localMailbox() {
  const messages = new Map(), sockets = new Set();
  const server = createServer(socket => {
    sockets.add(socket); socket.setEncoding('utf8'); socket.setTimeout(15000, () => socket.destroy());
    socket.on('error', () => {}); socket.on('close', () => sockets.delete(socket));
    socket.write('220 localhost test SMTP\r\n');
    let buffer = '', recipients = [], data = false, lines = [];
    socket.on('data', chunk => {
      buffer += chunk;
      if (buffer.length > 1_000_000) { socket.destroy(); return; }
      let end;
      while ((end = buffer.indexOf('\r\n')) >= 0) {
        const line = buffer.slice(0, end); buffer = buffer.slice(end + 2);
        if (data) {
          if (line === '.') {
            try {
              const html = htmlBody(lines.join('\r\n'));
              const code = /<p\b[^>]*font-size:\s*32px[^>]*>\s*(\d{8})\s*<\/p>/i.exec(html)?.[1];
              if (!code || !html.includes('登录学习星球')) throw new Error('Project OTP template missing');
              for (const email of recipients) {
                const previous = messages.get(email) ?? [];
                messages.set(email, [...previous, {code, html}]);
              }
              socket.write('250 Message accepted into local test sink\r\n');
            } catch { socket.write('554 Invalid local test template\r\n'); }
            data = false; lines = []; recipients = [];
          } else {
            lines.push(line.startsWith('..') ? line.slice(1) : line);
            if (lines.length > 10000) socket.destroy();
          }
        } else if (/^(EHLO|HELO) /i.test(line)) socket.write('250-localhost\r\n250 8BITMIME\r\n');
        else if (/^MAIL FROM:/i.test(line)) { recipients = []; socket.write('250 OK\r\n'); }
        else if (/^RCPT TO:/i.test(line)) {
          const address = /^RCPT TO:\s*<([a-z0-9._+-]+@example\.test)>$/i.exec(line)?.[1].toLowerCase();
          if (address) { recipients.push(address); socket.write('250 OK\r\n'); }
          else socket.write('550 Only synthetic local recipients are accepted\r\n');
        } else if (/^DATA$/i.test(line) && recipients.length) { data = true; lines = []; socket.write('354 End with a single dot\r\n'); }
        else if (/^QUIT$/i.test(line)) { socket.end('221 Bye\r\n'); }
        else if (/^(RSET|NOOP)$/i.test(line)) { recipients = []; data = false; lines = []; socket.write('250 OK\r\n'); }
        else socket.write('502 Unsupported test SMTP command\r\n');
      }
    });
  });
  await listen(server);
  return {
    port: server.address().port,
    latest(email) {
      const entries = messages.get(email.toLowerCase()) ?? [];
      return entries.length ? {count: entries.length, ...entries.at(-1)} : null;
    },
    get count() { return [...messages.values()].reduce((sum, entries) => sum + entries.length, 0); },
    async stop() {
      for (const socket of sockets) socket.destroy();
      await new Promise(resolve => server.close(resolve)); messages.clear();
    },
  };
}
