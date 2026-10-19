#!/usr/bin/env node
/*
 * 起点 Fock（wasm2js 产物）→ LuaJIT 转译器。开发期工具，运行时不用。
 *
 * 用法：node tools/gen_fock.js <Fock.js> <输出.lua>
 * 依赖：npm i acorn（仅开发机）。
 *
 * 只认 wasm2js 产出的 asm.js 子集：int32 运算、七种堆视图、labeled block /
 * switch / for 循环、函数表 call_indirect。表达式里的赋值 / 逗号 / 三目 / 短路
 * 提成语句并按求值顺序落临时变量；break / continue 用 goto。
 */
"use strict";
const acorn = require("acorn");
const fs = require("fs");

const [, , srcPath, outPath] = process.argv;
const src = fs.readFileSync(srcPath, "utf8");
const a = src.indexOf("this.exports=function(A){");
const e = src.search(/\}\(A\)\}\(\w+\)\},instantiate/);
if (a < 0 || e < 0) throw new Error("找不到 wasm2js 导出函数");
const code = "(" + src.slice(a + "this.exports=".length, e + "}(A)}".length) + ")";
const ast = acorn.parse(code, { ecmaVersion: 2020 });
const outer = ast.body[0].expression;
const inner = outer.body.body.find((n) => n.type === "ReturnStatement").argument.callee;
const top = inner.body.body;

// 变量名每个构建都不同：从模块头的 var 声明按位置推。顺序固定为
// 七个堆视图、imul、abs、clz32、abort、导入 b..f、栈指针 B、一个恒 0 的全局 Iv。
const HEAP_KIND = { Int8Array: "I8", Int16Array: "I16", Int32Array: "I32", Uint8Array: "U8", Uint16Array: "U16", Uint32Array: "U32", Float64Array: "F64" };
const HEAP = {};
const TOPVAR = { a: "rf_a", u: "rf_u", c: "rf_c", s: "rf_s" };
let STACK_INIT = 0;
(function header() {
    const decl = top.find((s) => s.type === "VariableDeclaration");
    const plain = [];
    for (const d of decl.declarations) {
        const init = d.init;
        if (init && init.type === "NewExpression" && HEAP_KIND[init.callee.name]) HEAP[d.id.name] = HEAP_KIND[init.callee.name];
        else if (init && init.type === "MemberExpression" && init.object.type === "Identifier" && init.object.name === "A" && init.property.name !== "buffer") TOPVAR[d.id.name] = init.property.name === "abort" ? "abort" : "imp_" + init.property.name;
        else if (init && init.type === "MemberExpression" && init.object.name === "Math") TOPVAR[d.id.name] = "math.abs";
        else if (init && init.type === "Identifier") plain.push(d.id.name);
        else if (init && init.type === "Literal") plain.push(d);
    }
    const idents = plain.filter((x) => typeof x === "string");
    TOPVAR[idents[0]] = "imul";
    TOPVAR[idents[1]] = "clz32";
    const lits = plain.filter((x) => typeof x !== "string");
    TOPVAR[lits[0].id.name] = "B";
    STACK_INIT = lits[0].init.value;
    TOPVAR[lits[1].id.name] = "Iv";
})();
const tableDecl = top.find((s) => s.type === "VariableDeclaration" && s.declarations.length === 2 && !s.declarations[0].init);
const TABLE = new Set(tableDecl.declarations.map((d) => d.id.name));
const fnNames = new Set(top.filter((s) => s.type === "FunctionDeclaration").map((s) => s.id.name));
const fnRef = (n) => "F.f" + n.replace(/\$/g, "S_");

let tmpCount = 0;
let labelCount = 0;

