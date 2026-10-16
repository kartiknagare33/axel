export class ExprError extends Error {}

export type Node =
  | { k: 'num'; v: number } | { k: 'str'; v: string } | { k: 'bool'; v: boolean }
  | { k: 'ref'; name: string }
  | { k: 'call'; fn: string; args: Node[] }
  | { k: 'un'; op: '-' | 'not'; e: Node }
  | { k: 'bin'; op: string; l: Node; r: Node };

const PREC: Record<string, number> = {
  or: 1, and: 2, '==': 3, '!=': 3, '<': 4, '<=': 4, '>': 4, '>=': 4,
  '+': 5, '-': 5, '*': 6, '/': 6,
};

export function tokenize(src: string): string[] {
  const re = /\s*(\d+(?:\.\d+)?|'[^']*'|"[^"]*"|[A-Za-z_][\w.]*|==|!=|<=|>=|[-+*/<>(),=])/y;
  const out: string[] = [];
  while (re.lastIndex < src.length) {
    const start = re.lastIndex;
    if (!src.slice(start).trim()) break;
    const m = re.exec(src);
    if (!m) throw new ExprError(`Unexpected character '${src.slice(start).trim()[0]}'`);
    out.push(m[1]);
  }
  return out;
}

export function parse(src: string): Node {
  const t = tokenize(src);
  let i = 0;
  const peek = () => t[i];
  const next = () => t[i++];
  const expect = (s: string) => { if (t[i] !== s) throw new ExprError(`Expected '${s}'`); i++; };
  const isIdent = (s?: string) => !!s && /^[A-Za-z_]/.test(s);

  function primary(): Node {
    const tok = next();
    if (tok === undefined) throw new ExprError('Expression ends too early');
    if (/^\d/.test(tok)) return { k: 'num', v: Number(tok) };
    if (/^['"]/.test(tok)) return { k: 'str', v: tok.slice(1, -1) };
    if (tok === '(') { const e = expr(0); expect(')'); return e; }
    if (tok === '-') return { k: 'un', op: '-', e: expr(7) };
    if (tok === 'not') return { k: 'un', op: 'not', e: expr(3) };
    if (tok === 'true' || tok === 'false') return { k: 'bool', v: tok === 'true' };
    if (isIdent(tok)) {
      if (peek() === '(') {
        next();
        const args: Node[] = [];
        if (peek() !== ')') {
          do {
            if (isIdent(peek()) && t[i + 1] === '=') i += 2;
            args.push(expr(0));
          } while (peek() === ',' && next());
        }
        expect(')');
        return { k: 'call', fn: tok, args };
      }
      return { k: 'ref', name: tok };
    }
    throw new ExprError(`Unexpected '${tok}'`);
  }

  function expr(min: number): Node {
    let l = primary();
    for (;;) {
      const op = peek();
      const p = op === undefined ? undefined : PREC[op];
      if (p === undefined || p < min) return l;
      next();
      l = { k: 'bin', op: op!, l, r: expr(p + 1) };
    }
  }

  const ast = expr(0);
  if (i !== t.length) throw new ExprError(`Unexpected '${t[i]}'`);
  return ast;
}

export interface Scope { get(name: string): unknown; call?(fn: string, args: unknown[]): unknown }

export function evaluate(n: Node, s: Scope): unknown {
  switch (n.k) {
    case 'num': case 'str': case 'bool': return n.v;
    case 'ref': return s.get(n.name);
    case 'call':
      if (!s.call) throw new ExprError(`${n.fn}() is not available here`);
      return s.call(n.fn, n.args.map(a => evaluate(a, s)));
    case 'un': {
      const v = evaluate(n.e, s);
      return n.op === 'not' ? !v : v == null ? null : -Number(v);
    }
    case 'bin': {
      if (n.op === 'and') return !!evaluate(n.l, s) && !!evaluate(n.r, s);
      if (n.op === 'or') return !!evaluate(n.l, s) || !!evaluate(n.r, s);
      const l = evaluate(n.l, s), r = evaluate(n.r, s);
      const eq = l === r || (l != null && r != null && String(l) === String(r));
      if (n.op === '==') return eq;
      if (n.op === '!=') return !eq;
      if (l == null || r == null || l === '' || r === '') return null;
      const a = Number(l), b = Number(r);
      switch (n.op) {
        case '+': return a + b;
        case '-': return a - b;
        case '*': return a * b;
        case '/': return b === 0 ? null : a / b;
        case '<': return a < b;
        case '<=': return a <= b;
        case '>': return a > b;
        case '>=': return a >= b;
      }
    }
  }
  throw new ExprError('Unknown expression');
}

export function refs(n: Node, out = { fields: new Set<string>(), calls: new Set<string>() }) {
  if (n.k === 'ref') out.fields.add(n.name);
  else if (n.k === 'call') { out.calls.add(n.fn); n.args.forEach(a => refs(a, out)); }
  else if (n.k === 'un') refs(n.e, out);
  else if (n.k === 'bin') { refs(n.l, out); refs(n.r, out); }
  return out;
}
