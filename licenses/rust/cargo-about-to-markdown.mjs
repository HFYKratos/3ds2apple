#!/usr/bin/env node
// Turns a cargo-about JSON report (cargo about generate --format json) into the
// compact Markdown section embedded in THIRD_PARTY.md.
//
// Usage:
//   node licenses/rust/cargo-about-to-markdown.mjs REPORT.json "Section title"
//
// Writes REPORT.md next to REPORT.json and prints a one-line summary.
// Third-party crates only: the project's own workspace crates are skipped.
import fs from 'node:fs';
import crypto from 'node:crypto';

const [jsonPath, title] = process.argv.slice(2);
if (!jsonPath || !title) {
  console.error('usage: node cargo-about-to-markdown.mjs REPORT.json "Section title"');
  process.exit(2);
}

// Workspace crates of this repository are not third-party dependencies.
const ownNames = new Set(['builder-core', 'builder-pack', 'devpush', 'zakuro-ios']);

const report = JSON.parse(fs.readFileSync(jsonPath, 'utf8'));
const thirdParty = report.crates.filter(
  (crate) => crate.package.source && !ownNames.has(crate.package.name),
);

const rows = thirdParty
  .map((crate) => ({
    name: crate.package.name,
    version: crate.package.version,
    license: crate.license || crate.package.license || 'UNKNOWN',
    repository: crate.package.repository || '',
  }))
  .sort((a, b) => a.name.localeCompare(b.name) || a.version.localeCompare(b.version));

// cargo-about groups licence files by their exact text (one entry per crate
// licence file), so the same SPDX id can appear several times; dedupe by
// id+text hash and keep one copy of every distinct licence text (copyright
// lines included).
const groups = new Map();
for (const license of report.licenses) {
  const text = (license.text || '').trim();
  const hash = crypto.createHash('sha256').update(text).digest('hex').slice(0, 16);
  const key = license.id + '|' + hash;
  let group = groups.get(key);
  if (!group) {
    group = { id: license.id, name: license.name, text, crates: new Set() };
    groups.set(key, group);
  }
  for (const usedBy of license.used_by || []) {
    const crate = usedBy.crate || usedBy;
    if (ownNames.has(crate.name)) continue;
    group.crates.add(crate.name + ' ' + crate.version);
  }
}
const ordered = [...groups.values()].sort((a, b) => a.id.localeCompare(b.id));

const lines = [];
lines.push('### ' + title);
lines.push('');
lines.push('Generated with `cargo-about 0.9.3` from the crate graph pinned in the');
lines.push('workspace `Cargo.lock` (third-party crates only; this repository\'s own');
lines.push('crates are excluded).');
lines.push('');
lines.push('| Crate | Version | License | Repository |');
lines.push('|---|---|---|---|');
for (const row of rows) {
  lines.push('| `' + row.name + '` | ' + row.version + ' | `' + row.license + '` | ' +
    (row.repository || '-') + ' |');
}
lines.push('');
lines.push('#### License texts');
lines.push('');
for (const group of ordered) {
  lines.push('##### ' + group.name + ' (`' + group.id + '`)');
  lines.push('');
  lines.push('Crates covered by this license text: ' +
    ([...group.crates].sort().join(', ') || '(none)'));
  lines.push('');
  lines.push('```text');
  lines.push(group.text);
  lines.push('```');
  lines.push('');
}

const outPath = jsonPath.replace(/\.json$/, '.md');
fs.writeFileSync(outPath, lines.join('\n'));
console.log('wrote ' + outPath + ': ' + rows.length + ' crates, ' + ordered.length +
  ' licence texts, ' + fs.statSync(outPath).size + ' bytes');
