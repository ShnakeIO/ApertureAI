const { getConfigValue } = require('./config');

function getGoogleDriveTools() {
  return [
    {
      type: 'function',
      function: {
        name: 'list_drive_files',
        description: 'List files and folders in a Google Drive folder. If no folder_id is provided, lists all files the service account can access (including files inside shared folders). Returns file names, IDs, types, parent IDs, and webViewLink URLs.',
        parameters: {
          type: 'object',
          properties: {
            folder_id: { type: 'string', description: 'Optional. The Google Drive folder ID to list contents of. If omitted, lists all accessible files.' }
          }
        }
      }
    },
    {
      type: 'function',
      function: {
        name: 'search_drive_files',
        description: 'Search Google Drive files by name and return IDs, metadata, and webViewLink URLs.',
        parameters: {
          type: 'object',
          properties: {
            query: { type: 'string', description: 'The search text to match against file names.' }
          },
          required: ['query']
        }
      }
    },
    {
      type: 'function',
      function: {
        name: 'read_drive_file',
        description: 'Read text content from a Google Drive file. Returns JSON with file metadata (including webViewLink) plus extracted content. Supports Google Docs/Sheets export, plain text files, PDF text extraction, and DOCX text extraction.',
        parameters: {
          type: 'object',
          properties: {
            file_id: { type: 'string', description: 'The file ID to read.' },
            export: { type: 'boolean', description: 'Optional hint. If true, prefer Drive export mode. If false, prefer direct download mode. The app may auto-select based on file type.' }
          },
          required: ['file_id']
        }
      }
    }
  ];
}

function getOneDriveTools() {
  return [
    {
      type: 'function',
      function: {
        name: 'list_onedrive_files',
        description: 'List files and folders in Microsoft OneDrive/SharePoint. If no folder_id is provided, lists root-level files for the selected drive/site/user context.',
        parameters: {
          type: 'object',
          properties: {
            folder_id: { type: 'string', description: 'Optional. The OneDrive folder/item ID to list contents of. If omitted, lists root-level items.' },
            drive_id: { type: 'string', description: 'Optional. The drive ID to browse. Use this when search results include driveId.' },
            site_id: { type: 'string', description: 'Optional. SharePoint site ID. If provided, the tool browses that site drive.' },
            user_id: { type: 'string', description: 'Optional. Microsoft user principal name or user ID for OneDrive for Business.' }
          }
        }
      }
    },
    {
      type: 'function',
      function: {
        name: 'search_onedrive_files',
        description: 'Search Microsoft OneDrive/SharePoint files by name or content. Returns file IDs, names, URLs, and metadata.',
        parameters: {
          type: 'object',
          properties: {
            query: { type: 'string', description: 'The search text to match against file names and content.' },
            drive_id: { type: 'string', description: 'Optional. Restrict search to a specific drive.' },
            site_id: { type: 'string', description: 'Optional. Restrict search to a SharePoint site drive.' },
            user_id: { type: 'string', description: 'Optional. Restrict search to a specific user drive.' }
          },
          required: ['query']
        }
      }
    },
    {
      type: 'function',
      function: {
        name: 'read_onedrive_file',
        description: 'Read text content from a Microsoft OneDrive/SharePoint file. Returns JSON with file metadata (including webUrl) plus extracted content.',
        parameters: {
          type: 'object',
          properties: {
            item_id: { type: 'string', description: 'The OneDrive item ID to read.' },
            drive_id: { type: 'string', description: 'Optional. The drive ID if the file is on a specific drive (returned by search results).' },
            site_id: { type: 'string', description: 'Optional. SharePoint site ID to resolve the file from.' },
            user_id: { type: 'string', description: 'Optional. User ID/UPN to resolve the file from.' }
          },
          required: ['item_id']
        }
      }
    }
  ];
}

function getToolDefinitions(hasDrive, hasOneDrive) {
  const tools = [];
  if (hasDrive) tools.push(...getGoogleDriveTools());
  if (hasOneDrive) tools.push(...getOneDriveTools());
  return tools;
}

function defaultSystemPrompt(hasDrive, hasOneDrive) {
  const parts = ['You are ApertureAI, a helpful AI assistant.'];

  if (hasDrive || hasOneDrive) {
    parts.push('You have tools to browse and read files from the user\'s cloud storage. When the user asks about their files or data, USE YOUR TOOLS to look up the actual content — do not guess or make things up from file names alone.');
  }

  if (hasDrive) {
    const driveFolderId = getConfigValue('GOOGLE_DRIVE_FOLDER_ID');
    if (driveFolderId) {
      parts.push(`For Google Drive: The root folder ID is ${driveFolderId}. When listing files, start with that root folder ID.`);
    } else {
      parts.push('For Google Drive: Use list_drive_files with no folder_id to see all accessible files, or use search_drive_files to find files by name.');
    }
    parts.push('For Google Docs/Sheets/Slides, use export mode. For PDF and DOCX files, use read_drive_file for extracted text.');
  }

  if (hasOneDrive) {
    parts.push('For Microsoft OneDrive/SharePoint: Use list_onedrive_files to browse files, search_onedrive_files to find files by name, and read_onedrive_file to read content. If a result includes driveId, pass it as drive_id in follow-up calls.');
    parts.push('If no default OneDrive context is configured, start with list_onedrive_files (without folder_id) to discover accessible drives/sites.');
  }

  if (hasDrive || hasOneDrive) {
    parts.push('When you cite a file, include its full URL so the user can open it directly. If you quote or summarize specific file content, mention the exact source file name and link.');
  }

  parts.push('Be concise and helpful. Summarize data clearly.');
  return parts.join(' ');
}

