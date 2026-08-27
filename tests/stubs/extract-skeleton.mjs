// Stands in for the real extract-skeleton.mjs inside the test suite.
//
// The real one reads a transcript and produces a condensed skeleton. What the
// tests need from it is only its OUTPUT CONTRACT and, above all, its size:
// Do-Refresh embeds the skeleton into the prompt it pipes to claude, and a
// realistic skeleton is far larger than the ~32K a Windows command line holds.
// A small fixture here would let the argument-passing bug pass unnoticed,
// which is exactly how it survived the first time.
//
// argv: [oldJsonl, sessionDesc, outDir]
// Writes <guid>-skeleton.md and <guid>-transcript.md into outDir, where <guid>
// is the basename of oldJsonl, matching what Do-Refresh looks for.
import { writeFileSync } from 'node:fs';
import { basename, join } from 'node:path';

const [oldJsonl, desc, outDir] = process.argv.slice(2);
const guid = basename(oldJsonl, '.jsonl');

const kb = Number(process.env.CLAUDECM_SKELETON_KB || '80');
const line = '- decision: the parser keeps its own lookahead buffer, see notes\n';
let body = `# Skeleton for ${desc}\n\n`;
while (body.length < kb * 1024) body += line;

writeFileSync(join(outDir, `${guid}-skeleton.md`), body, 'utf8');
writeFileSync(join(outDir, `${guid}-transcript.md`), `filtered transcript for ${desc}\n`, 'utf8');