function collectVars(fn) {
    const names = new Set(fn.params.map((p) => p.name));
    const vars = new Set();
    (function walk(n) {
        if (!n || typeof n.type !== "string") return;
        if (n !== fn && (n.type === "FunctionExpression" || n.type === "FunctionDeclaration")) return;
        if (n.type === "VariableDeclarator") vars.add(n.id.name);
        for (const k of Object.keys(n)) {
            const v = n[k];
            if (Array.isArray(v)) v.forEach(walk);
            else if (v && typeof v.type === "string") walk(v);
        }
    })(fn.body);
    for (const p of names) vars.delete(p);
    return { params: [...names], vars: [...vars], all: new Set([...names, ...vars]) };
}

class Fn {
    constructor(node) {
        this.scope = collectVars(node);
        this.node = node;
        this.out = [];
        this.targets = [];
    }

    name(id) {
        if (this.scope.all.has(id)) return "v_" + id;
        if (HEAP[id]) throw new Error("heap view used as value: " + id);
        if (TOPVAR[id]) return TOPVAR[id];
        if (TABLE.has(id)) return "UA";
        if (fnNames.has(id)) return fnRef(id);
        throw new Error("unresolved identifier " + id);
    }

    isHeap(id) {
        return HEAP[id] && !this.scope.all.has(id);
    }

    tmp() {
        return "t" + ++tmpCount;
    }

    push(s) {
        this.out.push(s);
    }

    // ---- 类型转换 ----
    num(r) {
        return r.t === "b" ? `(${r.s} and 1 or 0)` : r.s;
    }

    cond(r) {
        return r.t === "b" ? r.s : `(${r.s} ~= 0)`;
    }

    // 带小数的值（除法结果）转 int32 前先截断
    int(r) {
        const s = this.num(r);
        return r.frac ? `toint(${s})` : s;
    }

    // 按顺序求值一组表达式；后面的操作数产生了语句时，把前面的结果落到临时变量里
    operands(nodes, discards) {
        const res = [];
        for (const node of nodes) {
            const mark = this.out.length;
            const r = this.emit(node);
            if (this.out.length > mark) {
                let at = mark;
                for (const prev of res) {
                    if (!prev.lit && !prev.tmp) {
                        const t = this.tmp();
                        this.out.splice(at++, 0, `local ${t} = ${prev.t === "b" ? prev.s : this.num(prev)}`);
                        prev.s = t;
                        prev.tmp = true;
                        prev.frac = prev.frac;
                        prev.call = false;
                    }
                }
            }
            res.push(r);
        }
        return res;
    }

    // ---- 表达式 ----
    emit(node, discard) {
        switch (node.type) {
            case "Literal":
                if (typeof node.value !== "number") throw new Error("非数字字面量 " + node.raw);
                return { s: String(node.value), t: "n", lit: true };
            case "Identifier":
                if (node.name === "undefined") return { s: "nil", t: "u", lit: true };
                return { s: this.name(node.name), t: "n" };
            case "MemberExpression":
                return this.member(node);
            case "CallExpression":
                return this.call(node);
            case "UnaryExpression":
                return this.unary(node);
            case "BinaryExpression":
                return this.binary(node);
            case "LogicalExpression":
                return this.logical(node, discard);
            case "ConditionalExpression":
                return this.conditional(node, discard);
            case "AssignmentExpression":
                return this.assign(node, discard);
            case "UpdateExpression":
                return this.update(node, discard);
            case "SequenceExpression":
                return this.sequence(node, discard);
            default:
                throw new Error("不支持的表达式 " + node.type);
        }
    }

    member(node) {
        if (!node.computed) {
            if (node.property.name === "byteLength") return { s: "16777216", t: "n" };
            throw new Error("非计算成员访问 " + code.slice(node.start, node.end));
        }
        const idx = this.operands([node.property])[0];
        if (node.object.type === "Identifier" && this.isHeap(node.object.name)) {
            return { s: `${HEAP[node.object.name]}[${this.int(idx)}]`, t: "n" };
        }
        return { s: `${this.emit(node.object).s}[${this.int(idx)}]`, t: "n", call: false };
    }

