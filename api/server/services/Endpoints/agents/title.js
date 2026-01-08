const { isEnabled } = require('@librechat/api');
const { logger } = require('@librechat/data-schemas');
const { CacheKeys } = require('librechat-data-provider');
const getLogStores = require('~/cache/getLogStores');
const { saveConvo } = require('~/models');

/**
 * Generate a fallback title from the user's message text
 * @param {string} text - The user's message text
 * @returns {string} A truncated title derived from the message
 */
const generateFallbackTitle = (text) => {
  if (!text || typeof text !== 'string') {
    return 'New Chat';
  }
  // Remove excessive whitespace and newlines
  const cleanText = text.replace(/\s+/g, ' ').trim();
  if (!cleanText) {
    return 'New Chat';
  }
  // Truncate to 40 characters max, adding ellipsis if needed
  if (cleanText.length <= 40) {
    return cleanText;
  }
  return cleanText.substring(0, 37) + '...';
};

/**
 * Add title to conversation in a way that avoids memory retention
 */
const addTitle = async (req, { text, response, client }) => {
  const { TITLE_CONVO = true } = process.env ?? {};
  if (!isEnabled(TITLE_CONVO)) {
    return;
  }

  if (client.options.titleConvo === false) {
    return;
  }

  const titleCache = getLogStores(CacheKeys.GEN_TITLE);
  const key = `${req.user.id}-${response.conversationId}`;
  /** @type {NodeJS.Timeout} */
  let timeoutId;
  let title;
  try {
    const timeoutPromise = new Promise((_, reject) => {
      timeoutId = setTimeout(() => reject(new Error('Title generation timeout')), 45000);
    }).catch((error) => {
      logger.error('Title error:', error);
    });

    let titlePromise;
    let abortController = new AbortController();
    if (client && typeof client.titleConvo === 'function') {
      titlePromise = Promise.race([
        client
          .titleConvo({
            text,
            abortController,
          })
          .catch((error) => {
            logger.error('Client title error:', error);
          }),
        timeoutPromise,
      ]);
    } else {
      // If client doesn't have titleConvo, use fallback
      title = generateFallbackTitle(text);
    }

    if (titlePromise) {
      title = await titlePromise;
    }
    if (!abortController.signal.aborted) {
      abortController.abort();
    }
    if (timeoutId) {
      clearTimeout(timeoutId);
    }

    // If LLM title generation failed, use fallback
    if (!title) {
      logger.debug(`[${key}] No title generated from LLM, using fallback`);
      title = generateFallbackTitle(text);
    }

    await titleCache.set(key, title, 120000);
    await saveConvo(
      req,
      {
        conversationId: response.conversationId,
        title,
      },
      { context: 'api/server/services/Endpoints/agents/title.js' },
    );
  } catch (error) {
    logger.error('Error generating title:', error);
    // Even on error, try to save a fallback title
    try {
      const fallbackTitle = generateFallbackTitle(text);
      await titleCache.set(key, fallbackTitle, 120000);
      await saveConvo(
        req,
        {
          conversationId: response.conversationId,
          title: fallbackTitle,
        },
        { context: 'api/server/services/Endpoints/agents/title.js - fallback' },
      );
    } catch (fallbackError) {
      logger.error('Error saving fallback title:', fallbackError);
    }
  }
};

module.exports = addTitle;
