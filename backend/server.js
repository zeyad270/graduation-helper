import cors from 'cors';
import dotenv from 'dotenv';
import express from 'express';

dotenv.config();

const app = express();
const port = Number(process.env.PORT || 8080);
const geminiModel =
  process.env.GEMINI_MODEL?.trim() || 'gemini-2.5-flash';

// Load all 4 API keys
const GEMINI_API_KEYS = [
  process.env.GEMINI_API_KEY?.trim(),
  process.env.GEMINI_API_KEY_1?.trim(),
  process.env.GEMINI_API_KEY_2?.trim(),
  process.env.GEMINI_API_KEY_3?.trim(),
].filter(Boolean); // Remove any undefined keys

// API Key Manager - handles rotation and failover
class ApiKeyManager {
  constructor(keys) {
    this.keys = keys;
    this.currentIndex = 0;
    this.keyStats = {};
    keys.forEach((key, idx) => {
      this.keyStats[idx] = { attempts: 0, failures: 0, lastUsed: null };
    });
  }

  getNextKey() {
    if (this.keys.length === 0) return null;
    const key = this.keys[this.currentIndex];
    this.keyStats[this.currentIndex].lastUsed = new Date();
    return key;
  }

  rotateKey() {
    this.currentIndex = (this.currentIndex + 1) % this.keys.length;
  }

  recordFailure(keyIndex) {
    if (this.keyStats[keyIndex]) {
      this.keyStats[keyIndex].failures++;
    }
  }

  recordSuccess(keyIndex) {
    if (this.keyStats[keyIndex]) {
      this.keyStats[keyIndex].attempts++;
    }
  }

  getStats() {
    return this.keyStats;
  }

  getHealthStatus() {
    return {
      totalKeys: this.keys.length,
      currentIndex: this.currentIndex,
      stats: this.keyStats,
    };
  }
}

const keyManager = new ApiKeyManager(GEMINI_API_KEYS);

const GEMINI_URL =
  `https://generativelanguage.googleapis.com/v1beta/models/${geminiModel}:generateContent`;

const ALL_KEYS = [
  'title',
  'students',
  'supervisor',
  'year',
  'abstract',
  'technologies',
  'description',
  'keywords',
  'category',
  'problem',
  'solution',
  'objectives',
];

const FIELD_INSTRUCTIONS = {
  title:
    'Extract ONLY the specific project title. NOT university or faculty name.',
  students: 'Extract ALL student full names as comma-separated list.',
  supervisor: 'Extract supervisor full name with title (Dr./Prof./Eng.).',
  year: 'Extract the 4-digit submission year only.',
  category:
    'Pick ONE: Medical, Education, Finance, E-Commerce, Social Media, Entertainment, Transportation, Smart Agriculture, IoT/Smart Home, Manufacturing, Other',
  technologies:
    'List all technologies, frameworks, programming languages mentioned.',
  keywords:
    'Extract keywords from explicit Keywords section only. Comma-separated.',
  abstract:
    'Extract the COMPLETE abstract. Copy every sentence word-for-word. Remove the label. Do NOT include any other section.',
  description:
    'Extract the first Overview or Introduction section ONLY. Copy word-for-word. Stop at the next subheading. Do NOT combine with Project Overview or other sections.',
  problem:
    'Extract the COMPLETE problem statement. Copy every sentence and numbered point word-for-word.',
  solution:
    'Extract the COMPLETE proposed solution. Copy every sentence word-for-word.',
  objectives:
    'Extract the COMPLETE objectives section ONLY. Copy every bullet and numbered item word-for-word. Do NOT include Project Overview.',
};

const FIELD_CONTEXT = {
  abstract:
    'Abstract or executive summary labeled Abstract, Summary, or Executive Summary. Not a chapter introduction.',
  description:
    'The first overview or introduction section only. Copy word-for-word and stop at the next subheading.',
  problem:
    'Problem statement labeled Problem, Problem Statement, Problem Definition, Challenges, Issues, or Motivation.',
  solution:
    'Proposed solution labeled Solution, Proposed Solution, Approach, Methodology, or System Design.',
  objectives:
    'Objectives or goals section only. Include all numbered or bulleted items. Do not include Project Overview.',
  technologies:
    'Technology stack such as tools, languages, frameworks, and databases.',
  keywords: 'Keywords listed explicitly under a Keywords label.',
  title: 'The main project title.',
  supervisor: 'Supervisor or advisor with title Dr., Prof., or Eng.',
  students: 'All student names.',
  year: 'Submission or academic year.',
  category: 'Project category or domain.',
};

