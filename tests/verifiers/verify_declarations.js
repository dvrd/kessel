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
  // One direct return is inferred wherever it sits in the body.
  'export function pick() { if (ready) { log() } return 1; cleanup(); }',
  'import fs = require("fs"); var hidden = compute(); export const size: number = 1;',
  'export class Nil extends null {}',
  'export class Secret { private get key() { return 1 } private set key(v) {} private run(): void; private run(x?: any) {} }',
  'export class Point { constructor(public x?: string, private y?: number, readonly z: number = 1) {} }',
  'export const table = {"a-b": 1, "ok": 2, 0x10: 3, a: 6, "a": "x", [true]: 4};',
  'declare namespace N { enum E { A, B = 5, C } const enum F { A, B } }',
  'declare module "m" { export enum E { A = 0, B = A + 1 } }',
  'declare module "m" { export default class C {} }',
  'export enum Big { a = 1 / 0, b = -1 / 0, c = 0 / 0 }',
  'interface Shape { side: number } export default Shape;',
  'type Foo = number; export const Foo = 1; export default Foo;',
  'import x from "y"; declare module "express" { interface Request { id: number } }',
  'import {key} from "./keys"; export function read({ [key]: value }: any): string { return "" }',
  'import * as E from "effects"; export const run = <E>(input: () => E.Result<E>): E.Result<E> => input();',
  'declare module "m" { import unused = require("fs"); import used = require("g"); export const x: used.T; }',
  'export * from "pkg" with { type: "json" }; export type { R } from "types" with { "resolution-mode": "import" };',
  // Assignments inside a nested function or an object literal belong to that container.
  'export function Foo(): void {} function g() { Foo.a = 1 } const z = { p: Foo.b = 2 }; Foo.c ||= 3;',
  '{ let a = ""; function k() {} } export let b: typeof a; export let c: typeof k;',
  'function g() { return import.meta.url } var hidden = compute(); export const size: number = 1;',
  'export function pick<T>() { if (ready) { type U = number; } return null! as T | U }',
  // A leading generic function type argument is parenthesized, as TypeScript prints it.
  'export declare const a: X<<T>() => T>; export interface I { p: X<(<U>() => U), <V>(x: V) => V>; q: Array<new <T>() => T>; r: Array<new () => void> }',
  // An extends clause that is not a name declares a `_base` constant of the inferred type.
  'const C_base = 1; export class C extends (null) {} export class D extends (load() as Ctor)<string> { p: number = 1 }',
  'export namespace N { export class C extends ({} as {new(): I}) {} } export default class extends (() => 1) {}',
  'class C { static constructor() {} }',
  'interface SymbolConstructor { foo: string } var Symbol: SymbolConstructor; var obj = { [Symbol.foo]: 0 };',
  'enum E1 { X = Y, X1 = E1["Y"], Y = E1.Z, Y1 = E1["Z"], S = S } enum E1 { Z = 4 }',
  'global { interface Array<T> { x } } namespace A { declare global { interface Array<T> { y } } }',
  'var total = 1 + count as number, less = a < b as boolean;',
  'export const first = (...[a, b]: Bar[]): void => {}; export function size(...{length}: string[]): void {}',
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
  'export function pick() { if (ready) { return 1 } }',
  'export const a = 10 satisfies number;',
  'export function f(a = 1 /* s */ satisfies number): void {}',
  'var x = 10; var x = 10;',
  'export enum E { a } export enum E { c = a }',
  'export const f: (a, b?) => void = null!;',
  'export function f(d?, ...rest): void {}',
  'export function f({x} = {x: 10}, [a] = [1, 2], {b}): void {}',
  'type U = number; export class C { constructor(public x?: U) {} }',
  'export class C extends class {} {}',
  'export const f = async function () {};',
  'declare var p: number | number[]; declare var s: string; export class C { [p]() {} [s]() {} }',
  'export const o = { [true]: lookup() };',
  'const key = make(); export class C { [key]: number }',
  // Names that exist in the source scope but not at the declaration's scope.
  '{ var a = ""; } export let b: typeof a;',
  'export function bar(): typeof b { var b = 1; return undefined; }',
  'export function bar() { type T = number; return 1 as T }',
  'export const o = { m() { type T = number; return (x: T) => 1 }, get g() { type U = 1; return 1 as U } };',
  '{ var a = ""; } export class C { static m(q: typeof a): typeof a { return q } set s(v: typeof a) {} constructor(public d: typeof a) {} }',
  '{ var a = class {}; } export class C extends a { p: typeof a; get g(): typeof a { return a } } export type T = typeof a;',
  'export function Foo(): void {} if (ready) { Foo.a = 1 } call(Foo.b = 2); Foo.c = Foo.d = 3;',
  'declare namespace app { function foo(): void; } app.foo.bar = 1; app.foo.bar = 2;',
  'namespace M { export namespace N { export enum E1 { a = 1 } } } export enum E2 { b = M.N.E1.a, c = M.N.E1.a.a }',
  'await ready; const arr = [load()];',
  'export class C extends mixin(Base) {} export class D extends (x satisfies Ctor) {}',
  'declare global { interface Array<T> { x } }',
  // After a member that cannot be declared, only reusable function nodes are still checked.
  'var b: any; export var x = { b, a: lookup(), n: { c: lookup() }, d(p) { return 1 }, e: (q) => lookup() };',
  'var b: any; export var x = { ...b, a: lookup(), d(p) {} };',
  'declare var s: string; export var x = { [s]: 1, a: lookup(), d() {} };',
  'export function f(x = 1, y = unknown, w: number): void {}',
  'enum G { A } export class C { [G.A]() {} }',
  'export const C = @dec class {}; export class D extends (class { foo() {} }) {}',
  'export function f({[foo]: bar}: any): void { var foo = 1 }',
  'export const f = async i => await load(i);',
];
// Differences from TypeScript that are intended. Each entry is a fixture that
// must still differ: a fixed or newly broken fixture fails the comparison.
const PARSER_EARLY_ERROR = 'Kessel reports an early error and emits nothing. tsc rejects the same ' +
  'program (TS2464, TS2466, TS1102, TS2393 or TS1049) but transpileDeclaration skips those checks.';
