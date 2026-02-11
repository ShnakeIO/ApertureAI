const fs = require('fs');
const crypto = require('crypto');
const { getConfigValue, getServiceAccountPath } = require('./config');
const { extractText } = require('./file-extraction');

let serviceAccountJSON = null;
let accessToken = null;
let tokenExpiry = 0;

function loadServiceAccount() {
  const saPath = getServiceAccountPath();
  if (!saPath) return;
  try {
    const data = fs.readFileSync(saPath, 'utf8');
    serviceAccountJSON = JSON.parse(data);
  } catch (err) {
    console.error('Failed to load service account:', err.message);
    serviceAccountJSON = null;
  }
}

function isConfigured() {
  return !!serviceAccountJSON;
}

function createJWT() {
  const clientEmail = serviceAccountJSON.client_email;
  const privateKey = serviceAccountJSON.private_key;
  const tokenURI = serviceAccountJSON.token_uri || 'https://oauth2.googleapis.com/token';

  if (!clientEmail || !privateKey) {
    throw new Error('Invalid service account JSON.');
  }

  const now = Math.floor(Date.now() / 1000);
  const header = { alg: 'RS256', typ: 'JWT' };
  const claims = {
    iss: clientEmail,
    scope: 'https://www.googleapis.com/auth/drive.readonly',
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
  if (accessToken && now < tokenExpiry - 60) {
    return accessToken;
  }

  if (!serviceAccountJSON) {
    throw new Error('No Google service account configured.');
  }

  const jwt = createJWT();
  const tokenURI = serviceAccountJSON.token_uri || 'https://oauth2.googleapis.com/token';
  const body = `grant_type=${encodeURIComponent('urn:ietf:params:oauth:grant-type:jwt-bearer')}&assertion=${jwt}`;

  const response = await fetch(tokenURI, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: body,
    signal: AbortSignal.timeout(15000)
  });

  const json = await response.json();
  if (!json.access_token) {
    throw new Error(json.error_description || 'Failed to get Google access token.');
  }

  accessToken = json.access_token;
  tokenExpiry = now + (json.expires_in || 3600);
  return accessToken;
}

async function driveRequest(url, token) {
  const response = await fetch(url, {
    headers: { 'Authorization': `Bearer ${token}` },
    signal: AbortSignal.timeout(20000)
  });
  return response;
}

async function listFiles(folderId) {
  const token = await ensureAccessToken();
  let query;
  if (folderId) {
    query = encodeURIComponent(`'${folderId}' in parents and trashed=false`);
  } else {
    // When a folder is shared with the service account, the folder itself is "sharedWithMe",
    // but the files inside it typically are not. Listing everything accessible ensures the
    // agent can discover files inside shared folders without needing IDs upfront.
    query = encodeURIComponent(`trashed=false`);
  }
  const fields = encodeURIComponent('files(id,name,mimeType,size,modifiedTime,webViewLink,parents)');
  const url = `https://www.googleapis.com/drive/v3/files?q=${query}&fields=${fields}&pageSize=100&orderBy=modifiedTime+desc&supportsAllDrives=true&includeItemsFromAllDrives=true&corpora=allDrives`;

  const response = await driveRequest(url, token);
  if (!response.ok) {
    const body = await response.text();
    throw new Error(`HTTP ${response.status}: ${body}`);
  }
  return await response.text();
}

async function searchFiles(queryText) {
  const token = await ensureAccessToken();
  const safeQuery = queryText.replace(/'/g, "\\'");
  const q = encodeURIComponent(`trashed=false and name contains '${safeQuery}'`);
  const fields = encodeURIComponent('files(id,name,mimeType,size,modifiedTime,webViewLink,parents)');
  const url = `https://www.googleapis.com/drive/v3/files?q=${q}&fields=${fields}&pageSize=100&orderBy=modifiedTime+desc&supportsAllDrives=true&includeItemsFromAllDrives=true&corpora=allDrives`;

  const response = await driveRequest(url, token);
  if (!response.ok) {
    const body = await response.text();
    throw new Error(`HTTP ${response.status}: ${body}`);
  }
  return await response.text();
}

async function getFileMetadata(fileId, token) {
  const fields = encodeURIComponent('id,name,mimeType,size,modifiedTime,webViewLink,parents');
  const url = `https://www.googleapis.com/drive/v3/files/${fileId}?fields=${fields}&supportsAllDrives=true`;

  const response = await driveRequest(url, token);
  if (!response.ok) {
    const body = await response.text();
    throw new Error(`HTTP ${response.status}: ${body}`);
  }
  return await response.json();
}

async function readFile(fileId, isExport) {
  const token = await ensureAccessToken();
  const metadata = await getFileMetadata(fileId, token);

  const mimeType = metadata.mimeType || '';
  const fileName = metadata.name || '';
  const webViewLink = metadata.webViewLink || `https://drive.google.com/open?id=${fileId}`;
  const isGoogleNative = mimeType.startsWith('application/vnd.google-apps');

  let exportMimes = null;
  if (isGoogleNative || isExport) {
    if (mimeType === 'application/vnd.google-apps.spreadsheet') {
      exportMimes = ['text/csv', 'text/plain'];
    } else {
      exportMimes = ['text/plain'];
    }
  }

  // Try export modes then fallback to direct download
  const attempts = [];
  if (exportMimes) {
    for (const em of exportMimes) {
      attempts.push({ type: 'export', mime: em });
    }
  }
  attempts.push({ type: 'download' });

  let lastError = null;
  for (const attempt of attempts) {
    let url;
    if (attempt.type === 'export') {
      url = `https://www.googleapis.com/drive/v3/files/${fileId}/export?mimeType=${encodeURIComponent(attempt.mime)}`;
    } else {
      url = `https://www.googleapis.com/drive/v3/files/${fileId}?alt=media`;
    }

    const response = await fetch(url, {
      headers: { 'Authorization': `Bearer ${token}` },
      signal: AbortSignal.timeout(30000)
    });

    if (!response.ok) {
      const status = response.status;
      if (attempt.type === 'export' && (status === 400 || status === 403 || status === 415)) {
        lastError = `HTTP ${status}`;
        continue; // try next export mime or fallback
      }
      const body = await response.text();
      throw new Error(`HTTP ${status}: ${body}`);
    }

    let text;
    if (attempt.type === 'export') {
      text = await response.text();
    } else {
      const buffer = Buffer.from(await response.arrayBuffer());
      text = await extractText(buffer, mimeType, fileName);
      if (text === null) {
        throw new Error('Could not extract readable text from file.');
      }
    }

    // Truncate
    if (text.length > 15000) {
      text = text.substring(0, 15000) + '\n\n[...truncated, file too large to show in full]';
    }

    const payload = {
      file: {
        id: fileId,
        name: fileName,
        mimeType: mimeType,
        webViewLink: webViewLink
      },
      content: text
    };

    return JSON.stringify(payload);
  }

  throw new Error(lastError || 'Could not read file.');
}

module.exports = { loadServiceAccount, isConfigured, listFiles, searchFiles, readFile };