    call(node) {
        let callee;
        const argNodes = node.arguments;
        if (node.callee.type === "Identifier") {
            const n = node.callee.name;
            if (this.scope.all.has(n)) throw new Error("调用局部变量 " + n);
            callee = this.name(n);
        } else if (node.callee.type === "MemberExpression") {
            const r = this.operands([node.callee.property, ...argNodes]);
            const idx = this.int(r.shift());
            return { s: `${this.emit(node.callee.object).s}[${idx}](${r.map((x) => this.num(x)).join(", ")})`, t: "n", call: true };
        } else {
            throw new Error("不支持的调用目标 " + node.callee.type);
        }
        const r = this.operands(argNodes);
        return { s: `${callee}(${r.map((x) => this.num(x)).join(", ")})`, t: "n", call: true };
    }

    unary(node) {
        const op = node.operator;
        if (op === "void") {
            this.flush(this.emit(node.argument, true));
            return { s: "nil", t: "u", lit: true };
        }
        const r = this.emit(node.argument);
        if (op === "!") return { s: `(not ${this.cond(r)})`, t: "b" };
        if (op === "-") return { s: `(-${this.num(r)})`, t: "n", frac: r.frac };
        if (op === "+") return { s: this.num(r), t: "n", frac: true };
        if (op === "~") return { s: `bnot(${this.int(r)})`, t: "n" };
        throw new Error("不支持的一元运算 " + op);
    }

    binary(node) {
        const [l, r] = this.operands([node.left, node.right]);
        const op = node.operator;
        const L = this.num(l);
        const R = this.num(r);
        switch (op) {
            case "+": return { s: `(${L} + ${R})`, t: "n" };
            case "-": return { s: `(${L} - ${R})`, t: "n" };
            case "*": return { s: `(${L} * ${R})`, t: "n" };
            case "/": return { s: `(${L} / ${R})`, t: "n", frac: true };
            case "%": return { s: `fmod(${L}, ${R})`, t: "n" };
            case "|":
                if (node.right.type === "Literal" && node.right.value === 0) return { s: `tobit(${this.int(l)})`, t: "n" };
                return { s: `bor(${this.int(l)}, ${this.int(r)})`, t: "n" };
            case "&": return { s: `band(${this.int(l)}, ${this.int(r)})`, t: "n" };
            case "^": return { s: `bxor(${this.int(l)}, ${this.int(r)})`, t: "n" };
            case "<<": return { s: `lshift(${this.int(l)}, ${this.int(r)})`, t: "n" };
            case ">>": return { s: `arshift(${this.int(l)}, ${this.int(r)})`, t: "n" };
            case ">>>":
                if (node.right.type === "Literal" && node.right.value === 0) return { s: `(tobit(${this.int(l)}) % 4294967296)`, t: "n" };
                return { s: `(rshift(${this.int(l)}, ${this.int(r)}) % 4294967296)`, t: "n" };
            case "<": case "<=": case ">": case ">=":
                return { s: `(${L} ${op} ${R})`, t: "b" };
            case "==": case "===": return { s: `(${L} == ${R})`, t: "b" };
            case "!=": case "!==": return { s: `(${L} ~= ${R})`, t: "b" };
            default: throw new Error("不支持的二元运算 " + op);
        }
    }

    // 子表达式落到独立缓冲，返回 [语句, 结果]
    sub(fn) {
        const saved = this.out;
        this.out = [];
        const r = fn();
        const stmts = this.out;
        this.out = saved;
        return [stmts, r];
    }

