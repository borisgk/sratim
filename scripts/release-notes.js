#!/usr/bin/env node

import { execSync } from 'node:child_process';
import process from 'node:process';

const tag = process.env.TAG || 'Latest';
const repo = process.env.REPO || 'borisgk/sratim';
const isTelegram = process.argv.includes('--telegram');

// 1. Resolve commit range between previous tag and target ref / HEAD
let prevTag = process.env.PREV_TAG;
if (!prevTag || prevTag === '0.0.0') {
  try {
    prevTag = execSync('git describe --tags --abbrev=0 HEAD^', {
      encoding: 'utf8',
      stdio: ['pipe', 'pipe', 'ignore'],
    }).trim();
  } catch {
    prevTag = '';
  }
}

// 2. Fetch commits from git log
const range = prevTag ? `${prevTag}..HEAD` : 'HEAD';
let rawLog = '';
try {
  rawLog = execSync(`git log "${range}" --format="%H%x1f%s%x1f%b%x1e"`, {
    encoding: 'utf8',
    stdio: ['pipe', 'pipe', 'ignore'],
  });
} catch {
  // Fallback to latest commit if range fails
  try {
    rawLog = execSync('git log -n 1 HEAD --format="%H%x1f%s%x1f%b%x1e"', {
      encoding: 'utf8',
      stdio: ['pipe', 'pipe', 'ignore'],
    });
  } catch {}
}

// 3. Parse commits and sanitize @-mentions (e.g. Zig built-in @typeInfo)
const sanitize = s => s.replace(/(^|[^`\w])@([a-zA-Z_][a-zA-Z0-9_]*)(?!`)/g, '$1`@$2`');

const commits = [];
for (const entry of rawLog.split('\x1e')) {
  if (!entry.trim()) continue;
  const [hash, subject, body] = entry.split('\x1f');
  if (!subject || /^Merge /i.test(subject)) continue;

  const bullets = (body || '')
    .split('\n')
    .map(l => l.trim())
    .filter(Boolean)
    .map(l => l.replace(/^[-*]\s+/, ''))
    .map(sanitize);

  commits.push({
    hash: hash.trim(),
    shortHash: hash.trim().slice(0, 7),
    subject: sanitize(subject.trim()),
    bullets,
  });
}

if (commits.length === 0) {
  process.exit(0);
}

// 4. Output Markdown (for GitHub Releases) or HTML (for Telegram)
if (!isTelegram) {
  const lines = [];
  for (const c of commits) {
    const url = `https://github.com/${repo}/commit/${c.hash}`;
    lines.push(`* ${c.subject} ([${c.shortHash}](${url}))`);
    for (const b of c.bullets) {
      lines.push(`  - ${b}`);
    }
  }
  process.stdout.write(lines.join('\n') + '\n');
} else {
  const escapeHtml = s => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  const fmtInline = s =>
    escapeHtml(s)
      .replace(/`([^`]+)`/g, '<code>$1</code>')
      .replace(/\*\*([^*]+)\*\*/g, '<b>$1</b>');

  const items = [];
  let currentLen = 0;
  for (const c of commits) {
    const url = `https://github.com/${repo}/commit/${c.hash}`;
    const mainLine = `• <b>${fmtInline(c.subject)}</b> (<a href="${url}">${c.shortHash}</a>)`;
    items.push(mainLine);
    currentLen += mainLine.length;

    for (const b of c.bullets) {
      const subLine = `  ▫️ ${fmtInline(b)}`;
      if (currentLen + subLine.length > 3200) {
        items.push('  ▫️ <i>...and more on GitHub</i>');
        break;
      }
      items.push(subLine);
      currentLen += subLine.length;
    }
  }

  const header = `🚀 <b>Sratim Release ${escapeHtml(tag)}!</b>\n\n`;
  const footer = `\n\n🔗 <a href="https://github.com/${repo}/releases/tag/${escapeHtml(tag)}">View Release on GitHub</a>`;
  process.stdout.write(`${header}${items.join('\n')}${footer}\n`);
}
