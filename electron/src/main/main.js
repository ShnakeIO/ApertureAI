const { app, BrowserWindow, ipcMain } = require('electron');
const path = require('path');
const crypto = require('crypto');
const { loadConfig, getConfigValue, getUserConfigPath } = require('./config');
const { defaultSystemPrompt, runAgentLoop, appendMemoryEntry, compactConversationIfNeeded } = require('./openai');
const driveModule = require('./google-drive');
const onedriveModule = require('./onedrive');
const feedbackModule = require('./feedback');
const { saveChatState, loadChatState, saveCurrentChatToHistory } = require('./persistence');
const { initAutoUpdater, quitAndInstall, stopAutoUpdater, getUpdaterStatus } = require('./updater');

let mainWindow = null;

// App state
let conversationMessages = [];
let chatHistory = [];
let currentChatId = crypto.randomUUID();
let memoryEntries = [];
let lastUserPrompt = '';
let requestInFlight = false;

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 980,
    height: 700,
    minWidth: 720,
    minHeight: 520,
    title: 'ApertureAI',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false
    }
  });

  mainWindow.loadFile(path.join(__dirname, '..', 'renderer', 'index.html'));

  mainWindow.on('closed', () => {
    mainWindow = null;
  });
}

function persistState() {
  chatHistory = saveCurrentChatToHistory(currentChatId, conversationMessages, chatHistory);
  saveChatState({ currentChatId, conversationMessages, chatHistory });
}

function initializeState() {
  loadConfig();
  driveModule.loadServiceAccount();

  const saved = loadChatState();
  if (saved && saved.conversationMessages && saved.conversationMessages.length > 0) {
    conversationMessages = saved.conversationMessages;
    chatHistory = saved.chatHistory || [];
    currentChatId = saved.currentChatId || crypto.randomUUID();

    // Ensure system message
    const hasSystem = conversationMessages.some(m => m.role === 'system');
    if (!hasSystem) {
      conversationMessages.unshift({ role: 'system', content: defaultSystemPrompt(driveModule.isConfigured(), onedriveModule.isConfigured()) });
    }
    memoryEntries = [];
    return true;
  }

  return false;
}

function getStartupData(restoredState) {
  const hasDrive = driveModule.isConfigured();
  const hasOneDrive = onedriveModule.isConfigured();
  const hasApiKey = !!getConfigValue('OPENAI_API_KEY');
  const model = getConfigValue('OPENAI_MODEL') || 'gpt-4o-mini';

  // Build messages to display
  const displayMessages = [];
  if (restoredState) {
    // Rebuild display from conversation messages
    for (const msg of conversationMessages) {
      if (msg.role === 'user') {
        displayMessages.push({ text: msg.content, isUser: true });
      } else if (msg.role === 'assistant' && typeof msg.content === 'string' && msg.content.length > 0) {
        displayMessages.push({ text: msg.content, isUser: false });
      }
    }
  } else {
    // Fresh start
    conversationMessages = [{ role: 'system', content: defaultSystemPrompt(hasDrive, hasOneDrive) }];
    currentChatId = crypto.randomUUID();
    memoryEntries = [];

    if (hasDrive || hasOneDrive) {
      const sources = [];
      if (hasDrive) sources.push('Google Drive');
      if (hasOneDrive) sources.push('OneDrive');
      displayMessages.push({ text: `Welcome to ApertureAI. I can browse and read your ${sources.join(' and ')} files. Ask me anything!`, isUser: false });
    } else {
      displayMessages.push({ text: 'Welcome to ApertureAI. Cloud storage access is not configured yet.', isUser: false });
    }
    if (!hasApiKey) {
      displayMessages.push({ text: 'Put your API key in apertureai.env (OPENAI_API_KEY=...) then reopen the app.', isUser: false });
    }
    persistState();
  }

  return {
    displayMessages,
    hasApiKey,
    hasDrive,
    hasOneDrive,
    model,
    appVersion: app.getVersion(),
    status: hasApiKey ? 'Ready' : 'No API key'
  };
}

