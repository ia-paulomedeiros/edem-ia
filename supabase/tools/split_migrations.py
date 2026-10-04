#!/usr/bin/env python3
"""Divide migrations grandes em partes menores para colar no SQL Editor do Supabase.

As partes são geradas a partir dos arquivos canônicos (014, 015, 016, 017): nunca edite uma parte.
Cada parte corta só entre seções de topo (fora de corpo de função), cabe em ~28 KB, é
idempotente como o arquivo inteiro e termina com um SELECT que diz se tudo foi criado.

Uso:  python3 supabase/tools/split_migrations.py           # (re)gera supabase/partes/
      python3 supabase/tools/split_migrations.py --check   # falha se as partes estiverem velhas
"""
import os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCES = ['014_paridade_regras.sql', '015_paridade_automacoes.sql', '016_placeholders_laquila.sql', '017_mensageria.sql']
OUTDIR = os.path.join(ROOT, 'partes')
LIMIT = 29_000          # bytes por parte, já com cabeçalho e verificação (o pedido é < 30 KB)

DOLLAR = re.compile(r'\$[A-Za-z_]*\$')

def statement_safe_points(lines):
    """Índices de linha onde se pode cortar: fora de string com dólar e sem comando aberto."""
    inside = None           # tag de dólar aberta ($$, $p$, $function$ ...)
    pending = False         # comando começado e ainda sem ';'
    safe = set()
    for i, line in enumerate(lines):
        if inside is None and not pending:
            safe.add(i)
        pos = 0
        while pos <= len(line):
            if inside:
                j = line.find(inside, pos)
                if j < 0: break
                pos = j + len(inside); inside = None; pending = True
                continue
            rest = line[pos:]
            c = rest.find('--'); m = DOLLAR.search(rest); q = rest.find(';')
            cands = [(x, k) for x, k in ((c, 'c'), (m.start() if m else -1, 'd'), (q, 'q')) if x >= 0]
            if not cands:
                if rest.strip(): pending = True
                break
            x, k = min(cands)
            if rest[:x].strip(): pending = True
            if k == 'c': break
            if k == 'd': inside = m.group(0); pos += m.end(); pending = True
            else: pending = False; pos += x + 1
    safe.add(len(lines))
    return safe

def section_starts(lines, safe):
    """Cortes possíveis: comentário de topo (coluna 0) depois de linha em branco, fora de comando."""
    return [i for i in range(1, len(lines))
            if i in safe and lines[i].startswith('-- ') and not lines[i - 1].strip()]

def objects(sql):
    funcs = sorted(set(re.findall(r'create or replace function public\.(\w+)', sql, re.I)))
    views = sorted(set(re.findall(r'create or replace view public\.(\w+)', sql, re.I)))
    tables = sorted(set(re.findall(r'create table if not exists public\.(\w+)', sql, re.I)))
    cols = []
    for m in re.finditer(r'alter table public\.(\w+)((?:\s*add column if not exists \w+[^,;]*,?)+)', sql, re.I):
        for c in re.findall(r'add column if not exists (\w+)', m.group(2), re.I):
            cols.append((m.group(1), c))
    for m in re.finditer(r"alter table public\.(\w+) add column (?!if\b)(\w+)", sql, re.I):
        if (m.group(1), m.group(2)) not in cols: cols.append((m.group(1), m.group(2)))
    dropped = set(re.findall(r'drop function if exists public\.(\w+)', sql, re.I))
    return funcs, views, tables, cols, dropped

