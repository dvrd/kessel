//! Reference dump of oxc's regular expression tree for Kessel's regexp gate.
//!
//! Reads JSON lines `{"p": pattern, "f": flags}` on stdin and writes one JSON
//! line per input: either `{"err": message}` or a normalized tree. Spans are
//! UTF-8 byte offsets into the pattern, which is what oxc's literal reader
//! produces, so they compare directly with Kessel's spans.

use std::io::{BufRead, BufWriter, Write};

use oxc_allocator::Allocator;
use oxc_regular_expression::{LiteralParser, Options, ast::*};
use serde_json::{Value, json};

fn main() {
    let stdin = std::io::stdin();
    let mut out = BufWriter::new(std::io::stdout().lock());
    for line in stdin.lock().lines() {
        let line = line.expect("stdin must be UTF-8");
        if line.is_empty() {
            continue;
        }
        let input: Value = serde_json::from_str(&line).expect("input must be JSON lines");
        let pattern = input["p"].as_str().expect("p must be a string");
        let flags = input["f"].as_str().expect("f must be a string");
        let allocator = Allocator::default();
        let parsed =
            LiteralParser::new(&allocator, pattern, Some(flags), Options::default()).parse();
        let value = match parsed {
            Ok(tree) => json!({
                "k": "Pattern", "s": tree.span.start, "e": tree.span.end,
                "c": [disjunction(&tree.body)],
            }),
            Err(error) => json!({ "err": error.to_string() }),
        };
        serde_json::to_writer(&mut out, &value).expect("stdout must be writable");
        out.write_all(b"\n").expect("stdout must be writable");
    }
}

fn disjunction(node: &Disjunction) -> Value {
    let alternatives: Vec<Value> = node.body.iter().map(alternative).collect();
    json!({ "k": "Disjunction", "s": node.span.start, "e": node.span.end, "c": alternatives })
}

fn alternative(node: &Alternative) -> Value {
    let terms: Vec<Value> = node.body.iter().map(term).collect();
    json!({ "k": "Alternative", "s": node.span.start, "e": node.span.end, "c": terms })
}

fn term(node: &Term) -> Value {
    match node {
        Term::BoundaryAssertion(it) => json!({
            "k": "BoundaryAssertion", "s": it.span.start, "e": it.span.end,
            "kind": format!("{:?}", it.kind),
        }),
        Term::LookAroundAssertion(it) => json!({
            "k": "LookAround", "s": it.span.start, "e": it.span.end,
            "kind": format!("{:?}", it.kind), "c": [disjunction(&it.body)],
        }),
        Term::Quantifier(it) => json!({
            "k": "Quantifier", "s": it.span.start, "e": it.span.end,
            "min": it.min, "max": it.max, "greedy": it.greedy, "c": [term(&it.body)],
        }),
        Term::Character(it) => character(it),
        Term::Dot(it) => json!({ "k": "Dot", "s": it.span.start, "e": it.span.end }),
        Term::CharacterClassEscape(it) => class_escape(it),
        Term::UnicodePropertyEscape(it) => property(it),
        Term::CharacterClass(it) => class(it),
        Term::CapturingGroup(it) => json!({
            "k": "CapturingGroup", "s": it.span.start, "e": it.span.end,
            "name": it.name.as_ref().map(|name| name.as_str()), "c": [disjunction(&it.body)],
        }),
        Term::IgnoreGroup(it) => json!({
            "k": "IgnoreGroup", "s": it.span.start, "e": it.span.end,
            "modifiers": it.modifiers.as_ref().map(|modifiers| json!({
                "s": modifiers.span.start, "e": modifiers.span.end,
                "enabling": modifier(modifiers.enabling),
                "disabling": modifier(modifiers.disabling),
            })),
            "c": [disjunction(&it.body)],
        }),
        Term::IndexedReference(it) => json!({
            "k": "IndexedReference", "s": it.span.start, "e": it.span.end, "index": it.index,
        }),
        Term::NamedReference(it) => json!({
            "k": "NamedReference", "s": it.span.start, "e": it.span.end,
            "name": it.name.as_str(),
        }),
    }
}

/// Modifier flags in a fixed `ims` order so the text compares independent of source order.
fn modifier(flags: Modifier) -> String {
    let mut text = String::new();
    if flags.contains(Modifier::I) {
        text.push('i');
    }
    if flags.contains(Modifier::M) {
        text.push('m');
    }
    if flags.contains(Modifier::S) {
        text.push('s');
    }
    text
}

fn character(it: &Character) -> Value {
    json!({
        "k": "Character", "s": it.span.start, "e": it.span.end,
        "kind": format!("{:?}", it.kind), "value": it.value,
    })
}

fn class_escape(it: &CharacterClassEscape) -> Value {
    json!({
        "k": "CharacterClassEscape", "s": it.span.start, "e": it.span.end,
        "kind": format!("{:?}", it.kind),
    })
}

fn property(it: &UnicodePropertyEscape) -> Value {
    json!({
        "k": "UnicodePropertyEscape", "s": it.span.start, "e": it.span.end,
        "negative": it.negative, "strings": it.strings, "name": it.name.as_str(),
        "value": it.value.as_ref().map(|value| value.as_str()),
    })
}

fn class(it: &CharacterClass) -> Value {
    let contents: Vec<Value> = it.body.iter().map(class_contents).collect();
    json!({
        "k": "CharacterClass", "s": it.span.start, "e": it.span.end,
        "negative": it.negative, "strings": it.strings, "kind": format!("{:?}", it.kind),
        "c": contents,
    })
}

fn class_contents(node: &CharacterClassContents) -> Value {
    match node {
        CharacterClassContents::CharacterClassRange(it) => json!({
            "k": "CharacterClassRange", "s": it.span.start, "e": it.span.end,
            "c": [character(&it.min), character(&it.max)],
        }),
        CharacterClassContents::CharacterClassEscape(it) => class_escape(it),
        CharacterClassContents::UnicodePropertyEscape(it) => property(it),
        CharacterClassContents::Character(it) => character(it),
        CharacterClassContents::NestedCharacterClass(it) => class(it),
        CharacterClassContents::ClassStringDisjunction(it) => {
            let strings: Vec<Value> = it.body.iter().map(class_string).collect();
            json!({
                "k": "ClassStringDisjunction", "s": it.span.start, "e": it.span.end,
                "strings": it.strings, "c": strings,
            })
        }
    }
}

fn class_string(it: &ClassString) -> Value {
    let characters: Vec<Value> = it.body.iter().map(character).collect();
    json!({
        "k": "ClassString", "s": it.span.start, "e": it.span.end,
        "strings": it.strings, "c": characters,
    })
}
