'use strict';

const headerLimit = 8192;
const bodyLimit = 64 * 1024 * 1024;
const delimiter = Buffer.from('\r\n\r\n');

async function* readFrames(input) {
  const header = Buffer.allocUnsafe(headerLimit);
  let headerSize = 0;
  let body;
  let received = 0;
  for await (const chunk of input) {
    for (let offset = 0; offset < chunk.length;) {
      if (!body) {
        const byte = chunk[offset++];
        if (headerSize === header.length) throw new Error('LSP header is too large');
        header[headerSize++] = byte;
        if (byte !== 10 || headerSize < 4 || !header.subarray(headerSize - 4, headerSize).equals(delimiter)) continue;
        const lengths = header.toString('ascii', 0, headerSize - 4).split('\r\n')
          .filter(line => /^Content-Length:/i.test(line));
        const value = lengths.length === 1 && /^Content-Length:\s*(\d+)\s*$/i.exec(lengths[0]);
        if (!value || Number(value[1]) > bodyLimit) throw new Error('Invalid LSP Content-Length');
        body = Buffer.allocUnsafe(Number(value[1]));
        headerSize = 0;
        received = 0;
      }
      const size = Math.min(body.length - received, chunk.length - offset);
      chunk.copy(body, received, offset, offset + size);
      offset += size;
      received += size;
      if (received === body.length) {
        yield body.toString('utf8');
        body = undefined;
      }
    }
  }
  if (body || headerSize) throw new Error('Incomplete LSP frame');
}

function writeMessage(stream, message) {
  const content = Buffer.from(JSON.stringify({ jsonrpc: '2.0', ...message }));
  const header = Buffer.from('Content-Length: ' + content.length + '\r\n\r\n');
  return new Promise((resolve, reject) => {
    stream.write(Buffer.concat([header, content]), error => error ? reject(error) : resolve());
  });
}

module.exports = { readFrames, writeMessage };