const CHECKER_FALLBACK = 'Both tools reject the file with TS9038. TypeScript adds or drops TS9008 on ' +
  'sibling methods after its checker merges their inferred types, which needs type information.';
const INVALID_NAMESPACE = 'A deliberately invalid input that Kessel rejects; transpileDeclaration ' +
  'emits declarations for it. oxc 0.127.0 also reports errors for this file.';
const documented = {
  'conformance/internalModules': {
    'moduleBody/invalidModuleWithStatementsOfEveryKind.ts / moduleBody/invalidModuleWithStatementsOfEveryKind.ts': INVALID_NAMESPACE,
    'moduleBody/invalidModuleWithVarStatements.ts / moduleBody/invalidModuleWithVarStatements.ts': INVALID_NAMESPACE,
  },
  'conformance/es6/computedProperties': {},
};
for (const target of ['ES5', 'ES6']) {
  const computed = documented['conformance/es6/computedProperties'];
  for (const id of [3, 14, 17, 24, 26, 27, 40, 49, 50]) {
    const name = 'computedPropertyNames' + id + '_' + target + '.ts';
    computed[name + ' / ' + name] = PARSER_EARLY_ERROR;
  }
  for (const stem of ['computedPropertyNames10', 'computedPropertyNames13', 'computedPropertyNamesDeclarationEmit5']) {
    const name = stem + '_' + target + '.ts';
    computed[name + ' / ' + name] = CHECKER_FALLBACK;
  }
}
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
// TypeScript's own output for an invalid input is not always parseable. Such
// text only matches byte for byte, so unparseable Kessel output never matches.
function looseTree(text) {
  try { return tree(text); } catch (error) { return ['unparseable', text]; }
}
// Compare every TypeScript input under a fixture directory. Each difference is
// classified so that parser rejections stay separate from emitter differences.
function compareUpstream(directory, only) {
  const corpus = path.resolve('tests/vendor/typescript/tests/cases', directory);
  const filenames = only ? only.slice() : directory === 'compiler/isolatedDeclarations'
    ? fs.readdirSync(path.dirname(corpus)).filter(name => /^isolatedDeclaration.*\.tsx?$/.test(name))
    : fs.readdirSync(corpus, { recursive: true }).filter(name => /\.tsx?$/.test(name) && !/\.d\.ts$/.test(name));
  const root = directory === 'compiler/isolatedDeclarations' ? path.dirname(corpus) : corpus;
  const result = { count: 0, matchingDiagnostics: 0, matchingOutput: 0, valid: 0, unavailable: 0, gaps: [] };
  for (const filename of filenames.sort()) {
    const text = fs.readFileSync(path.join(root, filename), 'utf8');
    const split = text.split(/^\s*\/\/\s*@filename:\s*(.+?)\s*$/gmi);
    const units = split.length === 1 ? [[filename, text]] : [];
    for (let i = 1; i < split.length; i += 2) units.push([split[i], split[i + 1]]);
    for (const [name, source] of units) {
      if (!/\.tsx?$/.test(name) || /\.d\.ts$/.test(name)) continue;
      // A few fixtures crash TypeScript itself (a stack overflow or an internal
      // TypeError). They have no reference, so they are counted and not compared.
      let reference;
      try {
        reference = ts.transpileDeclaration(source, {fileName: name, compilerOptions: options});
      } catch (error) {
        result.unavailable++;
        continue;
      }
      const actual = isolatedDeclarationSync(name, source);
      const expected = reference.diagnostics.map(d => [
        'TS' + d.code, Buffer.byteLength(source.slice(0, d.start)),
        Buffer.byteLength(source.slice(0, d.start + d.length)), d.messageText,
      ].join('|')).sort();
      const got = actual.errors.map(e => [e.code, e.start, e.end, e.message].join('|')).sort();
      const matches = JSON.stringify(expected) === JSON.stringify(got);
      if (matches) result.matchingDiagnostics++;
      let outputMatches = true;
      if (expected.length === 0) {
        result.valid++;
        outputMatches = got.length === 0 && JSON.stringify(looseTree(reference.outputText)) === JSON.stringify(looseTree(actual.output));
        if (outputMatches) result.matchingOutput++;
      }
      result.count++;
      if (matches && outputMatches) continue;
      let category = 'output';
      if (actual.errors.some(e => e.code === 'Invalid_Syntax')) {
        const kind = /\.tsx$/.test(name) ? ts.ScriptKind.TSX : ts.ScriptKind.TS;
        const parsed = ts.createSourceFile(name, source, ts.ScriptTarget.ESNext, false, kind);
        category = parsed.parseDiagnostics.length ? 'parser-syntax' : 'parser-early-error';
      } else if (!matches) {
        category = expected.length === 0 ? 'kessel-rejects' : got.length === 0 ? 'kessel-accepts' : 'diagnostics';
      }
      result.gaps.push({ key: filename + ' / ' + name, category });
    }
  }
  assert.ok(result.count > 0, 'TypeScript declaration compiler fixtures are required');
  return result;
}
function checkUpstream(directory) {
  const result = compareUpstream(directory);
  const known = documented[directory] || {};
  const gaps = result.gaps.map(gap => gap.key);
  const unexpected = gaps.filter(gap => !(gap in known));
  const stale = Object.keys(known).filter(gap => !gaps.includes(gap));
  console.log(result.count + ' compiler inputs, ' + result.matchingDiagnostics + ' exact diagnostic sets, ' +
    result.matchingOutput + '/' + result.valid + ' declaration ASTs matched, ' +
    (gaps.length - unexpected.length) + ' documented differences.');
  for (const gap of unexpected) console.log('Difference in ' + gap);
  for (const gap of stale) console.log('Documented difference no longer occurs in ' + gap);
  return unexpected.length === 0 && stale.length === 0;
}
// Upstream inputs that once produced unparseable or silently wrong output.
// They must keep matching TypeScript exactly, whatever the broad list records.
const pinned = {
  compiler: [
    'specializedLambdaTypeArguments.ts', 'importTypeWithUnparenthesizedGenericFunctionParsed.ts',
    'contextualReturnTypeOfIIFE2.ts', 'declarationEmitNestedAnonymousMappedType.ts',
    'declarationEmitVarInElidedBlock.ts', 'enumBasics3.ts', 'functionVariableInReturnTypeAnnotation.ts',
  ],
  conformance: ['externalModules/topLevelAwaitNonModule.ts'],
};
function checkPinned() {
  let matched = 0;
  let total = 0;
  for (const directory of Object.keys(pinned)) {
    const result = compareUpstream(directory, pinned[directory]);
    total += result.count;
    matched += result.count - result.gaps.length;
    for (const gap of result.gaps) console.log('Pinned input differs: ' + directory + '/' + gap.key);
  }
  assert.ok(total >= 8, 'every pinned fixture must be present');
  console.log(matched + '/' + total + ' pinned upstream inputs matched.');
  return matched === total;
}
// The whole compiler and conformance directories are far larger than the
// focused suites. A checked-in list names every input where the emitter (not
// the parser) differs, so a regression or an unrecorded fix fails the run.
// Parser rejections are counted but not listed: the parser is tested elsewhere.
function checkBroad(update) {
  const baseline = path.resolve('tests/baselines/dts_typescript_differences.txt');
  const lines = [];
  for (const directory of ['compiler', 'conformance']) {
    const result = compareUpstream(directory);
    const counts = {};
    for (const gap of result.gaps) {
      counts[gap.category] = (counts[gap.category] || 0) + 1;
      if (!gap.category.startsWith('parser-')) lines.push([gap.category, directory, gap.key].join('\t'));
    }
    console.log(directory + ': ' + result.count + ' inputs, ' + result.matchingDiagnostics +
      ' exact diagnostic sets, ' + result.matchingOutput + '/' + result.valid + ' declaration ASTs matched, ' +
      result.unavailable + ' without a reference.');
    console.log('  ' + Object.keys(counts).sort().map(name => name + ' ' + counts[name]).join(', '));
  }
  lines.sort();
  if (update) {
    fs.writeFileSync(baseline, lines.join('\n') + '\n');
    console.log('Wrote ' + lines.length + ' emitter differences to ' + path.relative('.', baseline) + '.');
    return true;
  }
  const recorded = fs.readFileSync(baseline, 'utf8').split('\n').filter(line => line !== '');
  const added = lines.filter(line => !recorded.includes(line));
  const removed = recorded.filter(line => !lines.includes(line));
  for (const line of added) console.log('New difference: ' + line);
  for (const line of removed) console.log('Recorded difference no longer occurs: ' + line);
  console.log(lines.length + ' emitter differences, ' + recorded.length + ' recorded.');
  return added.length === 0 && removed.length === 0;
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
    if (!checkUpstream('compiler/isolatedDeclarations')) process.exitCode = 1;
    if (!checkPinned()) process.exitCode = 1;
  }
  if (process.argv.includes('--broad') && !checkBroad(process.argv.includes('--update'))) process.exitCode = 1;
  if (process.argv.includes('--namespaces') && !checkUpstream('conformance/internalModules')) process.exitCode = 1;
  if (process.argv.includes('--computed') && !checkUpstream('conformance/es6/computedProperties')) process.exitCode = 1;
  console.log('Declaration CLI and SDK matched TypeScript ' + ts.version + ' on ' + (positive.length + negative.length + 2) + ' inputs.');
} finally {
  fs.rmSync(dir, { recursive: true, force: true });
}
