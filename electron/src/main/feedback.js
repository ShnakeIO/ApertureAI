const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { app } = require('electron');
const { getConfigValue, getServiceAccountPath } = require('./config');

const FEEDBACK_HISTORY_FILE = 'feedback_reports.json';
const DEFAULT_FEEDBACK_DOC_ID = '1arf9n_r7IQmNkPHEaV0hZqlyVunU2p9-cjm5_0QVF2Q';
const FEEDBACK_SCOPES = [
  'https://www.googleapis.com/auth/documents'
];

let cachedServiceAccount = null;
let accessToken = null;
let tokenExpiry = 0;

function parseDocId(value) {
  if (!value || typeof value !== 'string') return null;
  const trimmed = value.trim();
  if (!trimmed) return null;

  const urlMatch = trimmed.match(/\/document\/d\/([a-zA-Z0-9_-]+)/);
  if (urlMatch) return urlMatch[1];

  if (/^[a-zA-Z0-9_-]{20,}$/.test(trimmed)) return trimmed;
  return null;
}

function getConfiguredDocId() {
  const direct =
    parseDocId(getConfigValue('FEEDBACK_GOOGLE_DOC_ID')) ||
    parseDocId(getConfigValue('GOOGLE_FEEDBACK_DOC_ID'));
  if (direct) return direct;

  const fromUrl =
    parseDocId(getConfigValue('FEEDBACK_GOOGLE_DOC_URL')) ||
    parseDocId(getConfigValue('GOOGLE_FEEDBACK_DOC_URL'));
  if (fromUrl) return fromUrl;

  return DEFAULT_FEEDBACK_DOC_ID;
}

function getHistoryPath() {
  return path.join(app.getPath('userData'), FEEDBACK_HISTORY_FILE);
}

function readReportHistory() {
  const historyPath = getHistoryPath();
  if (!fs.existsSync(historyPath)) return [];
  try {
    const raw = fs.readFileSync(historyPath, 'utf8');
    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) return [];
    return parsed;
  } catch (err) {
    console.error('Failed to load feedback history:', err.message);
    return [];
  }
}

function writeReportHistory(history) {
  const historyPath = getHistoryPath();
  try {
    fs.writeFileSync(historyPath, JSON.stringify(history, null, 2), 'utf8');
  } catch (err) {
    console.error('Failed to save feedback history:', err.message);
  }
}

function loadServiceAccount() {
  const saPath = getServiceAccountPath();
  if (!saPath) {
    cachedServiceAccount = null;
    return null;
  }

  if (cachedServiceAccount && cachedServiceAccount.__path === saPath) {
    return cachedServiceAccount;
  }

  try {
    const parsed = JSON.parse(fs.readFileSync(saPath, 'utf8'));
    cachedServiceAccount = { ...parsed, __path: saPath };
    return cachedServiceAccount;
  } catch (err) {
    console.error('Failed to load feedback service account:', err.message);
    cachedServiceAccount = null;
    return null;
  }
}

function createServiceAccountJWT(serviceAccount, scopes) {
  const clientEmail = serviceAccount.client_email;
  const privateKey = serviceAccount.private_key;
  const tokenURI = serviceAccount.token_uri || 'https://oauth2.googleapis.com/token';

  if (!clientEmail || !privateKey) {
    throw new Error('Invalid service account JSON.');
  }

  const now = Math.floor(Date.now() / 1000);
  const header = { alg: 'RS256', typ: 'JWT' };
  const claims = {
    iss: clientEmail,
    scope: scopes.join(' '),
    aud: tokenURI,
    iat: now,
    exp: now + 3600
  };

  const headerB64 = Buffer.from(JSON.stringify(header)).toString('base64url');
  const claimsB64 = Buffer.from(JSON.stringify(claims)).toString('base64url');
  const signingInput = `${headerB64}.${claimsB64}`;

  const sign = crypto.createSign('RSA-SHA256');
  sign.update(signingInput);
  const signature = sign.sign(privateKey, 'base64url');

  return `${signingInput}.${signature}`;
}

