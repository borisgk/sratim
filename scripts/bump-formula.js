#!/usr/bin/env node

import fs from 'node:fs';
import process from 'node:process';

const formulaPath = process.argv[2] || 'Formula/sratim.rb';
const rawVersion = process.argv[3] || process.env.TAG || '';
const newVersion = rawVersion.replace(/^v/, '');
const newSha = process.argv[4] || process.env.SHA256 || '';

if (!newVersion || !newSha) {
  console.error('Usage: node scripts/bump-formula.js <path/to/sratim.rb> <version> <sha256>');
  process.exit(1);
}

let content = fs.readFileSync(formulaPath, 'utf8');
content = content.replace(/version ".*?"/, `version "${newVersion}"`);
content = content.replace(/sha256 ".*?"/, `sha256 "${newSha}"`);

fs.writeFileSync(formulaPath, content, 'utf8');
console.log(`Updated ${formulaPath} to version ${newVersion} with sha256 ${newSha}`);