// IPC Handlers
function registerIpcHandlers() {
  ipcMain.handle('chat:send', async (_event, text) => {
    if (requestInFlight) return { error: 'Request already in flight.' };
    if (!text || !text.trim()) return { error: 'Empty message.' };

    const trimmed = text.trim();
    requestInFlight = true;
    lastUserPrompt = trimmed;
    conversationMessages.push({ role: 'user', content: trimmed });
    persistState();

    try {
      const onThinking = (thinkingText) => {
        if (mainWindow) {
          mainWindow.webContents.send('chat:thinking', thinkingText);
        }
      };

      const responseText = await runAgentLoop(
        { conversationMessages, memoryEntries },
        driveModule,
        onThinking,
        onedriveModule
      );

      conversationMessages.push({ role: 'assistant', content: responseText });
      memoryEntries = appendMemoryEntry(lastUserPrompt, responseText, memoryEntries);
      persistState();
      requestInFlight = false;
      return { response: responseText };
    } catch (err) {
      requestInFlight = false;
      persistState();
      return { error: err.message };
    }
  });

  ipcMain.handle('chat:newChat', async () => {
    if (requestInFlight) return { error: 'Cannot create new chat while request is in flight.' };

    chatHistory = saveCurrentChatToHistory(currentChatId, conversationMessages, chatHistory);
    const hasDrive = driveModule.isConfigured();
    const hasOneDrive = onedriveModule.isConfigured();
    conversationMessages = [{ role: 'system', content: defaultSystemPrompt(hasDrive, hasOneDrive) }];
    currentChatId = crypto.randomUUID();
    memoryEntries = [];

    let welcomeMsg;
    if (hasDrive || hasOneDrive) {
      const sources = [];
      if (hasDrive) sources.push('Google Drive');
      if (hasOneDrive) sources.push('OneDrive');
      welcomeMsg = `Welcome to ApertureAI. I can browse and read your ${sources.join(' and ')} files. Ask me anything!`;
    } else {
      welcomeMsg = 'Welcome to ApertureAI. Cloud storage access is not configured yet.';
    }

    persistState();
    return { welcomeMessage: welcomeMsg };
  });

  ipcMain.handle('chat:loadChat', async (_event, chatId) => {
    if (requestInFlight) return { error: 'Cannot switch chat while request is in flight.' };

    const chat = chatHistory.find(c => c.id === chatId);
    if (!chat) return { error: 'Chat not found.' };

    // Save current
    chatHistory = saveCurrentChatToHistory(currentChatId, conversationMessages, chatHistory);

    // Load selected
    conversationMessages = [...(chat.messages || [])];
    currentChatId = chat.id;
    memoryEntries = [];

    persistState();

    // Build display messages
    const displayMessages = [];
    for (const msg of conversationMessages) {
      if (msg.role === 'user') {
        displayMessages.push({ text: msg.content, isUser: true });
      } else if (msg.role === 'assistant' && typeof msg.content === 'string' && msg.content.length > 0) {
        displayMessages.push({ text: msg.content, isUser: false });
      }
    }
    return { displayMessages };
  });

  ipcMain.handle('chat:getHistory', async () => {
    // Sort by timestamp descending
    const sorted = [...chatHistory].sort((a, b) => (b.timestamp || 0) - (a.timestamp || 0));
    return sorted.map(c => ({
      id: c.id,
      title: c.title || 'Chat',
      timestamp: c.timestamp || 0,
      isCurrent: c.id === currentChatId
    }));
  });

  ipcMain.handle('chat:getSettings', async () => {
    const hasApiKey = !!getConfigValue('OPENAI_API_KEY');
    const model = getConfigValue('OPENAI_MODEL') || 'gpt-4o-mini';
    const hasDrive = driveModule.isConfigured();
    const hasOneDrive = onedriveModule.isConfigured();
    const hasGitHubToken = !!(getConfigValue('GITHUB_TOKEN') || getConfigValue('GH_TOKEN'));
    const userConfigPath = getUserConfigPath();
    const feedbackStatus = feedbackModule.getStatus();
    return {
      hasApiKey,
      model,
      hasDrive,
      hasOneDrive,
      hasGitHubToken,
      userConfigPath,
      appVersion: app.getVersion(),
      feedbackConfigured: feedbackStatus.configured,
      feedbackDocId: feedbackStatus.docId
    };
  });

  ipcMain.handle('feedback:status', async () => {
    return feedbackModule.getStatus();
  });

  ipcMain.handle('feedback:list', async (_event, limit) => {
    return feedbackModule.listReports(limit);
  });

  ipcMain.handle('feedback:submit', async (_event, payload) => {
    const hasDrive = driveModule.isConfigured();
    const hasOneDrive = onedriveModule.isConfigured();
    const storageSummary =
      hasDrive && hasOneDrive
        ? 'Google Drive + OneDrive'
        : hasDrive
          ? 'Google Drive'
          : hasOneDrive
            ? 'OneDrive'
            : 'Not configured';

    return feedbackModule.submitReport({
      ...payload,
      appVersion: app.getVersion(),
      model: getConfigValue('OPENAI_MODEL') || 'gpt-4o-mini',
      storageSummary
    });
  });

  ipcMain.handle('guides:getCatalog', async () => {
    return [
      {
        id: 'factory_reset_windows_pc',
        title: 'Factory resetting your PC',
        keywords: 'windows reset remove everything local reinstall erase wipe',
        system_prompt:
          'You are helping with a Windows factory reset workflow. Keep instructions concrete and safe. ' +
          'This guide is for Windows PCs and for removing everything with a local reinstall. ' +
          'Before destructive actions, remind the user about backups and BitLocker recovery keys. ' +
          'Use short numbered steps and ask one diagnostic question at a time if they are stuck.',
        quick_steps: [
          'Open Settings and go to Recovery',
          'Choose Reset this PC',
          'Select Remove everything',
          'Choose Local reinstall',
          'Review reset options and confirm',
          'Run Windows Update after setup'
        ],
        content:
          'Diagnosis: This guide is for Windows PCs only.\n' +
          'Use this when you want to delete everything from the computer and do a local reinstall of Windows.\n\n' +
          'Before you start:\n' +
          '1. Plug the PC into power.\n' +
          '2. Back up anything you need (Desktop, Documents, browser passwords, 2FA backup codes).\n' +
          '3. If BitLocker is enabled, make sure you have your recovery key.\n' +
          '4. Sign in with an administrator account.\n\n' +
          'Reset steps (Windows 11 / Windows 10):\n' +
          '1. Open Settings.\n' +
          '2. Windows 11: System > Recovery.\n' +
          '   Windows 10: Update & Security > Recovery.\n' +
          '3. Under Reset this PC, click Reset PC (or Get started).\n' +
          '4. Choose Remove everything.\n' +
          '5. Choose Local reinstall.\n' +
          '6. Review Additional settings. If this PC is staying with you, keep clean-data off for speed. If giving away, enable clean-data.\n' +
          '7. Click Next, then Reset.\n' +
          '8. Wait while Windows restarts several times.\n\n' +
          'After reset:\n' +
          '1. Complete setup.\n' +
          '2. Run Windows Update.\n' +
          '3. Reinstall drivers and apps.\n' +
          '4. Restore your backups.\n\n' +
          'If reset fails:\n' +
          '- Open Command Prompt (Admin) and run: sfc /scannow\n' +
          '- Then run: DISM /Online /Cleanup-Image /RestoreHealth\n' +
          '- Retry the reset.\n\n' +
          'Use Back to Chat if you want live help with any step.'
      }
    ];
  });

  ipcMain.handle('guides:applyContext', async (_event, guideId) => {
    // Remove any existing guide context messages
    const prefix = '[ApertureAI Guide Context]';
    conversationMessages = conversationMessages.filter(m => {
      if (m.role === 'system' && typeof m.content === 'string' && m.content.startsWith(prefix)) {
        return false;
      }
      return true;
    });

    if (guideId) {
      const catalog = await ipcMain.emit('guides:getCatalog'); // reuse
      // For simplicity, hardcode the lookup
      const guides = [
        {
          id: 'factory_reset_windows_pc',
          system_prompt:
            'You are helping with a Windows factory reset workflow. Keep instructions concrete and safe. ' +
            'This guide is for Windows PCs and for removing everything with a local reinstall. ' +
            'Before destructive actions, remind the user about backups and BitLocker recovery keys. ' +
            'Use short numbered steps and ask one diagnostic question at a time if they are stuck.'
        }
      ];
      const guide = guides.find(g => g.id === guideId);
      if (guide && guide.system_prompt) {
        const guideContext = `${prefix}\n${guide.system_prompt}`;
        // Insert after the first system message
        const firstSystemIdx = conversationMessages.findIndex(m => m.role === 'system');
        const insertIdx = firstSystemIdx >= 0 ? firstSystemIdx + 1 : 0;
        conversationMessages.splice(insertIdx, 0, { role: 'system', content: guideContext });
      }
    }

    persistState();
    return { ok: true };
  });

  ipcMain.handle('update:install', async () => {
    quitAndInstall();
  });

  ipcMain.handle('update:getStatus', async () => {
    return getUpdaterStatus();
  });
}

// App lifecycle
app.whenReady().then(() => {
  const restoredState = initializeState();
  createWindow();
  registerIpcHandlers();

  mainWindow.webContents.on('did-finish-load', () => {
    const startupData = getStartupData(restoredState);
    mainWindow.webContents.send('chat:stateRestored', startupData);
  });

  // Auto-updater
  initAutoUpdater(mainWindow);
});

app.on('window-all-closed', () => {
  app.quit();
});

app.on('before-quit', () => {
  stopAutoUpdater();
  persistState();
});