const MAIN_PROMPT_WITH_SUMMARY = `
You are analyzing a graduation project document from an Egyptian university.
Formats vary widely. Use visual intelligence to find and extract each field.

Return a single valid JSON object. Use "" for missing fields.

FIELDS:
- title: Specific project name. NOT university/faculty/department. Usually prominent text.
- students: ALL student full names comma-separated. Look near "Project Team", "Prepared by", "By".
- supervisor: Supervisor with title (Dr./Prof./Eng.). Near "Supervisor"/"Supervised by". One name only.
- year: 4-digit year e.g. "2026".
- category: ONE of: Medical, Education, Finance, E-Commerce, Social Media, Entertainment, Transportation, Smart Agriculture, IoT/Smart Home, Manufacturing, Other
- technologies: Comma-separated tools/languages/frameworks. "" if not found.
- keywords: Only if explicit "Keywords:" section. "" otherwise.
- abstract: COPY word-for-word from the Abstract section ONLY. Every sentence. Do NOT truncate. Do NOT include any other section.
- description: COPY word-for-word from the first Overview or Introduction section ONLY. Stop at the next subheading. Do NOT combine multiple sections.
- problem: COPY word-for-word from the Problem section ONLY. Every sentence and numbered point. Do NOT truncate.
- solution: COPY word-for-word from the Solution/Methodology section ONLY. Every sentence. Do NOT truncate.
- objectives: COPY word-for-word from the Objectives section ONLY. Every bullet and number. Do NOT include Project Overview or any other section.
- summary: Write a 3-5 sentence professional executive summary of the entire project. Highlight the problem, solution, technologies, and value. If too few fields are extracted, write "" for this.

RULES:
1. Return ONLY the JSON and no markdown
2. All values on ONE LINE and replace line breaks with spaces
3. Escape double quotes inside values with backslash
4. NEVER invent data and use "" if not found
5. NEVER merge content from different sections into one field
6. Remove section labels from the start of values
7. COPY text exactly and do not paraphrase except for summary
`;

app.use(cors());
app.use(express.json({ limit: '30mb' }));

function requireGeminiKey() {
  if (GEMINI_API_KEYS.length === 0) {
    const error = new Error(
      'Missing GEMINI_API_KEY in backend/.env. Copy backend/.env.example to backend/.env and add your server keys: GEMINI_API_KEY, GEMINI_API_KEY_1, GEMINI_API_KEY_2, GEMINI_API_KEY_3',
    );
    error.status = 500;
    throw error;
  }
}

function errorResponse(res, error) {
  const status = error.status || 500;
  return res.status(status).json({
    ok: false,
    error: error.message || 'Unexpected server error.',
  });
}

function sanitizeText(value) {
  return String(value ?? '').trim();
}

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function score(value, key) {
  if (!value) return 0.0;
  if (key === 'year') return /^\d{4}$/.test(value) ? 0.97 : 0.4;
  if (key === 'category') return 0.92;

  const isLong = ['abstract', 'description', 'problem', 'solution', 'objectives'].includes(key);
  if (!isLong) return value.length > 5 ? 0.88 : 0.55;

  let result = 0.0;

  if (value.length > 500) result += 0.35;
  else if (value.length > 300) result += 0.25;
  else if (value.length > 100) result += 0.15;
  else result += 0.05;

  const trimmed = value.trimEnd();
  if (/[.?!:]$/.test(trimmed)) result += 0.25;
  else if (/[,;]$/.test(trimmed)) result += 0.05;

  if (/(\d+[.)]|-)\s/.test(value)) result += 0.2;

  const lower = value.toLowerCase();
  const aiPhrases = [
    'in summary',
    'to summarize',
    'in conclusion',
    'the document states',
    'according to the document',
    'the text mentions',
    'as mentioned',
  ];
  if (aiPhrases.some((phrase) => lower.includes(phrase))) result -= 0.3;
  if (value.length < 80) result -= 0.2;

  return Math.max(0, Math.min(1, result));
}

function emptyFields() {
  const result = {};
  for (const key of [...ALL_KEYS, 'summary']) {
    result[key] = { value: '', confidence: 0.0 };
  }
  return result;
}

