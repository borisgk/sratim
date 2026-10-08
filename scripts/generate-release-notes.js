#!/usr/bin/env node

import { execSync } from 'node:child_process';
import process from 'node:process';

function resolvePrevTag(prevTag, targetRef) {
  if (prevTag && prevTag !== '0.0.0') {
    return prevTag;
  }
  try {
    const detected = execSync(`git describe --tags --abbrev=0 "${targetRef}^"`, {
      encoding: 'utf8',
      stdio: ['pipe', 'pipe', 'ignore'],
    }).trim();
    if (detected) return detected;
  } catch {
    // If targetRef has no parent or no prior tags
  }
  return '';
}

function getGitLog(prevTag, targetRef) {
  // If targetRef is a newly minted tag that hasn't been fetched locally, fall back to HEAD
  let ref = targetRef;
  try {
    execSync(`git rev-parse --verify "${ref}"`, { stdio: 'ignore' });
  } catch {
    ref = 'HEAD';
  }

  let resolvedPrev = resolvePrevTag(prevTag, ref);
  if (resolvedPrev) {
    try {
      execSync(`git rev-parse --verify "${resolvedPrev}"`, { stdio: 'ignore' });
    } catch {
      try {
        execSync('git fetch --tags origin', { stdio: 'ignore' });
      } catch {}
      resolvedPrev = resolvePrevTag(prevTag, ref);
    }
  }

  const range = resolvedPrev ? `${resolvedPrev}..${ref}` : ref;
  try {
    const raw = execSync(`git log "${range}" --format="%H%x1f%s%x1f%b%x1e"`, {
      encoding: 'utf8',
      stdio: ['pipe', 'pipe', 'ignore'],
    });
    if (raw && raw.trim()) return raw;
  } catch {}

  // Fallback: log the latest commit HEAD
  try {
    return execSync(`git log -n 1 HEAD --format="%H%x1f%s%x1f%b%x1e"`, {
      encoding: 'utf8',
      stdio: ['pipe', 'pipe', 'ignore'],
    });
  } catch {
    return '';
  }
}

function parseCommits(rawLog) {
  const records = rawLog.split('\x1e').filter(r => r.trim());
  const commits = [];

  for (const record of records) {
    const parts = record.split('\x1f');
    if (parts.length < 2) continue;
    const hash = parts[0].trim();
    const subject = parts[1].trim();
    const body = (parts[2] || '').trim();

    if (!subject) continue;
    if (/^(Merge branch|Merge pull request)/i.test(subject)) continue;

    commits.push({ hash, subject, body });
  }

  return commits;
}

function categorizeCommit(subject) {
  // Check for Conventional Commit: type(scope): message or type: message
  const convMatch = subject.match(/^([a-zA-Z]+)(?:\(([^)]+)\))?!?: (.+)$/);
  if (convMatch) {
    const rawType = convMatch[1].toLowerCase();
    const scope = convMatch[2] || '';
    const message = convMatch[3].trim();

    let type = 'other';
    if (rawType === 'feat') type = 'feat';
    else if (rawType === 'fix') type = 'fix';
    else if (rawType === 'perf') type = 'perf';
    else if (rawType === 'refactor') type = 'refactor';
    else if (rawType === 'docs') type = 'docs';
    else if (rawType === 'test' || rawType === 'tests') type = 'test';
    else if (rawType === 'ci') type = 'ci';
    else if (rawType === 'build') type = 'build';
    else if (rawType === 'revert') type = 'revert';

    return { type, scope, message };
  }

  // Fallback heuristic classification based on title prefix
  let type = 'other';
  let message = subject;
  let scope = '';

  if (/^(add|added|implement|implemented|support|create|created|allow)\b/i.test(subject)) {
    type = 'feat';
  } else if (/^(fix|fixed|resolve|resolved|patch|correct)\b/i.test(subject)) {
    type = 'fix';
  } else if (/^(optimize|perf|speed|improve performance)\b/i.test(subject)) {
    type = 'perf';
  } else if (/^(refactor|restructure|reorganize|cleanup|clean|modularize)\b/i.test(subject)) {
    type = 'refactor';
  } else if (/^(doc|docs|documentation|readme)\b/i.test(subject)) {
    type = 'docs';
  } else if (/^(test|tests|testing)\b/i.test(subject)) {
    type = 'test';
  } else if (/^(ci|workflow|action|actions)\b/i.test(subject)) {
    type = 'ci';
  } else if (/^(build|bump|deps)\b/i.test(subject)) {
    type = 'build';
  }

  return { type, scope, message };
}

function parseBodyItems(body) {
  if (!body) return [];
  const lines = body.split('\n');
  const items = [];

  for (let line of lines) {
    line = line.trim();
    if (!line) continue;
    // Strip leading list markers if present
    if (line.startsWith('- ') || line.startsWith('* ')) {
      line = line.substring(2).trim();
    }
    if (line) {
      items.push(line);
    }
  }

  return items;
}

function generateChangelog(prevTag, targetRef, repo) {
  const rawLog = getGitLog(prevTag, targetRef);
  const commits = parseCommits(rawLog);

  if (commits.length === 0) {
    return '';
  }

  const sections = {
    feat: { title: 'Features', items: [] },
    fix: { title: 'Bug Fixes', items: [] },
    perf: { title: 'Performance Improvements', items: [] },
    refactor: { title: 'Refactoring', items: [] },
    docs: { title: 'Documentation', items: [] },
    test: { title: 'Tests', items: [] },
    ci: { title: 'Continuous Integration', items: [] },
    build: { title: 'Build System', items: [] },
    revert: { title: 'Reverts', items: [] },
    other: { title: 'Other Changes', items: [] },
  };

  for (const c of commits) {
    const { type, scope, message } = categorizeCommit(c.subject);
    const bodyItems = parseBodyItems(c.body);
    const shortHash = c.hash.substring(0, 7);
    const commitUrl = `https://github.com/${repo}/commit/${c.hash}`;

    const scopePrefix = scope ? `**${scope}:** ` : '';
    const mainLine = `* ${scopePrefix}${message} ([${shortHash}](${commitUrl}))`;

    const entry = {
      mainLine,
      bodyItems,
    };

    if (sections[type]) {
      sections[type].items.push(entry);
    } else {
      sections.other.items.push(entry);
    }
  }

  const outputParts = [];
  const sectionOrder = ['feat', 'fix', 'perf', 'refactor', 'docs', 'test', 'ci', 'build', 'revert', 'other'];

  for (const key of sectionOrder) {
    const sec = sections[key];
    if (sec.items.length === 0) continue;

    outputParts.push(`### ${sec.title}\n`);
    for (const item of sec.items) {
      outputParts.push(item.mainLine);
      for (const b of item.bodyItems) {
        outputParts.push(`  - ${b}`);
      }
    }
    outputParts.push(''); // blank line between sections
  }

  return outputParts.join('\n').trim();
}

const prevTag = process.env.PREV_TAG || '';
const targetRef = process.env.TAG || process.env.TARGET_REF || 'HEAD';
const repo = process.env.REPO || 'borisgk/sratim';

const changelog = generateChangelog(prevTag, targetRef, repo);
process.stdout.write(changelog);