    // 条件上下文：返回 Lua 布尔表达式
    condOf(node) {
        if (node.type === "LogicalExpression") {
            const l = this.condOf(node.left);
            const [stmts, rc] = this.sub(() => this.condOf(node.right));
            const and = node.operator === "&&";
            if (!stmts.length) return `(${l} ${and ? "and" : "or"} ${rc})`;
            const t = this.tmp();
            this.push(`local ${t} = ${l}`);
            this.push(`if ${and ? t : "not " + t} then`);
            this.out.push(...stmts);
            this.push(`${t} = ${rc}`);
            this.push("end");
            return t;
        }
        return this.cond(this.emit(node));
    }

    logical(node, discard) {
        const and = node.operator === "&&";
        if (discard) {
            const l = this.condOf(node.left);
            const [stmts] = this.sub(() => this.flush(this.emit(node.right, true)));
            this.push(`if ${and ? l : "not " + l} then`);
            this.out.push(...stmts);
            this.push("end");
            return { s: "nil", t: "u" };
        }
        const l = this.emit(node.left);
        const t = this.tmp();
        this.push(`local ${t} = ${this.num(l)}`);
        const [stmts, r] = this.sub(() => this.emit(node.right));
        this.push(`if ${t} ${and ? "~=" : "=="} 0 then`);
        this.out.push(...stmts);
        this.push(`${t} = ${this.num(r)}`);
        this.push("end");
        return { s: t, t: "n", tmp: true };
    }

    conditional(node, discard) {
        const c = this.condOf(node.test);
        const [sa, ra] = this.sub(() => this.emit(node.consequent, discard));
        const [sb, rb] = this.sub(() => this.emit(node.alternate, discard));
        if (discard) {
            this.push(`if ${c} then`);
            this.out.push(...sa);
            this.flush(ra);
            this.push("else");
            this.out.push(...sb);
            this.flush(rb);
            this.push("end");
            return { s: "nil", t: "u" };
        }
        if (!sa.length && !sb.length) return { s: `(${c} and ${this.num(ra)} or ${this.num(rb)})`, t: "n", frac: ra.frac || rb.frac };
        const t = this.tmp();
        this.push(`local ${t}`);
        this.push(`if ${c} then`);
        this.out.push(...sa);
        this.push(`${t} = ${this.num(ra)}`);
        this.push("else");
        this.out.push(...sb);
        this.push(`${t} = ${this.num(rb)}`);
        this.push("end");
        return { s: t, t: "n", tmp: true };
    }

    sequence(node, discard) {
        const list = node.expressions;
        for (let k = 0; k < list.length - 1; k++) this.flush(this.emit(list[k], true));
        return this.emit(list[list.length - 1], discard);
    }

    // 表达式作为语句：只有调用有副作用
    flush(r) {
        if (r && r.call) this.push(r.s);
    }

    storeCoerce(view, s) {
        return view === "F64" ? s : `tobit(${s})`;
    }

    assign(node, discard) {
        let op = node.operator;
        const left = node.left;
        let right = node.right;
        if (op !== "=") {
            if (left.type !== "Identifier") throw new Error("复合赋值目标不是变量");
            right = { type: "BinaryExpression", operator: op.slice(0, -1), left, right };
        }
        if (left.type === "Identifier") {
            const target = this.name(left.name);
            const r = this.emit(right);
            this.push(`${target} = ${this.num(r)}`);
            return { s: target, t: "n", frac: r.frac };
        }
        const isHeap = left.object.type === "Identifier" && this.isHeap(left.object.name);
        const [idx, r] = this.operands([left.property, right]);
        const lhsBase = isHeap ? HEAP[left.object.name] : this.emit(left.object).s;
        const idxS = this.int(idx);
        if (discard) {
            this.push(`${lhsBase}[${idxS}] = ${isHeap ? this.storeCoerce(lhsBase, this.int(r)) : this.num(r)}`);
            return { s: "nil", t: "u" };
        }
        const t = this.tmp();
        const ti = this.tmp();
        this.push(`local ${ti} = ${idxS}`);
        this.push(`local ${t} = ${this.num(r)}`);
        this.push(`${lhsBase}[${ti}] = ${isHeap ? this.storeCoerce(lhsBase, t) : t}`);
        return { s: t, t: "n", tmp: true };
    }

