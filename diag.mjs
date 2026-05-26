// Monkey-patch semantic-release-pub to log the pluginConfig it receives
import { readFileSync, writeFileSync } from 'node:fs';

const preparePath = './node_modules/semantic-release-pub/dist/prepare.js';
const original = readFileSync(preparePath, 'utf-8');

// Inject a log at the top of the prepare function
const patched = original.replace(
  'export const prepare = async (pluginConfig,',
  'export const prepare = async (pluginConfig, ...rest) => { console.log("srp-pluginConfig:", JSON.stringify(pluginConfig)); return _prepare(pluginConfig, ...rest); };\nexport const _prepare = async (pluginConfig,'
);

if (patched === original) {
  console.log('PATCH FAILED - string not found');
} else {
  writeFileSync(preparePath, patched);
  console.log('Patched prepare.js to log pluginConfig');
}
