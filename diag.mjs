// Diagnostic: print semantic-release-pub version and prepare.js contents
import { readFileSync } from 'node:fs';

const pkgJson = JSON.parse(readFileSync('./node_modules/semantic-release-pub/package.json', 'utf-8'));
console.log('=== semantic-release-pub version:', pkgJson.version, '===');

const prepareSrc = readFileSync('./node_modules/semantic-release-pub/dist/prepare.js', 'utf-8');
console.log('=== prepare.js ===');
console.log(prepareSrc);

const utilsSrc = readFileSync('./node_modules/semantic-release-pub/dist/utils.js', 'utf-8');
console.log('=== utils.js (first 40 lines) ===');
console.log(utilsSrc.split('\n').slice(0, 40).join('\n'));