    update(node, discard) {
        if (node.argument.type !== "Identifier") throw new Error("自增目标不是变量");
        const target = this.name(node.argument.name);
        const delta = node.operator === "++" ? "+" : "-";
        if (discard || node.prefix) {
            this.push(`${target} = ${target} ${delta} 1`);
            return { s: target, t: "n" };
        }
        const t = this.tmp();
        this.push(`local ${t} = ${target}`);
        this.push(`${target} = ${target} ${delta} 1`);
        return { s: t, t: "n", tmp: true };
    }

    // ---- 语句 ----
    stmt(node) {
        const before = tmpCount;
        const mark = this.out.length;
        this.stmtInner(node);
        if (tmpCount !== before) {
            this.out.splice(mark, 0, "do");
            this.out.push("end");
        }
    }

    stmts(list) {
        for (const s of list) this.stmt(s);
    }

    stmtInner(node) {
        switch (node.type) {
            case "EmptyStatement":
                return;
            case "ExpressionStatement":
                this.flush(this.emit(node.expression, true));
                return;
            case "VariableDeclaration":
                for (const d of node.declarations) {
                    if (d.init) this.flush(this.emit({ type: "AssignmentExpression", operator: "=", left: d.id, right: d.init }, true));
                }
                return;
            case "BlockStatement":
                this.stmts(node.body);
                return;
            case "ReturnStatement": {
                if (!node.argument) { this.push("do return end"); return; }
                const r = this.emit(node.argument);
                this.push(r.t === "u" ? "do return end" : `do return ${this.num(r)} end`);
                return;
            }
            case "IfStatement":
                this.ifStmt(node);
                return;
            case "ForStatement":
                this.loop(node, null);
                return;
            case "WhileStatement":
                this.loop({ type: "ForStatement", init: null, test: node.test, update: null, body: node.body }, null);
                return;
            case "LabeledStatement":
                this.labeled(node);
                return;
            case "BreakStatement":
                this.jump(node.label ? node.label.name : null, "brk");
                return;
            case "ContinueStatement":
                this.jump(node.label ? node.label.name : null, "cont");
                return;
            case "SwitchStatement":
                this.switchStmt(node, null);
                return;
            default:
                throw new Error("不支持的语句 " + node.type);
        }
    }

    ifStmt(node) {
        const c = this.condOf(node.test);
        this.push(`if ${c} then`);
        this.stmt(node.consequent);
        if (node.alternate) {
            this.push("else");
            this.stmt(node.alternate);
        }
        this.push("end");
    }

    jump(label, kind) {
        for (let k = this.targets.length - 1; k >= 0; k--) {
            const t = this.targets[k];
            let to = null;
            if (label) {
                if (t.label === label) to = kind === "brk" ? t.brk : t.cont;
            } else if (kind === "brk" ? t.loop || t.sw : t.loop) {
                to = kind === "brk" ? t.brk : t.cont;
            }
            if (to) {
                this.push(`goto ${to}`);
                return;
            }
        }
        throw new Error("找不到跳转目标 " + label + " " + kind);
    }

    labeled(node) {
        const label = node.label.name;
        const body = node.body;
        if (body.type === "ForStatement" || body.type === "WhileStatement") {
            this.loop(body.type === "WhileStatement"
                ? { type: "ForStatement", init: null, test: body.test, update: null, body: body.body }
                : body, label);
        } else if (body.type === "SwitchStatement") {
            this.switchStmt(body, label);
        } else {
            const brk = "L" + ++labelCount;
            this.targets.push({ label, brk });
            this.push("do");
            this.stmt(body);
            this.push("end");
            this.targets.pop();
            this.push(`::${brk}::`);
        }
    }