function normalizeFieldMap(decoded) {
  const result = {};
  for (const key of ALL_KEYS) {
    const value = sanitizeText(decoded?.[key]);
    result[key] = {
      value,
      confidence: score(value, key),
    };
  }

  const summary = sanitizeText(decoded?.summary);
  result.summary = {
    value: summary,
    confidence: summary ? 0.95 : 0.0,
  };
  return result;
}

function repairJson(raw) {
  let repaired = raw.trim();
  const quoteCount = (repaired.match(/"/g) || []).length;
  if (quoteCount % 2 !== 0) repaired += '"';

  const opens = (repaired.match(/{/g) || []).length;
  const closes = (repaired.match(/}/g) || []).length;
  if (opens > closes) repaired += '}'.repeat(Math.min(opens - closes, 5));

  return repaired;
}

function parseGeminiJson(raw) {
  const cleaned = raw.replace(/```json|```/g, '').trim();
  const first = cleaned.indexOf('{');
  const last = cleaned.lastIndexOf('}');

  if (first === -1 || last === -1 || last <= first) {
    return emptyFields();
  }

  const candidate = repairJson(cleaned.slice(first, last + 1));
  try {
    return normalizeFieldMap(JSON.parse(candidate));
  } catch {
    return emptyFields();
  }
}

function buildGeminiParts(images = [], rawTexts = []) {
  const parts = [];

  for (const image of images) {
    if (!image?.data) continue;
    parts.push({
      inline_data: {
        mime_type: image.mimeType || 'image/jpeg',
        data: image.data,
      },
    });
  }

  const texts = Array.isArray(rawTexts)
    ? rawTexts.map((item) => sanitizeText(item)).filter(Boolean)
    : [];

  if (texts.length > 0) {
    parts.push({
      text: `Additional text:\n${texts.join('\n\n---\n\n')}`,
    });
  }

  return parts;
}

async function callGemini(parts, { maxOutputTokens = 4096 } = {}) {
  requireGeminiKey();

  let lastError;
  const keysToTry = GEMINI_API_KEYS.length;
  let keyAttempts = 0;

  // Try all keys with rotation
  for (let keyAttempt = 0; keyAttempt < keysToTry; keyAttempt++) {
    // For each key, try up to 3 times
    for (let attempt = 1; attempt <= 3; attempt++) {
      const currentKey = keyManager.getNextKey();
      const currentKeyIndex = keyManager.currentIndex;

      try {
        const response = await fetch(`${GEMINI_URL}?key=${currentKey}`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            contents: [{ parts }],
            generationConfig: {
              temperature: 0.1,
              topP: 0.95,
              maxOutputTokens,
            },
          }),
        });

        const text = await response.text();
        let data = {};
        try {
          data = JSON.parse(text);
        } catch {
          data = {};
        }

        if (!response.ok) {
          const message =
            data?.error?.message ||
            `Gemini request failed with status ${response.status}.`;
          const error = new Error(message);
          error.status = response.status;

          // Check if this is a quota/rate limit error (try next key)
          const isQuotaError =
            response.status === 429 ||
            response.status === 403 ||
            /quota|rate limit|resource exhausted/i.test(message);

          // Check if retryable (temp error, try again with same key)
          const isRetryable =
            response.status >= 500 ||
            /overloaded|temporarily unavailable/i.test(message);

          // If quota error, switch to next key
          if (isQuotaError && keyAttempt < keysToTry - 1) {
            console.log(
              `[Key ${currentKeyIndex}] Quota/rate limit hit. Switching to next key...`,
            );
            keyManager.recordFailure(currentKeyIndex);
            keyManager.rotateKey();
            break; // Break inner loop to try next key
          }

          // If retryable, retry with same key
          if (isRetryable && attempt < 3) {
            console.log(
              `[Key ${currentKeyIndex}] Attempt ${attempt}/3 failed (${response.status}). Retrying...`,
            );
            await delay(attempt * 2500);
            lastError = error;
            continue; // Continue inner loop to retry
          }

          // Not retryable, throw error
          throw error;
        }

        const finishReason = data?.candidates?.[0]?.finishReason;
        if (finishReason === 'SAFETY' || finishReason === 'RECITATION') {
          const error = new Error(`Gemini blocked the request: ${finishReason}.`);
          error.status = 422;
          throw error;
        }

        const output = data?.candidates?.[0]?.content?.parts?.[0]?.text;
        if (!output) {
          const error = new Error('Gemini returned an empty response.');
          error.status = 502;
          if (attempt < 3) {
            await delay(attempt * 2000);
            lastError = error;
            continue;
          }
          throw error;
        }

        // Success!
        keyManager.recordSuccess(currentKeyIndex);
        console.log(`[Key ${currentKeyIndex}] Request successful on attempt ${attempt}`);
        return output.trim();
      } catch (error) {
        lastError = error;
        if (!error.status || (error.status !== 429 && error.status !== 403)) {
          // Non-quota error, don't retry more keys
          throw error;
        }
      }
    }
  }

  throw lastError || new Error('Gemini request failed after trying all keys.');
}

