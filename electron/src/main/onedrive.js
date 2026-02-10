const { getConfigValue } = require('./config');
const { extractText } = require('./file-extraction');

const GRAPH_ROOT = 'https://graph.microsoft.com/v1.0';
const DRIVE_CONTEXT_HINT = 'Provide drive_id/site_id/user_id in the tool call, or set MICROSOFT_DRIVE_ID/MICROSOFT_SITE_ID/MICROSOFT_USER_ID in apertureai.env.';

let accessToken = null;
let tokenExpiry = 0;

function isConfigured() {
  return !!(
    getConfigValue('MICROSOFT_TENANT_ID') &&
    getConfigValue('MICROSOFT_CLIENT_ID') &&
    getConfigValue('MICROSOFT_CLIENT_SECRET')
  );
}

async function ensureAccessToken() {
  const now = Date.now() / 1000;
  if (accessToken && now < tokenExpiry - 60) {
    return accessToken;
  }

  const tenantId = getConfigValue('MICROSOFT_TENANT_ID');
  const clientId = getConfigValue('MICROSOFT_CLIENT_ID');
  const clientSecret = getConfigValue('MICROSOFT_CLIENT_SECRET');

  if (!tenantId || !clientId || !clientSecret) {
    throw new Error('Microsoft OneDrive not configured. Add MICROSOFT_TENANT_ID, MICROSOFT_CLIENT_ID, and MICROSOFT_CLIENT_SECRET to apertureai.env.');
  }

  const url = `https://login.microsoftonline.com/${tenantId}/oauth2/v2.0/token`;
  const body = new URLSearchParams({
    client_id: clientId,
    scope: 'https://graph.microsoft.com/.default',
    client_secret: clientSecret,
    grant_type: 'client_credentials'
  });

  const response = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: body.toString(),
    signal: AbortSignal.timeout(15000)
  });

  const responseText = await response.text();
  let json = null;
  try {
    json = JSON.parse(responseText);
  } catch (err) {
    json = null;
  }

  if (!response.ok || !json?.access_token) {
    const apiMessage = json?.error_description || json?.error?.message;
    throw new Error(apiMessage || `Failed to get Microsoft access token (HTTP ${response.status}).`);
  }

  accessToken = json.access_token;
  tokenExpiry = now + (json.expires_in || 3600);
  return accessToken;
}

async function graphRequest(url, options = {}) {
  const token = await ensureAccessToken();
  const headers = {
    Authorization: `Bearer ${token}`,
    ...(options.headers || {})
  };

  return fetch(url, {
    ...options,
    headers,
    signal: options.signal || AbortSignal.timeout(20000)
  });
}

function normalizeDriveOptions(driveOptions) {
  if (!driveOptions) return {};
  if (typeof driveOptions === 'string') {
    return { driveId: driveOptions };
  }
  return {
    driveId: driveOptions.driveId || driveOptions.drive_id || null,
    siteId: driveOptions.siteId || driveOptions.site_id || null,
    userId: driveOptions.userId || driveOptions.user_id || null
  };
}

function getConfiguredDriveOptions() {
  return {
    driveId: getConfigValue('MICROSOFT_DRIVE_ID'),
    siteId: getConfigValue('MICROSOFT_SITE_ID'),
    userId: getConfigValue('MICROSOFT_USER_ID')
  };
}

function getDriveBase(driveOptions) {
  const normalized = normalizeDriveOptions(driveOptions);
  const configured = getConfiguredDriveOptions();

  const driveId = normalized.driveId || configured.driveId;
  const siteId = normalized.siteId || configured.siteId;
  const userId = normalized.userId || configured.userId;

  if (driveId) return `${GRAPH_ROOT}/drives/${encodeURIComponent(driveId)}`;
  if (siteId) return `${GRAPH_ROOT}/sites/${encodeURIComponent(siteId)}/drive`;
  if (userId) return `${GRAPH_ROOT}/users/${encodeURIComponent(userId)}/drive`;
  return null;
}

function formatFileItem(item) {
  return {
    id: item.id || '',
    name: item.name || '',
    mimeType: item.file ? (item.file.mimeType || 'file') : 'folder',
    size: item.size || 0,
    modifiedTime: item.lastModifiedDateTime || '',
    webUrl: item.webUrl || '',
    isFolder: !!item.folder,
    driveId: item.parentReference?.driveId || ''
  };
}

async function parseJsonResponse(response) {
  const body = await response.text();
  let json = null;
  try {
    json = JSON.parse(body);
  } catch (err) {
    json = null;
  }

  if (!response.ok) {
    const apiMessage = json?.error?.message || body;
    throw new Error(`HTTP ${response.status}: ${apiMessage}`);
  }

  return json || {};
}

async function listFiles(folderId, driveOptions) {
  const base = getDriveBase(driveOptions);
  const select = 'id,name,file,folder,size,lastModifiedDateTime,webUrl,parentReference';

  if (!base && !folderId) {
    return listAccessibleLocations();
  }

  if (!base) {
    throw new Error(`Cannot browse an item by ID without drive context. ${DRIVE_CONTEXT_HINT}`);
  }

  const encodedFolderId = folderId ? encodeURIComponent(folderId) : null;
  const url = encodedFolderId
    ? `${base}/items/${encodedFolderId}/children?$top=100&$orderby=lastModifiedDateTime+desc&$select=${select}`
    : `${base}/root/children?$top=100&$orderby=lastModifiedDateTime+desc&$select=${select}`;

  const response = await graphRequest(url);
  const json = await parseJsonResponse(response);
  const files = (json.value || []).map(formatFileItem);
  return JSON.stringify({ files });
}

