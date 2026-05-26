import { readFileSync } from 'node:fs';
import { parse as parseDirect } from './node_modules/yaml/dist/index.js';
import { parse as parseBare } from 'yaml';

const yamlVer = JSON.parse(readFileSync('./node_modules/yaml/package.json', 'utf-8')).version;
const data = readFileSync('packages/testcontainers_core/pubspec.yaml', 'utf-8');

const o1 = parseDirect(data);
const o2 = parseBare(data);

console.log('yaml pkg version:', yamlVer);
console.log('direct import -> version:', o1.version, '| typeof:', typeof o1.version);
console.log('bare import   -> version:', o2.version, '| typeof:', typeof o2.version);
console.log('same parse fn:', parseDirect === parseBare);