function compressedContent(content, maxChars) {
  if (typeof content !== 'string') return '';
  if (content.length <= maxChars || maxChars < 32) return content;
  let head = Math.floor(maxChars * 0.7);
  if (head >= content.length) head = Math.floor(maxChars / 2);
  const tail = maxChars - head;
  const prefix = content.substring(0, head);
  const suffix = content.substring(content.length - tail);
  return `${prefix}\n\n...[truncated ${content.length - maxChars} chars]...\n\n${suffix}`;
}

function compactConversationIfNeeded(messages, memoryEntries) {
  if (messages.length <= 24) return messages;

  let totalChars = 0;
  for (const msg of messages) {
    totalChars += (typeof msg.content === 'string' ? msg.content.length : 0);
  }
  if (messages.length <= 34 && totalChars < 52000) return messages;

  const systemMsg = messages.length > 0 ? messages[0] : null;
  const rebuilt = [];

  if (systemMsg && typeof systemMsg === 'object') {
    rebuilt.push(systemMsg);
  }

  // Add memory summary
  if (memoryEntries && memoryEntries.length > 0) {
    const memorySummary = 'Conversation memory summary from earlier turns:\n' + memoryEntries.join('\n\n');
    rebuilt.push({
      role: 'system',
      content: compressedContent(memorySummary, 5000)
    });
  }

  // Keep last 22 non-system messages
  const tailCount = Math.min(22, messages.length);
  const start = messages.length - tailCount;
  for (let i = start; i < messages.length; i++) {
    const original = messages[i];
    if (!original || typeof original !== 'object') continue;
    if (original.role === 'system') continue;

    const msg = { ...original };
    if (typeof msg.content === 'string' && msg.content.length > 0) {
      const max = msg.role === 'tool' ? 5000 : 7000;
      msg.content = compressedContent(msg.content, max);
    }
    rebuilt.push(msg);
  }

  return rebuilt;
}

function appendMemoryEntry(userPrompt, assistantResponse, memoryEntries) {
  const q = compressedContent((userPrompt || '').trim(), 260);
  const a = compressedContent((assistantResponse || '').trim(), 360);
  if (!q && !a) return memoryEntries;

  const entry = `Q: ${q}\nA: ${a}`;
  const entries = [...memoryEntries, entry];
  while (entries.length > 18) {
    entries.shift();
  }
  return entries;
}

async function sendChatCompletion(messages, tools, config) {
  let baseURL = config.baseURL || 'https://api.openai.com';
  while (baseURL.endsWith('/')) baseURL = baseURL.slice(0, -1);
  const url = `${baseURL}/v1/chat/completions`;

  const body = {
    model: config.model || 'gpt-4o-mini',
    messages: messages
  };
  if (tools && tools.length > 0) {
    body.tools = tools;
  }

  const headers = {
    'Content-Type': 'application/json',
    'Authorization': `Bearer ${config.apiKey}`
  };
  if (config.project) headers['OpenAI-Project'] = config.project;
  if (config.organization) headers['OpenAI-Organization'] = config.organization;

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 90000);

  try {
    const response = await fetch(url, {
      method: 'POST',
      headers,
      body: JSON.stringify(body),
      signal: controller.signal
    });

    clearTimeout(timeout);

    const json = await response.json();

    if (!response.ok) {
      const errMsg = json?.error?.message || 'Request failed.';
      throw new Error(`HTTP ${response.status}: ${errMsg}`);
    }

    const choice = json.choices?.[0];
    const message = choice?.message;
    if (!message) throw new Error('No message in response.');

    return message;
  } catch (err) {
    clearTimeout(timeout);
    if (err.name === 'AbortError') throw new Error('Request timed out.');
    throw err;
  }
}