    loop(node, label) {
        const id = ++labelCount;
        const t = { label, loop: true, brk: "B" + id, cont: "C" + id };
        this.push("do");
        if (node.init) this.stmt(node.init.type === "VariableDeclaration" ? node.init : { type: "ExpressionStatement", expression: node.init });
        this.push("while true do");
        if (node.test) {
            const before = tmpCount;
            const mark = this.out.length;
            const c = this.condOf(node.test);
            this.push(`if not ${c} then goto ${t.brk} end`);
            if (tmpCount !== before) {
                this.out.splice(mark, 0, "do");
                this.push("end");
            }
        }
        this.targets.push(t);
        this.push("do");
        this.stmt(node.body);
        this.push("end");
        this.targets.pop();
        this.push(`::${t.cont}::`);
        if (node.update) this.stmt({ type: "ExpressionStatement", expression: node.update });
        this.push("end");
        this.push("end");
        this.push(`::${t.brk}::`);
    }

    switchStmt(node, label) {
        const id = ++labelCount;
        const end = "S" + id;
        const d = this.emit(node.discriminant);
        const sv = "sw" + id;
        this.push("do");
        this.push(`local ${sv} = ${this.int(d)}`);
        const cases = node.cases;
        let first = true;
        let def = null;
        cases.forEach((c, k) => {
            if (!c.test) { def = k; return; }
            const tv = this.emit(c.test);
            this.push(`${first ? "if" : "elseif"} ${sv} == ${tv.s} then goto K${id}_${k}`);
            first = false;
        });
        if (first) this.push(`goto ${def === null ? end : "K" + id + "_" + def}`);
        else this.push(`else goto ${def === null ? end : "K" + id + "_" + def} end`);
        this.targets.push({ label, sw: true, brk: end });
        cases.forEach((c, k) => {
            this.push(`::K${id}_${k}::`);
            this.push("do");
            this.stmts(c.consequent);
            this.push("end");
        });
        this.targets.pop();
        this.push("end");
        this.push(`::${end}::`);
    }

    body() {
        this.stmts(this.node.body.body);
        return this.out;
    }

    render(header) {
        const body = this.body();
        const locals = this.scope.vars.length
            ? `local ${this.scope.vars.map((v) => "v_" + v).join(", ")} = ${this.scope.vars.map(() => "0").join(", ")}`
            : "";
        return `${header}(${this.scope.params.map((p) => "v_" + p).join(", ")})\n${locals}\n${body.join("\n")}\nend`;
    }
}

function fnSource(node, header) {
    return new Fn(node).render(header);
}

