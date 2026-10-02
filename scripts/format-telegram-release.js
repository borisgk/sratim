#!/usr/bin/env node

function escapeHtml(str) {
  return str
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}

function formatInline(text) {
  let s = escapeHtml(text);
  // `code` -> <code>code</code>
  s = s.replace(/`([^`]+)`/g, '<code>$1</code>');
  // **text** -> <b>text</b>
  s = s.replace(/\*\*([^\*]+)\*\*/g, '<b>$1</b>');
  // [text](url) -> <a href="url">text</a>
  s = s.replace(/\[([^\]]+)\]\((https?:\/\/[^\s\)]+)\)/g, '<a href="$2">$1</a>');
  return s;
}

function buildTelegramMessage(rawChangelog, tag, repo) {
  const sectionEmojis = {
    'Bug Fixes': '🐛',
    'Features': '✨',
    'Performance Improvements': '⚡',
    'Continuous Integration': '👷',
    'Documentation': '📚',
    'Refactoring': '♻️',
    'Code Refactoring': '♻️',
    'Tests': '🧪',
    'Build System': '📦',
    'Reverts': '⏪',
  };

  const lines = (rawChangelog || '').split('\n');
  const items = [];

  for (let line of lines) {
    line = line.trim();
    if (!line) continue;
    // Skip version header line (e.g. ### [1.19.6](...) (2026-10-02))
    if (/^###\s+\[?\d+\.\d+\.\d+/.test(line)) continue;

    // Section header (### Bug Fixes)
    if (line.startsWith('### ')) {
      const title = line.replace(/^###\s+/, '').trim();
      const emoji = sectionEmojis[title] || '📌';
      items.push(`\n${emoji} <b>${escapeHtml(title)}</b>`);
      continue;
    }

    // Bullet point (* **scope:** message ([hash](url)))
    if (line.startsWith('* ') || line.startsWith('- ')) {
      let content = line.replace(/^[\*\-]\s+/, '').trim();
      let commitHtml = '';

      // Extract markdown commit link at the end: ([8384abf](https://...))
      const linkMatch = content.match(/\(\[([a-f0-9]+)\]\((https:\/\/[^\)]+)\)\)$/);
      if (linkMatch) {
        const hash = linkMatch[1];
        const url = linkMatch[2];
        commitHtml = ` (<a href="${url}">${hash}</a>)`;
        content = content.replace(/\(\[([a-f0-9]+)\]\((https:\/\/[^\)]+)\)\)$/, '').trim();
      }

      // Check for scope prefix: **scope:** or **scope(sub):**
      let scopeHtml = '';
      const scopeMatch = content.match(/^\*\*([^\*]+):\*\*\s*(.*)$/);
      if (scopeMatch) {
        scopeHtml = `<b>${escapeHtml(scopeMatch[1])}:</b> `;
        content = scopeMatch[2];
      }

      items.push(`• ${scopeHtml}${formatInline(content)}${commitHtml}`);
      continue;
    }

    items.push(formatInline(line));
  }

  // Safe boundary truncation to avoid Telegram's 4096 character limit
  const keptItems = [];
  let currentLen = 0;
  for (const item of items) {
    if (currentLen + item.length > 3200) {
      keptItems.push('\n• <i>...and more changes on GitHub</i>');
      break;
    }
    keptItems.push(item);
    currentLen += item.length + 1;
  }

  const formattedChangelog = keptItems.join('\n').trim();
  const safeTag = escapeHtml(tag || 'Latest');
  const header = `🚀 <b>Sratim Release ${safeTag}!</b>`;
  const footer = `🔗 <a href="https://github.com/${repo}/releases/tag/${safeTag}">View Release on GitHub</a>`;

  return formattedChangelog
    ? `${header}\n\n${formattedChangelog}\n\n${footer}`
    : `${header}\n\n${footer}`;
}

const changelog = process.env.CHANGELOG || '';
const tag = process.env.TAG || '';
const repo = process.env.REPO || 'borisgk/sratim';

process.stdout.write(buildTelegramMessage(changelog, tag, repo));
