'use strict';

function upperBound(sorted, value) {
  let low = 0;
  let high = sorted.length;
  while (low < high) {
    const mid = low + Math.floor((high - low) / 2);
    if (sorted[mid] <= value) low = mid + 1;
    else high = mid;
  }
  return low;
}

class DocumentText {
  constructor(text) {
    this.text = text;
    this.lines = [0];
    this.byteEnds = [];
    this.wideStarts = [];
    this.byteDeltas = [0];
    let bytes = 0;
    for (let offset = 0; offset < text.length;) {
      const point = text.codePointAt(offset);
      const units = point > 0xffff ? 2 : 1;
      if (point > 0x7f) {
        const width = point <= 0x7ff ? 2 : units === 2 ? 4 : 3;
        bytes += width;
        this.wideStarts.push(offset);
        this.byteEnds.push(bytes);
        this.byteDeltas.push(bytes - offset - units);
      } else {
        bytes++;
      }
      offset += units;
      if (point === 10 || (point === 13 && text.charCodeAt(offset) !== 10)) this.lines.push(offset);
    }
    this.byteLength = bytes;
  }

  lineEnd(line) {
    if (line + 1 === this.lines.length) return this.text.length;
    const next = this.lines[line + 1];
    return next - (this.text.charCodeAt(next - 1) === 10 && this.text.charCodeAt(next - 2) === 13 ? 2 : 1);
  }

  position(offset) {
    const line = upperBound(this.lines, offset) - 1;
    return { line, character: Math.min(offset, this.lineEnd(line)) - this.lines[line] };
  }

  // Native spans count UTF-8 bytes. Only multibyte characters change the byte-to-unit delta.
  bytePosition(offset) {
    const byte = Math.max(0, Math.min(offset, this.byteLength));
    const count = upperBound(this.byteEnds, byte);
    const unit = Math.min(byte - this.byteDeltas[count], this.wideStarts[count] ?? this.text.length);
    return this.position(unit);
  }

  offset(position) {
    if (!Number.isSafeInteger(position?.line) || position.line < 0 ||
        !Number.isSafeInteger(position.character) || position.character < 0) {
      throw new Error('Invalid document position');
    }
    if (position.line >= this.lines.length) return this.text.length;
    return Math.min(this.lines[position.line] + position.character, this.lineEnd(position.line));
  }

  change(change) {
    if (typeof change?.text !== 'string') throw new Error('Missing document text');
    if (change.range === undefined) return new DocumentText(change.text);
    const start = this.offset(change.range.start);
    const end = this.offset(change.range.end);
    if (start > end || (change.rangeLength !== undefined && change.rangeLength !== end - start)) {
      throw new Error('Invalid document change range');
    }
    return new DocumentText(this.text.slice(0, start) + change.text + this.text.slice(end));
  }
}

module.exports = { DocumentText };
