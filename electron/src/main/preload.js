const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('api', {
  // Chat
  sendMessage: (text) => ipcRenderer.invoke('chat:send', text),
  newChat: () => ipcRenderer.invoke('chat:newChat'),
  loadChat: (chatId) => ipcRenderer.invoke('chat:loadChat', chatId),
  getHistory: () => ipcRenderer.invoke('chat:getHistory'),
  getSettings: () => ipcRenderer.invoke('chat:getSettings'),
  submitFeedback: (payload) => ipcRenderer.invoke('feedback:submit', payload),
  getFeedbackReports: (limit) => ipcRenderer.invoke('feedback:list', limit),
  getFeedbackStatus: () => ipcRenderer.invoke('feedback:status'),
  uploadKnowledgeFiles: () => ipcRenderer.invoke('knowledge:uploadFiles'),

  // Guides
  getGuidesCatalog: () => ipcRenderer.invoke('guides:getCatalog'),
  applyGuideContext: (guideId) => ipcRenderer.invoke('guides:applyContext', guideId),

  // Update
  installUpdate: () => ipcRenderer.invoke('update:install'),
  getUpdaterStatus: () => ipcRenderer.invoke('update:getStatus'),

  // Events from main process
  onThinking: (callback) => {
    ipcRenderer.on('chat:thinking', (_event, text) => callback(text));
  },
  onStateRestored: (callback) => {
    ipcRenderer.on('chat:stateRestored', (_event, data) => callback(data));
  },
  onUpdateAvailable: (callback) => {
    ipcRenderer.on('update:available', (_event, version) => callback(version));
  },
  onUpdateDownloaded: (callback) => {
    ipcRenderer.on('update:downloaded', (_event, version) => callback(version));
  },
  onUpdateNotAvailable: (callback) => {
    ipcRenderer.on('update:not-available', () => callback());
  },
  onUpdateStatus: (callback) => {
    ipcRenderer.on('update:status', (_event, status) => callback(status));
  }
});
