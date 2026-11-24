'use strict';

// Converts Kessel's flat regexp node array (first_child / next_sibling links,
// UTF-8 byte spans) into the nested shape that regex_ast_oxc_reference.rs
// prints for oxc, so the two trees can be compared with a plain deep equal.
//
// Only information Kessel reports is used. The one derived field is a
// Character's `kind` (Symbol, Null, Octal2, ...): Kessel reports Character
// versus Escape plus a span, and the spelling inside that span decides the
// kind. A wrong span or a wrong Character/Escape split therefore shows up as a
// kind mismatch.

const assert = require('node:assert/strict');

const LOOKAROUND = {
  Lookahead: 'Lookahead', Negative_Lookahead: 'NegativeLookahead',
  Lookbehind: 'Lookbehind', Negative_Lookbehind: 'NegativeLookbehind',
};

// Bit order of RegexAstFlags: d, g, i, m, s, u, v, y from the low bit.
const MODIFIER_BITS = [['i', 1 << 2], ['m', 1 << 3], ['s', 1 << 4]];

function modifierText(mask) {
  assert.equal(mask & ~0b11100, 0, 'only i, m, s can be modifiers');
  return MODIFIER_BITS.filter(([, bit]) => (mask & bit) !== 0).map(([name]) => name).join('');
}

function characterKind(text, state) {
  if (text[0] !== '\\' || text.length === 1) return 'Symbol';
  const body = text.slice(1);
  if (/^c[A-Za-z0-9_]$/.test(body)) return 'ControlLetter';
  // `\0` before 8 or 9 is an Annex B octal escape, not the null escape.
  if (body === '0') return /[0-9]/.test(state.following) ? 'Octal1' : 'Null';
  if (/^[0-7]{1,3}$/.test(body)) return `Octal${body.length}`;
  if (/^x[0-9a-fA-F]{2}$/.test(body)) return 'HexadecimalEscape';
  if (body[0] === 'u' && body.length > 1) return 'UnicodeEscape';
  if (/^[fnrtv]$/.test(body)) return 'SingleEscape';
  if (state.inClass && body === 'b') return 'SingleEscape';
  if (state.inClass && state.unicode && !state.unicodeSets && body === '-') return 'SingleEscape';
  return 'Identifier';
}