async function ensureAccessToken() {
  const now = Date.now() / 1000;
  if (accessToken && now < tokenExpiry - 60) return accessToken;

  const serviceAccount = loadServiceAccount();
  if (!serviceAccount) {
    throw new Error('Google service account is not configured.');
  }

  const tokenURI = serviceAccount.token_uri || 'https://oauth2.googleapis.com/token';
  const jwt = createServiceAccountJWT(serviceAccount, FEEDBACK_SCOPES);
  const body = `grant_type=${encodeURIComponent('urn:ietf:params:oauth:grant-type:jwt-bearer')}&assertion=${jwt}`;

  const response = await fetch(tokenURI, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body,
    signal: AbortSignal.timeout(15000)
  });

  const json = await response.json();
  if (!json.access_token) {
    throw new Error(json.error_description || json.error || 'Failed to get Google OAuth token.');
  }

  accessToken = json.access_token;
  tokenExpiry = now + (json.expires_in || 3600);
  return accessToken;
}

async function appendToGoogleDoc(docId, text) {
  const token = await ensureAccessToken();
  const url = `https://docs.googleapis.com/v1/documents/${docId}:batchUpdate`;
  const body = {
    requests: [
      {
        insertText: {
          endOfSegmentLocation: {},
          text
        }
      }
    ]
  };

  const response = await fetch(url, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json'
    },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(20000)
  });

  if (!response.ok) {
    const errText = await response.text();
    if (response.status === 403 || response.status === 404) {
      throw new Error(
        `Google Doc access failed (${response.status}). Share the document with the service account email as Editor.`
      );
    }
    throw new Error(`Google Docs API error (${response.status}): ${errText}`);
  }
}

function sanitizeText(value, maxLen) {
  const text = typeof value === 'string' ? value.trim() : '';
  if (!text) return '';
  return text.length > maxLen ? `${text.substring(0, maxLen)}...` : text;
}

function buildDocEntry(report) {
  const typeLabel = report.type === 'feature' ? 'Feature Request' : 'Bug Report';
  const lines = [
    '\n\n',
    '--------------------------------------------------\n',
    `${typeLabel} (${report.createdAt})\n`,
    `Title: ${report.title}\n`,
    `Details: ${report.details}\n`,
    `App Version: ${report.appVersion}\n`,
    `Platform: ${report.platform}\n`,
    `Storage: ${report.storageSummary}\n`,
    `OpenAI Model: ${report.model}\n`,
    `Report ID: ${report.id}\n`
  ];
  return lines.join('');
}

function createReport(payload) {
  const type = payload?.type === 'feature' ? 'feature' : 'bug';
  const title = sanitizeText(payload?.title, 160);
  const details = sanitizeText(payload?.details, 3000);
  if (!title) throw new Error('Please enter a short title.');
  if (!details) throw new Error('Please enter report details.');

  return {
    id: crypto.randomUUID(),
    createdAt: new Date().toISOString(),
    type,
    title,
    details,
    appVersion: sanitizeText(payload?.appVersion, 40) || 'unknown',
    platform: `${process.platform}-${process.arch}`,
    storageSummary: sanitizeText(payload?.storageSummary, 80) || 'Not configured',
    model: sanitizeText(payload?.model, 80) || 'unknown',
    syncStatus: 'pending',
    syncError: null
  };
}

async function submitReport(payload) {
  const docId = getConfiguredDocId();
  const report = createReport(payload);
  const docEntry = buildDocEntry(report);

  try {
    await appendToGoogleDoc(docId, docEntry);
    report.syncStatus = 'synced';
  } catch (err) {
    report.syncStatus = 'failed';
    report.syncError = err.message || 'Unknown upload error.';
  }

  const history = readReportHistory();
  history.push(report);
  if (history.length > 200) {
    history.splice(0, history.length - 200);
  }
  writeReportHistory(history);

  return {
    ok: report.syncStatus === 'synced',
    report
  };
}

function listReports(limit = 10) {
  const safeLimit = Math.max(1, Math.min(Number(limit) || 10, 100));
  const history = readReportHistory();
  return history.slice(-safeLimit).reverse();
}

function getStatus() {
  const docId = getConfiguredDocId();
  const hasServiceAccount = !!loadServiceAccount();
  return {
    hasServiceAccount,
    docId,
    configured: hasServiceAccount && !!docId
  };
}

module.exports = {
  submitReport,
  listReports,
  getStatus
};