const lines = [];
lines.push("-- 由 tools/gen_fock.js 从起点 / QQ阅读的 Fock（wasm2js）转译生成，勿手改。");
lines.push("-- 运行环境见 fock.lua；env = { mem = ffi uint8_t*, imp = { b, c, d, e, f, abort } }。");
lines.push("local bit = require(\"bit\")");
lines.push("local ffi = require(\"ffi\")");
lines.push("local tobit, band, bor, bxor, bnot = bit.tobit, bit.band, bit.bor, bit.bxor, bit.bnot");
lines.push("local lshift, rshift, arshift = bit.lshift, bit.rshift, bit.arshift");
lines.push("local fmod = math.fmod");
lines.push("");
lines.push("local function toint(x)");
lines.push("    return tobit(x >= 0 and math.floor(x) or -math.floor(-x))");
lines.push("end");
lines.push("");
lines.push("local function imul(a, b)");
lines.push("    a, b = tobit(a), tobit(b)");
lines.push("    return tobit(band(a, 65535) * b + lshift(tobit(rshift(a, 16) * b), 16))");
lines.push("end");
lines.push("");
lines.push("local function clz32(x)");
lines.push("    x = tobit(x)");
lines.push("    if x == 0 then return 32 end");
lines.push("    if x < 0 then return 0 end");
lines.push("    local n = 0");
lines.push("    while x > 0 do x = lshift(x, 1); n = n + 1 end");
lines.push("    return n");
lines.push("end");
lines.push("");
lines.push("return function(env)");
lines.push("local mem = env.mem");
lines.push("local abort, imp_b, imp_c, imp_d, imp_e, imp_f = env.imp.abort, env.imp.b, env.imp.c, env.imp.d, env.imp.e, env.imp.f");
lines.push("local I8, I16, I32 = ffi.cast(\"int8_t*\", mem), ffi.cast(\"int16_t*\", mem), ffi.cast(\"int32_t*\", mem)");
lines.push("local U8, U16, U32 = ffi.cast(\"uint8_t*\", mem), ffi.cast(\"uint16_t*\", mem), ffi.cast(\"uint32_t*\", mem)");
lines.push("local F64 = ffi.cast(\"double*\", mem)");
lines.push(`local B, Iv = ${STACK_INIT}, 0`);
lines.push("local scratch = ffi.new(\"int32_t[4]\")");
lines.push("local scratch_f = ffi.cast(\"double*\", scratch)");
lines.push("local function rf_a(i) return scratch[i] end");
lines.push("local function rf_u(i, v) scratch[i] = v end");
lines.push("local function rf_c() return scratch_f[0] end");
lines.push("local function rf_s(v) scratch_f[0] = v end");
lines.push("local F = {}");
lines.push("local UA = { [0] = false }");
lines.push("local YA = UA");
lines.push("");

for (const s of top) {
    if (s.type === "FunctionDeclaration") {
        lines.push(fnSource(s, fnRef(s.id.name) + " = function"));
        lines.push("");
    }
}

// 函数表
let arrayNode = null;
(function find(n) {
    if (!n || typeof n.type !== "string" || arrayNode) return;
    if (n.type === "ArrayExpression") { arrayNode = n; return; }
    for (const k of Object.keys(n)) {
        const v = n[k];
        if (Array.isArray(v)) v.forEach(find);
        else if (v && typeof v.type === "string") find(v);
    }
})(tableDecl.declarations[1].init);
arrayNode.elements.forEach((el, k) => {
    if (el === null || el.type === "Literal") return;
    if (el.type === "Identifier") lines.push(`UA[${k}] = ${fnRef(el.name)}`);
    else lines.push(fnSource(el, `UA[${k}] = function`));
});
lines.push("");

// 数据段
const dataStmt = top.find((s) => s.type === "ExpressionStatement" && [].concat(s.expression.type === "SequenceExpression" ? s.expression.expressions : [s.expression]).every((c) => c.type === "CallExpression" && c.arguments.length === 3 && c.arguments[2].type === "Literal" && typeof c.arguments[2].value === "string"));
const calls = dataStmt.expression.type === "SequenceExpression" ? dataStmt.expression.expressions : [dataStmt.expression];
lines.push("local DATA = {");
for (const c of calls) {
    const off = c.arguments[1].value;
    const b64 = c.arguments[2].value;
    lines.push(`    { ${off}, "${b64}" },`);
}
lines.push("}");
lines.push("");

// 导出
const ret = top.find((s) => s.type === "ReturnStatement");
lines.push("local exports = {}");
for (const p of ret.argument.properties) {
    const key = p.key.name;
    if (p.value.type === "FunctionExpression") lines.push(fnSource(p.value, `exports.${key} = function`));
    else if (p.value.type === "Identifier" && TABLE.has(p.value.name)) lines.push(`exports.${key} = UA`);
    else if (p.value.type === "Identifier") lines.push(`exports.${key} = ${fnRef(p.value.name)}`);
    else throw new Error("不支持的导出 " + key);
}
lines.push("return exports, DATA, function(v) B = v end, function() return B end");
lines.push("end");
fs.writeFileSync(outPath, lines.join("\n") + "\n");
console.log("generated", outPath, fs.statSync(outPath).size, "bytes");