function normalizeKesselTree(tree, pattern) {
  const bytes = Buffer.from(pattern);
  const { nodes } = tree;
  const unicodeSets = (tree.flags & (1 << 6)) !== 0;
  const unicode = unicodeSets || (tree.flags & (1 << 5)) !== 0;
  const text = span => bytes.subarray(span.start, span.end).toString();

  function children(node) {
    const list = [];
    for (let id = node.first_child; id !== 0; id = nodes[id].next_sibling) {
      assert.ok(id > 0 && id < nodes.length, 'child link must stay inside the node array');
      assert.ok(list.length < nodes.length, 'sibling chain must not loop');
      list.push(nodes[id]);
    }
    return list;
  }

  function base(kind, node) {
    assert.ok(node.span.start <= node.span.end, 'span must not be reversed');
    assert.ok(node.span.end <= bytes.length, 'span must stay inside the pattern');
    return { k: kind, s: node.span.start, e: node.span.end };
  }

  // Alternatives hang directly off Pattern and Group nodes in Kessel; oxc
  // wraps them in a Disjunction spanning the first to the last alternative.
  function disjunction(parent) {
    const alternatives = children(parent);
    assert.ok(alternatives.length > 0, 'a disjunction has at least one alternative');
    return {
      k: 'Disjunction', s: alternatives[0].span.start, e: alternatives.at(-1).span.end,
      c: alternatives.map(alternative => {
        assert.equal(alternative.kind, 'Alternative');
        return { ...base('Alternative', alternative), c: children(alternative).map(term) };
      }),
    };
  }

  function character(node, inClass) {
    assert.notEqual(node.code_point, null, 'characters carry a value');
    const following = String.fromCharCode(bytes[node.span.end] ?? 0);
    const kind = characterKind(text(node.span), { inClass, unicode, unicodeSets, following });
    return { ...base('Character', node), kind, value: node.code_point };
  }

  function classEscape(node) {
    const letter = text(node.span)[1];
    assert.equal(node.negative, letter === letter.toUpperCase());
    const kind = (node.negative ? 'Negative' : '') + letter.toUpperCase();
    return { ...base('CharacterClassEscape', node), kind };
  }

  function property(node) {
    return {
      ...base('UnicodePropertyEscape', node), negative: node.negative,
      strings: node.may_contain_strings, name: text(node.name),
      value: node.property_value === null ? null : text(node.property_value),
    };
  }

  function classString(node) {
    const strings = children(node).map(alternative => {
      const characters = children(alternative).map(item => character(item, true));
      return {
        ...base('ClassString', alternative), strings: characters.length !== 1, c: characters,
      };
    });
    return {
      ...base('ClassStringDisjunction', node), strings: node.may_contain_strings, c: strings,
    };
  }

  function classNode(node) {
    const contents = [];
    let kind = 'Union';
    for (const child of children(node)) {
      if (child.kind === 'Class_Intersection' || child.kind === 'Class_Subtraction') {
        const relation = child.kind.slice('Class_'.length);
        assert.ok(kind === 'Union' || kind === relation, 'set operators must not mix');
        kind = relation;
      } else {
        contents.push(classContent(child));
      }
    }
    if (node.class_relation !== undefined) assert.equal(node.class_relation, kind);
    return {
      ...base('CharacterClass', node), negative: node.negative,
      strings: node.may_contain_strings, kind, c: contents,
    };
  }

  function classContent(node) {
    switch (node.kind) {
      case 'Class_Range': {
        const ends = children(node);
        assert.equal(ends.length, 2, 'a range has two ends');
        return { ...base('CharacterClassRange', node), c: ends.map(end => character(end, true)) };
      }
      case 'Character': case 'Escape': return character(node, true);
      case 'Character_Class_Escape': return classEscape(node);
      case 'Property_Escape': return property(node);
      case 'Character_Class': return classNode(node);
      case 'Class_String': return classString(node);
      default: return assert.fail(`Unexpected class member ${node.kind}`);
    }
  }

  function group(node) {
    const body = [disjunction(node)];
    switch (node.group_kind) {
      case 'Capture':
        assert.ok(node.capture_index > 0, 'captures are numbered from one');
        return { ...base('CapturingGroup', node), name: null, c: body };
      case 'Named_Capture':
        assert.ok(node.capture_index > 0, 'captures are numbered from one');
        return { ...base('CapturingGroup', node), name: text(node.name), c: body };
      case 'Noncapturing':
        return { ...base('IgnoreGroup', node), modifiers: null, c: body };
      case 'Modifiers':
        assert.ok(node.modifiers, 'modifier groups report structured flags');
        return {
          ...base('IgnoreGroup', node),
          modifiers: {
            s: node.name.start, e: node.name.end,
            enabling: modifierText(node.modifiers.add),
            disabling: modifierText(node.modifiers.remove),
          },
          c: body,
        };
      default:
        return { ...base('LookAround', node), kind: LOOKAROUND[node.group_kind], c: body };
    }
  }

  function term(node) {
    switch (node.kind) {
      case 'Start_Assertion': return { ...base('BoundaryAssertion', node), kind: 'Start' };
      case 'End_Assertion': return { ...base('BoundaryAssertion', node), kind: 'End' };
      case 'Boundary_Assertion': {
        const kind = node.negative ? 'NegativeBoundary' : 'Boundary';
        return { ...base('BoundaryAssertion', node), kind };
      }
      case 'Group': return group(node);
      case 'Quantifier': {
        const body = children(node);
        assert.equal(body.length, 1, 'a quantifier wraps one term');
        const bound = value => (value.overflow ? 'overflow' : value.value);
        return {
          ...base('Quantifier', node), min: bound(node.repeat.min),
          max: node.repeat.max === null ? null : bound(node.repeat.max),
          greedy: node.repeat.greedy, c: [term(body[0])],
        };
      }
      case 'Character': case 'Escape': return character(node, false);
      case 'Dot': return base('Dot', node);
      case 'Character_Class_Escape': return classEscape(node);
      case 'Property_Escape': return property(node);
      case 'Character_Class': return classNode(node);
      case 'Indexed_Reference':
        return { ...base('IndexedReference', node), index: node.capture_index };
      case 'Named_Reference': return { ...base('NamedReference', node), name: text(node.name) };
      default: return assert.fail(`Unexpected term ${node.kind}`);
    }
  }

  const root = nodes[tree.root];
  assert.equal(root.kind, 'Pattern');
  const normalized = { ...base('Pattern', root), c: [disjunction(root)] };
  checkCaptures(tree);
  return normalized;
}

// Capture numbering is not part of oxc's tree, so it is checked here against
// the spec rule: groups are numbered by their opening parenthesis, left to
// right, starting at one.
function checkCaptures(tree) {
  const groups = tree.nodes
    .filter(node => node.kind === 'Group' && node.capture_index !== 0)
    .sort((left, right) => left.span.start - right.span.start);
  groups.forEach((node, index) => assert.equal(node.capture_index, index + 1));
  assert.equal(tree.capture_count, groups.length);
  return groups.length;
}

module.exports = { normalizeKesselTree };