async function fetchSites() {
  const url = `${GRAPH_ROOT}/sites?search=*&$top=20&$select=id,displayName,webUrl`;
  const response = await graphRequest(url);
  const json = await parseJsonResponse(response);
  return (json.value || []).map((site) => ({
    id: site.id,
    name: site.displayName || '',
    webUrl: site.webUrl || '',
    type: 'SharePoint Site'
  }));
}

async function fetchDrives() {
  const url = `${GRAPH_ROOT}/drives?$top=50&$select=id,name,driveType,webUrl`;
  const response = await graphRequest(url);
  const json = await parseJsonResponse(response);
  return (json.value || []).map((drive) => ({
    id: drive.id,
    name: drive.name || '',
    webUrl: drive.webUrl || '',
    driveType: drive.driveType || ''
  }));
}

async function listAccessibleLocations() {
  const [sitesResult, drivesResult] = await Promise.allSettled([
    fetchSites(),
    fetchDrives()
  ]);

  const sites = sitesResult.status === 'fulfilled' ? sitesResult.value : [];
  const drives = drivesResult.status === 'fulfilled' ? drivesResult.value : [];

  if (sitesResult.status === 'rejected' && drivesResult.status === 'rejected') {
    throw new Error(`Unable to list accessible OneDrive/SharePoint locations. ${sitesResult.reason.message}`);
  }

  return JSON.stringify({
    sites,
    drives,
    hint: 'Use list_onedrive_files with drive_id/site_id/user_id to browse a specific location.'
  });
}

async function searchFiles(queryText, driveOptions) {
  const base = getDriveBase(driveOptions);

  if (!base) {
    return crossDriveSearch(queryText);
  }

  const safeQuery = encodeURIComponent(queryText);
  const select = 'id,name,file,folder,size,lastModifiedDateTime,webUrl,parentReference';
  const url = `${base}/root/search(q='${safeQuery}')?$top=100&$select=${select}`;

  const response = await graphRequest(url);
  const json = await parseJsonResponse(response);
  const files = (json.value || []).map(formatFileItem);
  return JSON.stringify({ files });
}

async function crossDriveSearch(queryText) {
  const url = `${GRAPH_ROOT}/search/query`;
  const body = {
    requests: [{
      entityTypes: ['driveItem'],
      query: { queryString: queryText },
      from: 0,
      size: 50
    }]
  };

  const response = await graphRequest(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body)
  });
  const json = await parseJsonResponse(response);

  const hits = json.value?.[0]?.hitsContainers?.[0]?.hits || [];
  const files = hits.map((hit) => formatFileItem(hit.resource || {}));
  return JSON.stringify({ files });
}

async function readFile(itemId, driveOptions) {
  const base = getDriveBase(driveOptions);
  if (!base) {
    throw new Error(`Cannot read file without drive context. ${DRIVE_CONTEXT_HINT}`);
  }

  const encodedItemId = encodeURIComponent(itemId);
  const metaUrl = `${base}/items/${encodedItemId}?$select=id,name,file,size,lastModifiedDateTime,webUrl,parentReference`;
  const metaResponse = await graphRequest(metaUrl);
  const metadata = await parseJsonResponse(metaResponse);

  if (!metadata.file) {
    throw new Error('The selected item is a folder. Choose a file item instead.');
  }

  const fileName = metadata.name || '';
  const mimeType = metadata.file?.mimeType || '';
  const webUrl = metadata.webUrl || '';
  const resolvedDriveId = metadata.parentReference?.driveId || normalizeDriveOptions(driveOptions).driveId || '';

  const contentUrl = `${base}/items/${encodedItemId}/content`;
  const contentResponse = await graphRequest(contentUrl, { signal: AbortSignal.timeout(30000) });

  if (!contentResponse.ok) {
    const body = await contentResponse.text();
    throw new Error(`HTTP ${contentResponse.status}: ${body}`);
  }

  const buffer = Buffer.from(await contentResponse.arrayBuffer());
  return formatReadResult(buffer, mimeType, fileName, itemId, webUrl, resolvedDriveId);
}

async function formatReadResult(buffer, mimeType, fileName, itemId, webUrl, driveId) {
  let text = await extractText(buffer, mimeType, fileName);
  if (text === null) {
    throw new Error(`Could not extract readable text from this file type (${mimeType || 'unknown'}).`);
  }

  if (text.length > 15000) {
    text = text.substring(0, 15000) + '\n\n[...truncated, file too large to show in full]';
  }

  return JSON.stringify({
    file: {
      id: itemId,
      driveId: driveId || '',
      name: fileName,
      mimeType: mimeType,
      webUrl: webUrl
    },
    content: text
  });
}

module.exports = { isConfigured, listFiles, searchFiles, readFile };
