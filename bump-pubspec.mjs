import { readFileSync, writeFileSync } from 'node:fs';

const version = process.argv[2];
if (!version) {
  console.error('Usage: node bump-pubspec.mjs <version>');
  process.exit(1);
}

const paths = [
  'packages/testcontainers_core/pubspec.yaml',
  'packages/testcontainers_compose/pubspec.yaml',
];

for (const p of paths) {
  const content = readFileSync(p, 'utf-8');
  const updated = content.replace(/^version:\s+\S+/m, `version: ${version}`);
  if (updated === content) {
    console.error(`ERROR: no version line found in ${p}`);
    process.exit(1);
  }
  writeFileSync(p, updated);
  console.log(`Bumped ${p} to ${version}`);
}
