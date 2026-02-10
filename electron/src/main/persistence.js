const fs = require('fs');
const path = require('path');
const { app } = require('electron');

function getChatStatePath() {
  const userDataDir = app.getPath('userData');
  return path.join(userDataDir, 'chat_state.json');
}

function saveChatState(state) {
  const filePath = getChatStatePath();
  const dir = path.dirname(filePath);
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }
  const payload = {
    version: 1,
    currentChatId: state.currentChatId || '',
    currentConversationMessages: state.conversationMessages || [],
    chatHistory: state.chatHistory || []
  };
  try {
    fs.writeFileSync(filePath, JSON.stringify(payload, null, 2), 'utf8');
  } catch (err) {
    console.error('Failed to save chat state:', err.message);
  }
}

function loadChatState() {
  const filePath = getChatStatePath();
  try {
    if (!fs.existsSync(filePath)) return null;
    const data = fs.readFileSync(filePath, 'utf8');
    const payload = JSON.parse(data);
    if (!payload || typeof payload !== 'object') return null;
    return {
      currentChatId: payload.currentChatId || null,
      conversationMessages: Array.isArray(payload.currentConversationMessages) ? payload.currentConversationMessages : [],
      chatHistory: Array.isArray(payload.chatHistory) ? payload.chatHistory : []
    };
  } catch (err) {
    console.error('Failed to load chat state:', err.message);
    return null;
  }
}

function saveCurrentChatToHistory(currentChatId, conversationMessages, chatHistory) {
  // Need at least one user message
  const hasUserMessage = conversationMessages.some(m => m.role === 'user');
  if (!hasUserMessage) return chatHistory;

  // Get title from first user message
  let title = 'New Chat';
  for (const msg of conversationMessages) {
    if (msg.role === 'user' && msg.content) {
      title = msg.content.length > 55 ? msg.content.substring(0, 55) + '\u2026' : msg.content;
      break;
    }
  }

  // Remove existing entry for this chat id
  const filtered = chatHistory.filter(c => c.id !== currentChatId);

  // Insert at beginning
  filtered.unshift({
    id: currentChatId,
    title: title,
    timestamp: Date.now() / 1000,
    messages: [...conversationMessages]
  });

  // Cap at 50
  while (filtered.length > 50) {
    filtered.pop();
  }

  return filtered;
}

module.exports = { saveChatState, loadChatState, saveCurrentChatToHistory };
