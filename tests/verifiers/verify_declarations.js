'use strict';

// Compare the public CLI and SDK against TypeScript's single-file declaration emitter.
// AST comparison ignores layout while retaining modifiers, types, names and literal values.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const ts = require('../../bench/node_modules/typescript');
const { isolatedDeclarationSync } = require('../../npm/kessel');

const binary = path.resolve('bin', process.platform === 'win32' ? 'kessel.exe' : 'kessel');
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kessel-declarations-'));
const options = { strict: true, target: ts.ScriptTarget.ESNext };
const positive = [
  'export class C {get v():number{return 1} set v({text=""}: {text?:string}){} set label([x]:[string]){} }',
  'interface I{x:number} export const api={get v():I{return {x:1}},set v({x}:I){}};',
  'export const table={set v([x]:[number]){}};',
  'type Flag = boolean; export const api={get v():Flag{return true}, set v(p:true|false){}};',
  'type A = number; export const api={get v():A[][]{return []}, set v(p:Array<Array<number>>){}};',
  'interface I{} type J=I; export const api={get v():I{return {}},set v(p:J){}};',
  'const Symbol = {}; export const table={get [globalThis.Symbol.iterator]():number{return 0}};',
  'type A = number | string; type B = A; export const api={get value():A{return 1},set value(v:B){}};',
  'export const api = { get v():number { return 1 }, set v(value:number | never){} };',
  'export const api = { get "plain"():number { return 1 }, get [-3.5]():number { return 2 } };',
  'export const api = { get ["16"]():number { return 1 }, set [0x10](v:number) {}, get ["12"]():number { return 2 } };',
  'export class API { get [0x10](){return read()} set 16(value:number){} [`run`](x:string):number; run(x:string){return 1} }',
  'export const table = { value: 1, get [globalThis.Symbol.iterator]():number { return 1 }, [Symbol.toPrimitive](x:string):string{return x} };',
  'export const table = { before: 1, set [Symbol.iterator](v:number){}, after: 3 } as const;',
  'export const table = { get [Symbol?.iterator]():number{return 1}, label:"x", set [Symbol.iterator](v:number){} };',
  'export class LiteralKeys { [+1]: string; [-2.5](): void {} [`label`]: boolean; }',
  'export const settings = { [`red`]: 1, [`a-b`]: 2, ["λ"]: 3, [+4]: 4, [-2]: 5, [-0]: 6, ["12"]: 7 };',
  'export const api = { get [`a`]() { return 1 }, get ["b"]() { return "x" }, set a(v:number) {} };',
  'declare const keys: { nested: { token: unique symbol } }; export interface API { [keys?.nested.token](): void; }',
  'import { keys } from "keys"; export type API = { readonly [keys.nested?.token]?: number };',
  'export interface LiteralKeys { [+1]: string; [-2.5](): void; [`flag`]: boolean; }',
  'interface Hidden { [invalid()]: string } export interface Visible { ["valid"]: number; }',
  'export namespace Cache { type Key=string; type Item={id:number}; export class Items { readonly [key:Key]:Item } }',
  'export class Statics { static readonly [key:symbol]: number; x:number=1 }',
  'export const n = 0x10, m = -5, yes = true, hello = "hi", empty = null, size = 3n;',
  'export let n = 2, ok = false; export var label: string = lookup();',
  'export const a = create() as string, b = ["x", 2, {ok: true}] as const;',
  'export const values = {count: 1, title: "x", nested: {valid: true}};',
  'export const select = <T,>(value: T): T => value;',
  'export function inc(x = 2, scale: number): number { return x * scale; }',
  'export function yes() { return true; } export async function fetch(): Promise<string> { return ""; }',
  'export function args(...names: string[]): void {}',
  'export function run({x}: {x: number}, [y]: [number]): number {return x + y}',
  'export default function <T>(value:T): T { return value }',
  'export default {ok: true};',
  'const name: string = get(); export default name;',
  'import type {A as First, B} from "types"; type Local = First; export interface API { run(x: Local): void; }',
  'import * as Lib from "types"; interface Box extends Lib.Base { key: Lib.Key }; export type Public = Box;',
  'const key = 7; export type Key = typeof key;',
  'import "side"; import {unused} from "b"; export type Item = number;',
  'import {unused} from "b"; const local = unknown();',
  'type Private = number; const invalid = get(); export {type Private as Public};',
  'let n = 0; function run(value: number): void {}',
  'export function parse(x: string): number; export function parse(x: number): string; export function parse(x) { return x; }',
  'export type {A as B} from "lib"; export * as Tools from "tools";',
  'type T = Missing; export function f<T>(x:T):T {return x}',
  'const key = bad(); export function f(key:number): typeof key {return key}',
  'type K = string; export type MapKeys<T> = { [K in keyof T]: T[K] };',
  'interface Link { next: Link } export type Root = Link;',
  'export {shared}; const ignored = bad(), shared: number = 1;',
  'const hidden = fail(); export const view: string = <div/> as any;',
  'type A = string; export type Unwrap<T> = T extends Promise<infer A> ? A : never;',
  'export class Box<T> { readonly value:T; constructor(value:T){this.value=value} get item():T{return this.value} }',
  'export abstract class Model { #data=read(); private raw=read(); static readonly count=2; abstract getName(x:number):string; }',
  'export class Child extends Parent<string> implements View { constructor(public readonly id:string,private data:number){super()} }',
  'export class Read { get n(){return 1} set n(value){}; m(x:string):number; m(x){return 4} }',
  'export const api = { method(x:number):number{return x}, get size(){return 2}, set size(n:number){} };',
  'export const obj={ method():number{return 2}, get n():number{return 3} } as const;',
  'export enum State { Idle, Running=2, More=Running<<1, Label="ready" }',
  'export const enum Flag { A=1, B=2, Both=A|B }',
  'export function f({x=3}: {x?:number}):number {return x}',
  'export const value: number = 5; export default (2);',
  'export let msg = `value ${read()}`; export function describe(s=`#${get()}`): string {return s}',
  'type N = 1; export class C { tuple? = [2 as N] as const; n? = 2; readonly tag? = "r"; }',
  'const key = {v:"field"}; export function f():void{}; f[key.v] = 42;',
  'export class Directory { readonly [key:string]:Item } ' +
    'export namespace API { type Id=string; export function get(id:Id):void{} }',
  'export module A.B { export const x:number=1; }',
  'export function fn():void{} export namespace fn { export let version=1; } fn.version=2;',
  'type Key=string; export namespace Outer { export namespace Inner { export type Name=Key; } }',
  'type Key=Missing; export namespace N { type Key=string; export type Name=Key; }',
  'type Key=Missing; export namespace N { export type Key=string; } export namespace N { export type Name=Key; }',
  'export declare namespace N { export {Secret as Name}; type Secret=number; const item:string; }',
  'namespace N { const unused=bad(); export interface View {} } export type Item=N.View;',
  'export namespace N { export enum E { A=1, B=A+1 } export class C { readonly x:E=E.B; } }',
  'export namespace N { import A=Other.T; export type Z=A; }',
  'export declare namespace N { export type X=number; type Local=string; }',
  'export namespace A { export namespace B {} } export namespace A.B { export type Item=number; }',
  'import type {Dep} from "lib"; export namespace N {export function load():Dep; export function load(){ return read() }}',
  'export namespace N { namespace Hidden { export type X=number; } export type Y=Hidden.X; }',
  'export declare namespace N {export const x=2; export {x as y};}',
  'import "dep"; declare global { interface Window { count:number; } }',
  'export {}; declare namespace A {type X=string;} declare namespace N {import J=A.X; import I=J; export {I};}',
  'export {}; type X=string; declare namespace Hidden { export {X as Alias}; }',
  'export {}; type X=string; declare namespace N { type Y=X; export {Y}; }',
  'import {} from "polyfill";',
  'import T = require("example"); export = T;',
  'const value = 1; export = { answer: 42 };',
];
const negative = [
  'export const api={get v():number{return 1},set v({x}: {x:number}){}};',
  'type A=string|number; export const api={get clé():(A){return 1},set clé(é:number|string){}};',
  'interface Input{} interface Output{} export const api={get v():Output{return {}},set v(p:Input){}};',
  'type Flag=true|false; export const api={get v():Flag{return true},set v(p:boolean){}};',
  'const globalThis={Symbol:{iterator:0}}; export const table={get [globalThis.Symbol.iterator]():number{return 0}};',
  'type A=number|string; type B=string|number; export const api={get v():A{return 1}, set v(input:B){}};',
  'export const api = { get value():number { return 1 }, set value(input:number|string){} };',
  'type Input=string; type Output=number; export const api={set [4](value:Input){}, get ["4"]():Output{return 1}};',
  'export const api = { get value():unknown { return 1 }, set value(input:any){} } as const;',
  'declare const key: string; export const table = {[key]: unknown(), ["x" + key]: {nested: get()}};',
  'declare const Symbol: { iterator: unique symbol }; export const api = {[Symbol.iterator]: unknown()};',
  'declare const key: string; export class API { [key](value:string):void; [key](value?:string){} }',
  'export class Bad { [factory()](value) { return value } [names[0]](v) {} }',
  'export const api = { [`run`]() {} };',
  'declare const Symbol: { key: unique symbol }; export class Bad { [Symbol.key](): void {} }',
  'export interface API { readonly [ /* [ */ λ() /* ] */ ]?: number; get [make()](): string; }',
  'export interface API { [lookup()](value): { [nested()]: string }; [bad()]; }',
  'export type Bad = { marker: string; [Symbol["iterator"]]: number; [(keys).token]: string };',
  'export interface Bad { [`k${x}`]: string; [-2n]: number; [keys[0].name](): boolean; }',
  'declare const valid: unique symbol; export interface Bad { [valid]; }',
  'export namespace API { export type Keys = { value: { [// [\n factory() // ]\n ]: string } } }',
  'export const s = compute(); export let missing;',
  'export function compute(input) { return input; }',
  'export function missing(): void {} export function empty() {}',
  'export function f(value = get()): void {}',
  'export const λ = fn(); export const 日本語 = get();',
  'export const xs = [1, 2];',
  'export const shape = { value: call() };',
  'export const {x: y, z} = get();',
  'export default compute();',
  'const privateValue = call(); export {privateValue};',
  'export const obj={...others};',
  'export const obj={name};',
  'export const xs=[...xs2] as const;',
  'export class C { n=call(); method(p):void {} }',
  'export class C extends mixin(Base) {}',
  'export const C = class Inner {};',
  'export const f = function named(x){ return x };',
  'export default function(){ return read() }',
  'export const obj = { get n(){return fn()} };',
  'export const obj = { method(){return read()} };',
  'export function count():number {return 1} count.next = 2;',
  'const n = 5; export enum Code { A=n }',
  'export const obj={ [get()]: 1 };',
  'const o = {nested:{key:"field"}} as const; export function f():void{}; f[o.nested.key]=1;',
  'const key = "field"; export function f():void{}; f[key]=1; f.field=2;',
  'const key:"first" = "first"; export function f():void{}; f[key]=1;',
  'export enum A { One=1 } export enum B { Ref=A.One, Alias=Ref }',
  'export namespace N { export function f():void{}; f.x=1; }',
  'export function fn():void{} export namespace fn {export let x:number;} fn.x=1; fn.other=2;',
  'export namespace A { export const bad=read(); } export const another=read();',
  'const bad=read(); export namespace A { export const another=read(); export type X=typeof bad; }',
  'export namespace A.B { export function bad(p) { return p; } }',
  'export namespace N { export const fn=(x:number) => /* => */ {\n    return lookup(x);\n}; }',
  'export const f=(x:number) => // =>\r\n{ return unknown(x) }',
  'export = read();',
];
function tree(text) {
  const file = ts.createSourceFile('out.d.ts', text, ts.ScriptTarget.Latest, true);
  assert.equal(file.parseDiagnostics.length, 0, text);
  function visit(node) {
    const record = [ts.SyntaxKind[node.kind]];
    if (node.text !== undefined) record.push(node.text);
    if (ts.isVariableDeclarationList(node)) record.push(node.flags & ts.NodeFlags.BlockScoped);
    if ('isTypeOnly' in node) record.push(node.isTypeOnly);
    ts.forEachChild(node, child => { record.push(visit(child)); });
    return record;
  }
  return file.statements.map(visit);
}
function referenceDiagnostics(source, diagnostics) {
  return diagnostics.map(d => ({
    code: 'TS' + d.code, start: Buffer.byteLength(source.slice(0, d.start)),
    end: Buffer.byteLength(source.slice(0, d.start + d.length)), message: d.messageText,
  }));
}
function check(source, filename, shouldEmit) {
  const file = path.join(dir, filename);
  fs.writeFileSync(file, source);
  const reference = ts.transpileDeclaration(source, {fileName: filename, compilerOptions: options});
  assert.equal(reference.diagnostics.length === 0, shouldEmit, source);
  const sdk = isolatedDeclarationSync(filename, source);
  const cli = spawnSync(binary, ['dts', file], {encoding: 'utf8'});
  assert.equal(cli.status, shouldEmit ? 0 : 1, source + '\n' + cli.stderr);
  assert.equal(cli.stdout, sdk.output);
  if (shouldEmit) {
    assert.deepEqual(sdk.errors, [], source);
    assert.equal(cli.stderr, '', source);
    assert.deepEqual(tree(sdk.output), tree(reference.outputText), source + '\n' + sdk.output + reference.outputText);
  } else {
    assert.equal(sdk.output, '');
    const expected = referenceDiagnostics(source, reference.diagnostics);
    assert.deepEqual(sdk.errors, expected, source);
    const expectedStderr = expected.map(e =>
      file + ':' + e.start + ':' + e.end + ' ' + e.code + ': ' + e.message + '\n').join('');
    assert.equal(cli.stderr.replace(/\r\n/g, '\n'), expectedStderr, source);
  }
}
function checkAccessorTypes() {
  const types = [
    'number', 'string', 'boolean', 'null', 'undefined', 'void', 'never', 'unknown', 'any', 'object',
    'symbol', 'bigint', 'string|number', 'number|never', '(A)', 'A', 'B', 'C', 'D', 'true', 'true|false',
    'number[]', 'Array<number>', 'I', 'J', 'E',
  ];
  const aliases = 'type A=string|number; type B=A; type C=string|number; type D=number; interface I{} interface J{} type E=I;';
  let emitted = 0;
  for (const read of types) for (const write of types) {
    const source = aliases + 'export const api={get v():' + read + '{return 1 as any},set v(p:' + write + '){}};';
    const reference = ts.transpileDeclaration(source, {fileName: 'api.ts', compilerOptions: options});
    const actual = isolatedDeclarationSync('api.ts', source);
    assert.deepEqual(actual.errors, referenceDiagnostics(source, reference.diagnostics), source);
    if (actual.errors.length) {
      assert.equal(actual.output, '', source);
    } else {
      assert.deepEqual(tree(actual.output), tree(reference.outputText), source);
      emitted++;
    }
  }
  console.log(types.length ** 2 + ' getter/setter type pairs matched TypeScript, including ' + emitted + ' emitted declarations.');
}
// An isolated emitter cannot resolve the definitions in another module. Verify
// both accessor annotations with a real consumer that can load that module.
function checkAccessorConsumer() {
  fs.writeFileSync(path.join(dir, 'contracts.d.ts'), 'export type Read = number; export type Write = string; export interface Payload { text?: string }');
  const source = [
    'import type {Read, Write, Payload} from "./contracts";',
    'export const port = {get data():Read {return 0}, set data(value:Write) {}};',
    'export const channel = {get message():Read {return 0}, set message({text = ""}:Payload) {}};',
    'export const keys = {get [+1]():number {return 10}, get ["+1"]():string {return "plus"}, get [-0]():boolean {return true}};',
  ].join('\n');
  const sdk = isolatedDeclarationSync('accessors.ts', source);
  assert.deepEqual(sdk.errors, []);
  const input = path.join(dir, 'accessors-input.ts');
  fs.writeFileSync(input, source);
  const cli = spawnSync(binary, ['dts', input], {encoding: 'utf8'});
  assert.equal(cli.status, 0, cli.stderr);
  assert.equal(cli.stdout, sdk.output);
  fs.writeFileSync(path.join(dir, 'accessors.d.ts'), sdk.output);
  // Evaluate the same source to check which numeric names JavaScript exposes.
  const runtime = {exports: {}};
  const js = ts.transpileModule(source, {compilerOptions: {...options, module: ts.ModuleKind.CommonJS}});
  require('node:vm').runInNewContext(js.outputText, runtime);
  const keys = runtime.exports.keys;
  assert.deepEqual(Reflect.ownKeys(keys), ['0', '1', '+1']);
  assert.deepEqual([keys[0], keys[1], keys['+1']], [true, 10, 'plus']);
  const consumer = path.join(dir, 'accessors-consumer.ts');
  fs.writeFileSync(consumer, [
    'import {port, channel, keys} from "./accessors";',
    'const read: number = port.data; port.data = "accepted";',
    'const message: number = channel.message; channel.message = {text: "message"};',
    '// @ts-expect-error the setter requires a payload', 'channel.message = 1;',
    '// @ts-expect-error the setter accepts strings', 'port.data = 42;',
    'const zero: boolean = keys[0], numeric: number = keys[1], text: string = keys["+1"];',
    '// @ts-expect-error a getter-only property is readonly', 'keys[1] = 5;',
  ].join('\n'));
  return consumer;
}
function checkUpstream(directory) {
  const corpus = path.resolve('tests/vendor/typescript/tests/cases', directory);
  const filenames = directory === 'compiler'
    ? fs.readdirSync(corpus).filter(name => /^isolatedDeclaration.*\.tsx?$/.test(name))
    : fs.readdirSync(corpus, { recursive: true }).filter(name => /\.tsx?$/.test(name) && !/\.d\.ts$/.test(name));
  let count = 0;
  let matchingDiagnostics = 0;
  let matchingOutput = 0;
  let valid = 0;
  const gaps = [];
  for (const filename of filenames.sort()) {
    const text = fs.readFileSync(path.join(corpus, filename), 'utf8');
    const split = text.split(/^\s*\/\/\s*@filename:\s*(.+?)\s*$/gmi);
    const units = split.length === 1 ? [[filename, text]] : [];
    for (let i = 1; i < split.length; i += 2) units.push([split[i], split[i + 1]]);
    for (const [name, source] of units) {
      if (!/\.tsx?$/.test(name) || /\.d\.ts$/.test(name)) continue;
      const reference = ts.transpileDeclaration(source, {fileName: name, compilerOptions: options});
      const actual = isolatedDeclarationSync(name, source);
      const expected = reference.diagnostics.map(d => [
        'TS' + d.code, Buffer.byteLength(source.slice(0, d.start)),
        Buffer.byteLength(source.slice(0, d.start + d.length)), d.messageText,
      ].join('|')).sort();
      const got = actual.errors.map(e => [e.code, e.start, e.end, e.message].join('|')).sort();
      const matches = JSON.stringify(expected) === JSON.stringify(got);
      if (matches) matchingDiagnostics++;
      let outputMatches = true;
      if (expected.length === 0) {
        valid++;
        outputMatches = got.length === 0 && JSON.stringify(tree(reference.outputText)) === JSON.stringify(tree(actual.output));
        if (outputMatches) matchingOutput++;
      }
      if (!matches || !outputMatches) gaps.push(filename + ' / ' + name);
      count++;
    }
  }
  assert.ok(count > 0, 'TypeScript declaration compiler fixtures are required');
  console.log(count + ' compiler inputs, ' + matchingDiagnostics + ' exact diagnostic sets, ' + matchingOutput + '/' + valid + ' declaration ASTs matched.');
  for (const gap of gaps) console.log('Difference in ' + gap);
  return gaps.length === 0;
}
try {
  assert.equal(ts.version, '5.9.3');
  for (const src of positive) check(src, src.includes('<div/>') ? 'api.tsx' : 'api.ts', true);
  for (const src of negative) check(src, 'lib.ts', false);
  check('export const flavor: string = "esm";', 'esm.mts', true);
  check('export const flavor: string = "commonjs";', 'entry.cts', true);
  const bad = isolatedDeclarationSync('broken.ts', 'export const = ;');
  assert.equal(bad.output, '');
  assert.equal(bad.errors[0].code, 'Invalid_Syntax');
  assert.equal(isolatedDeclarationSync('lib.js', 'const x = 1;').errors[0].code, 'Unsupported_Input');
  const header = 'export declare function api(): string;\n';
  assert.equal(isolatedDeclarationSync('input.d.ts', header).output, header);
  const docs = '/** Library entry. */\nexport function read(): number { return 1; }';
  assert.ok(isolatedDeclarationSync('entry.ts', docs).output.startsWith('/** Library entry. */\n'));
  const entry = path.join(dir, 'consumer.d.ts');
  fs.writeFileSync(entry, isolatedDeclarationSync('types.ts',
    'interface Item { id:number } export class Store { constructor(public readonly item:Item){} } ' +
    'export declare const token: unique symbol; export type Registry = { readonly [token]: Item }; ' +
    'export class Directory { readonly [key:string]:Item } ' +
    'export namespace API { type Id = number; export namespace Models { export interface Data { id:Id } } ' +
    'export function make(data:Models.Data):Store { return new Store(data); } }').output);
  const consumer = path.join(dir, 'consumer-test.ts');
  fs.writeFileSync(consumer, 'import { Store, API, Directory, Registry, token } from "./consumer"; const value: number = new Store({id: 1}).item.id;\n' +
    'declare const registry: Registry; const stored: number = registry[token].id;\n' +
    '// @ts-expect-error the computed registry entry is readonly\nregistry[token] = {id: 2};\n' +
    'declare const entries: Directory; const id: number = entries["one"].id;\n' +
    'const model: API.Models.Data = {id: 3}; const instance: Store = API.make(model);\n' +
    '// @ts-expect-error private type alias is not a namespace export\ntype Hidden = API.Id;\n' +
    '// @ts-expect-error id must be numeric\nnew Store({id: "invalid"});');
  const program = ts.createProgram([consumer, checkAccessorConsumer()], {...options, noEmit: true, types: []});
  assert.deepEqual(ts.getPreEmitDiagnostics(program).map(d => ts.flattenDiagnosticMessageText(d.messageText, '\n')), []);
  if (process.argv.includes('--corpus')) {
    checkAccessorTypes();
    if (!checkUpstream('compiler')) process.exitCode = 1;
  }
  if (process.argv.includes('--namespaces') && !checkUpstream('conformance/internalModules')) process.exitCode = 1;
  if (process.argv.includes('--computed') && !checkUpstream('conformance/es6/computedProperties')) process.exitCode = 1;
  console.log('Declaration CLI and SDK matched TypeScript ' + ts.version + ' on ' + (positive.length + negative.length + 2) + ' inputs.');
} finally {
  fs.rmSync(dir, { recursive: true, force: true });
}