app.get('/health', (_req, res) => {
  res.json({
    ok: true,
    backend: 'running',
    geminiConfigured: GEMINI_API_KEYS.length > 0,
    apiKeysAvailable: GEMINI_API_KEYS.length,
    keyStats: keyManager.getStats(),
  });
});

app.get('/api-keys-status', (_req, res) => {
  res.json({
    ok: true,
    totalKeys: GEMINI_API_KEYS.length,
    currentKeyIndex: keyManager.currentIndex,
    keyStats: keyManager.getStats(),
  });
});

app.post('/extract', async (req, res) => {
  try {
    const parts = buildGeminiParts(req.body.images, req.body.rawTexts);
    if (parts.length === 0) {
      return res.json({ ok: true, fields: emptyFields() });
    }

    parts.push({ text: MAIN_PROMPT_WITH_SUMMARY });
    const raw = await callGemini(parts);
    return res.json({ ok: true, fields: parseGeminiJson(raw) });
  } catch (error) {
    return errorResponse(res, error);
  }
});

app.post('/fill-missing', async (req, res) => {
  try {
    const existingFields = req.body.existingFields || {};
    const images = Array.isArray(req.body.images) ? req.body.images : [];
    const contextLines = Object.entries(existingFields)
      .map(([key, value]) => [key, sanitizeText(value)])
      .filter(([, value]) => value)
      .map(([key, value]) => `${key}: ${value}`);

    const missingKeys = ALL_KEYS.filter((key) => !sanitizeText(existingFields[key]));
    if (missingKeys.length === 0) {
      return res.json({ ok: true, filledFields: {}, summary: '' });
    }

    const parts = buildGeminiParts(images, []);
    parts.push({
      text: `
You are analyzing a graduation project. Here is the known information about this project:

${contextLines.join('\n')}

${images.length > 0 ? 'Additional document pages are also provided above.' : ''}

TASK: Based on ALL available context above, intelligently generate content for ONLY these missing fields: ${missingKeys.join(', ')}

For each missing field, infer or generate appropriate content:
- If the document pages show the content, COPY it verbatim
- If it can be inferred from other fields, generate it logically
- Use academic/professional tone appropriate for a graduation project
- For "category": pick ONE of: Medical, Education, Finance, E-Commerce, Social Media, Entertainment, Transportation, Smart Agriculture, IoT/Smart Home, Manufacturing, Other
- For "year": use current year if not found: ${new Date().getFullYear()}
- For long fields (abstract, description, problem, solution, objectives): write 2-4 professional sentences minimum if not found in document

Also generate a "summary" field: a 3-5 sentence executive summary of the entire project based on ALL known information. Make it professional, highlight the problem solved and key technologies.

Return a single valid JSON object with ONLY these keys: ${missingKeys.join(', ')}, summary
Use "" for any field you truly cannot determine even from context.
All values on ONE LINE. Return ONLY the JSON.
`,
    });

    const raw = await callGemini(parts);
    const parsed = parseGeminiJson(raw);
    const filledFields = {};
    for (const key of missingKeys) {
      if (parsed[key]?.value) filledFields[key] = parsed[key];
    }

    return res.json({
      ok: true,
      filledFields,
      summary: parsed.summary?.value || '',
    });
  } catch (error) {
    return errorResponse(res, error);
  }
});

