import { readFileSync } from 'node:fs';
import { parse } from './node_modules/yaml/dist/index.js';

const yamlVer = JSON.parse(readFileSync('./node_modules/yaml/package.json', 'utf-8')).version;
const data = readFileSync('packages/testcontainers_core/pubspec.yaml', 'utf-8');
const obj = parse(data);

console.log('yaml pkg version:', yamlVer);
console.log('parsed.name:', obj.name);
console.log('parsed.version:', obj.version);
console.log('typeof version:', typeof obj.version);
console.log('all keys:', Object.keys(obj).join(', '));