async function runAgentLoop(state, driveModule, onThinking, onedriveModule) {
  const { conversationMessages, memoryEntries } = state;
  const apiKey = getConfigValue('OPENAI_API_KEY');
  if (!apiKey) throw new Error('Missing API key. Add OPENAI_API_KEY to apertureai.env.');

  const model = getConfigValue('OPENAI_MODEL') || 'gpt-4o-mini';
  const baseURL = getConfigValue('OPENAI_BASE_URL') || 'https://api.openai.com';
  const project = getConfigValue('OPENAI_PROJECT') || null;
  const organization = getConfigValue('OPENAI_ORGANIZATION') || null;
  const hasDrive = driveModule && driveModule.isConfigured();
  const hasOneDrive = onedriveModule && onedriveModule.isConfigured();

  const config = { apiKey, model, baseURL, project, organization };
  const toolDefs = getToolDefinitions(hasDrive, hasOneDrive);
  const tools = toolDefs.length > 0 ? toolDefs : null;

  let iterations = 8;

  while (iterations > 0) {
    iterations--;

    // Compact before sending
    const compacted = compactConversationIfNeeded(conversationMessages, memoryEntries);
    if (compacted !== conversationMessages) {
      conversationMessages.length = 0;
      conversationMessages.push(...compacted);
    }

    const message = await sendChatCompletion(conversationMessages, tools, config);
    const toolCalls = message.tool_calls;
    const content = message.content || null;

    if (Array.isArray(toolCalls) && toolCalls.length > 0) {
      // Build assistant message with tool_calls
      const assistantMsg = { role: 'assistant' };
      if (content) assistantMsg.content = content;
      assistantMsg.tool_calls = toolCalls.map(tc => ({
        id: tc.id || '',
        type: 'function',
        function: {
          name: tc.function?.name || '',
          arguments: tc.function?.arguments || ''
        }
      }));
      conversationMessages.push(assistantMsg);

      // Execute tool calls sequentially
      for (const tc of toolCalls) {
        const result = await executeToolCall(tc, driveModule, onThinking, onedriveModule);
        const boundedResult = compressedContent(result || '', 9000);
        conversationMessages.push({
          role: 'tool',
          tool_call_id: tc.id || '',
          content: boundedResult
        });
      }

      if (onThinking) onThinking('Thinking...');
      continue;
    }

    // No tool calls — final answer
    return content || 'No response text returned.';
  }

  throw new Error('Agent reached maximum iterations without a final response.');
}

async function executeToolCall(toolCall, driveModule, onThinking, onedriveModule) {
  const funcName = toolCall.function?.name;
  let args = {};
  try {
    if (toolCall.function?.arguments) {
      args = JSON.parse(toolCall.function.arguments);
    }
  } catch (e) { /* ignore parse errors */ }

  const rootFolderId = getConfigValue('GOOGLE_DRIVE_FOLDER_ID');

  // Google Drive tools
  if (funcName === 'list_drive_files') {
    let folderId = args.folder_id;
    if (!folderId || folderId === 'root') folderId = rootFolderId || null;
    if (onThinking) onThinking('Browsing Drive files...');
    try {
      return await driveModule.listFiles(folderId);
    } catch (err) {
      return `Error: ${err.message}`;
    }
  } else if (funcName === 'search_drive_files') {
    const query = (args.query || '').trim();
    if (!query) return 'Error: Missing required query.';
    if (onThinking) onThinking('Searching Drive...');
    try {
      return await driveModule.searchFiles(query);
    } catch (err) {
      return `Error: ${err.message}`;
    }
  } else if (funcName === 'read_drive_file') {
    const fileId = args.file_id;
    if (!fileId) return 'Error: Missing required file_id.';
    const isExport = !!args.export;
    if (onThinking) onThinking('Reading file...');
    try {
      return await driveModule.readFile(fileId, isExport);
    } catch (err) {
      return `Error: ${err.message}`;
    }
  }

  // Microsoft OneDrive tools
  if (funcName === 'list_onedrive_files') {
    const folderId = args.folder_id || null;
    const driveOptions = { driveId: args.drive_id, siteId: args.site_id, userId: args.user_id };
    if (onThinking) onThinking('Browsing OneDrive files...');
    try {
      return await onedriveModule.listFiles(folderId, driveOptions);
    } catch (err) {
      return `Error: ${err.message}`;
    }
  } else if (funcName === 'search_onedrive_files') {
    const query = (args.query || '').trim();
    if (!query) return 'Error: Missing required query.';
    const driveOptions = { driveId: args.drive_id, siteId: args.site_id, userId: args.user_id };
    if (onThinking) onThinking('Searching OneDrive...');
    try {
      return await onedriveModule.searchFiles(query, driveOptions);
    } catch (err) {
      return `Error: ${err.message}`;
    }
  } else if (funcName === 'read_onedrive_file') {
    const itemId = args.item_id;
    if (!itemId) return 'Error: Missing required item_id.';
    const driveOptions = { driveId: args.drive_id, siteId: args.site_id, userId: args.user_id };
    if (onThinking) onThinking('Reading OneDrive file...');
    try {
      return await onedriveModule.readFile(itemId, driveOptions);
    } catch (err) {
      return `Error: ${err.message}`;
    }
  }

  return `Unknown tool: ${funcName}`;
}

module.exports = {
  defaultSystemPrompt,
  compressedContent,
  compactConversationIfNeeded,
  appendMemoryEntry,
  runAgentLoop
};