app.post('/generate-field', async (req, res) => {
  try {
    const fieldName = sanitizeText(req.body.fieldName);
    if (!fieldName) {
      return res.status(400).json({ ok: false, error: 'fieldName is required.' });
    }

    const allFields = req.body.allFields || {};
    const context = Object.entries(allFields)
      .map(([key, value]) => [key, sanitizeText(value)])
      .filter(([key, value]) => key !== fieldName && value)
      .map(([key, value]) => `${key}: ${value}`)
      .join('\n');

    const parts = buildGeminiParts(req.body.images, []);
    parts.push({
      text: `
You are writing content for a graduation project field.

PROJECT CONTEXT:
${context}

FIELD TO GENERATE: "${fieldName}"
WHAT IT SHOULD CONTAIN: ${FIELD_CONTEXT[fieldName] || `Content for ${fieldName}`}
INSTRUCTION: ${FIELD_INSTRUCTIONS[fieldName] || `Generate the ${fieldName}.`}

RULES:
- If document images show the content verbatim, COPY it word-for-word
- Otherwise, infer and write professional academic content based on the project context
- Do NOT include section headings or labels in your output
- Write in a professional academic tone
- Be specific to this project, not generic
- For "category": return ONLY ONE of: Medical, Education, Finance, E-Commerce, Social Media, Entertainment, Transportation, Smart Agriculture, IoT/Smart Home, Manufacturing, Other
- For "year": return ONLY the 4-digit year
- Return ONLY the content and no JSON
- If you truly cannot determine it: return NOT_FOUND
`,
    });

    const raw = await callGemini(parts);
    const value = raw === 'NOT_FOUND' ? '' : raw;
    return res.json({ ok: true, value });
  } catch (error) {
    return errorResponse(res, error);
  }
});

app.post('/generate-summary', async (req, res) => {
  try {
    const existingFields = req.body.existingFields || {};
    const context = Object.entries(existingFields)
      .map(([key, value]) => [key, sanitizeText(value)])
      .filter(([, value]) => value)
      .map(([key, value]) => `${key}: ${value}`)
      .join('\n');

    const parts = buildGeminiParts(req.body.images, []);
    parts.push({
      text: `
Based on this graduation project information:

${context}

Write a professional 4-6 sentence executive summary of this project that:
1. Starts with what the project is and the problem it solves
2. Mentions the key technologies used
3. Highlights the main features or objectives
4. Mentions the team or supervisor if known
5. Ends with the project's impact or value

Write in a polished academic tone. Return ONLY the summary text.
`,
    });

    const summary = await callGemini(parts);
    return res.json({ ok: true, summary });
  } catch (error) {
    return errorResponse(res, error);
  }
});

app.post('/extract-single-field', async (req, res) => {
  try {
    const fieldName = sanitizeText(req.body.fieldName);
    if (!fieldName) {
      return res.status(400).json({ ok: false, error: 'fieldName is required.' });
    }

    const parts = buildGeminiParts(req.body.images, []);
    const fallbackText = sanitizeText(req.body.fallbackText);
    if (fallbackText) {
      parts.push({ text: `Document text:\n${fallbackText}` });
    }

    if (parts.length === 0) {
      return res.json({ ok: true, value: '' });
    }

    parts.push({
      text: `${FIELD_INSTRUCTIONS[fieldName] || `Extract ${fieldName}.`}\n\nReturn ONLY the extracted text. If not found: NOT_FOUND`,
    });

    const raw = await callGemini(parts);
    const value = raw === 'NOT_FOUND' ? '' : raw;
    return res.json({ ok: true, value });
  } catch (error) {
    return errorResponse(res, error);
  }
});

app.post('/smart-scan-field', async (req, res) => {
  try {
    const fieldName = sanitizeText(req.body.fieldName);
    const images = Array.isArray(req.body.images) ? req.body.images : [];
    if (!fieldName || images.length === 0) {
      return res
        .status(400)
        .json({ ok: false, error: 'fieldName and one image are required.' });
    }

    const parts = buildGeminiParts([images[0]], []);
    parts.push({
      text: `
You are reading a page from an Egyptian university graduation project.

TASK: Extract content for the "${fieldName}" field.

WHAT TO LOOK FOR: ${FIELD_CONTEXT[fieldName] || `The ${fieldName} content.`}

RULES:
- The section may use a different label so understand meaning and not just exact labels
- Remove all headings and labels from your output
- COPY text exactly word-for-word and do not paraphrase
- Return complete text without truncating
- Extract ONLY content from the visible section and do not pull from other sections
- If page has no relevant content, return NOT_FOUND

Return ONLY the clean verbatim text.
`,
    });

    const raw = await callGemini(parts);
    const value = raw === 'NOT_FOUND' ? '' : raw;
    return res.json({ ok: true, value });
  } catch (error) {
    return errorResponse(res, error);
  }
});

app.listen(port, '0.0.0.0', () => {
  console.log(`Backend listening on http://0.0.0.0:${port}`);
});