def verification(tag, sql):
    funcs, views, tables, cols, _ = objects(sql)
    checks = []
    for f in funcs:
        checks.append(f"('função {f}', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = '{f}'))")
    for v in views + tables:
        checks.append(f"('{'view' if v in views else 'tabela'} {v}', to_regclass('public.{v}') is not null)")
    for t, c in cols:
        checks.append(f"('coluna {t}.{c}', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = '{t}' and column_name = '{c}'))")
    if not checks:
        checks.append("('nada a conferir', true)")
    body = ",\n    ".join(checks)
    return (f"\n-- ---------- Verificação da parte {tag}: deve voltar uma linha com resultado = OK\n"
            f"select '{tag}' as parte,\n"
            f"       case when bool_and(ok) then 'OK' else 'FALTOU: ' || string_agg(item, ', ') filter (where not ok) end as resultado,\n"
            f"       count(*) filter (where ok) || ' de ' || count(*) || ' itens' as conferidos\n"
            f"from (values\n    {body}\n) as v(item, ok);\n")

def build():
    files = {}
    for src in SOURCES:
        text = open(os.path.join(ROOT, src), encoding='utf-8').read()
        lines = text.splitlines(keepends=True)
        safe = statement_safe_points(lines)
        starts = [0] + [s for s in section_starts(lines, safe) if s > 0] + [len(lines)]
        starts = sorted(set(starts))
        # empacota seções consecutivas até o limite (cabeçalho + verificação contam)
        def final_size(a, b):
            body = ''.join(lines[a:b]); return len(body.encode()) + 900 + len(verification('x', body).encode())
        chunks, cur_start = [], 0
        for a, b in zip(starts, starts[1:]):
            if a > cur_start and final_size(cur_start, b) > LIMIT:
                chunks.append((cur_start, a)); cur_start = a
        chunks.append((cur_start, len(lines)))
        base = src[:3]
        total = len(chunks)
        for k, (a, b) in enumerate(chunks):
            tag = f"{base}{chr(ord('a') + k)}"
            body = ''.join(lines[a:b])

            i_src = SOURCES.index(src)
            prev = (f"{base}{chr(ord('a') + k - 1)}" if k
                    else (f"{SOURCES[i_src - 1][:3]} inteira (todas as partes {SOURCES[i_src - 1][:3]}*)" if i_src else '013'))
            head = (f"-- =============================================================================\n"
                    f"-- {tag} — parte {k + 1} de {total} de supabase/{src}\n"
                    f"-- GERADA por supabase/tools/split_migrations.py; não edite (edite o arquivo canônico).\n"
                    f"-- Rode depois de: {prev}. Idempotente: pode rodar de novo sem estragar nada.\n"
                    f"-- No SQL Editor: Cmd+A, Run. Se aparecer o aviso de operação destrutiva (drop de\n"
                    f"-- função/constraint antiga que esta parte recria), confirme. A última linha do\n"
                    f"-- resultado tem que dizer resultado = OK.\n"
                    f"-- =============================================================================\n\n")
            files[f"{tag}.sql"] = head + body.rstrip('\n') + '\n' + verification(tag, body)
    return files

def main():
    files = build()
    if '--check' in sys.argv:
        stale = [n for n, c in files.items()
                 if not os.path.exists(os.path.join(OUTDIR, n)) or open(os.path.join(OUTDIR, n), encoding='utf-8').read() != c]
        extra = [n for n in (os.listdir(OUTDIR) if os.path.isdir(OUTDIR) else []) if n.endswith('.sql') and n not in files]
        if stale or extra:
            sys.exit(f"partes desatualizadas: {stale + extra}. Rode: python3 supabase/tools/split_migrations.py")
        print('partes em dia'); return
    os.makedirs(OUTDIR, exist_ok=True)
    for n in os.listdir(OUTDIR):
        if n.endswith('.sql') and n not in files: os.remove(os.path.join(OUTDIR, n))
    for n, c in sorted(files.items()):
        if len(c.encode()) > 30_000:
            sys.exit(f"{n}: {len(c.encode())} bytes (> 30 KB); quebre a seção no arquivo canônico com um comentário de topo")
        open(os.path.join(OUTDIR, n), 'w', encoding='utf-8').write(c)
        print(f"{n:10s} {len(c.encode()):6d} bytes")

if __name__ == '__main__':
    main()
