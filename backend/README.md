# Backend

Small Express server that receives OCR requests from Flutter and calls Gemini
with a server-side API key.

## Setup

1. Copy `.env.example` to `.env`
2. Put your Gemini key in `GEMINI_API_KEY`
3. Optionally add more keys in `GEMINI_API_KEY_1`, `GEMINI_API_KEY_2`, `GEMINI_API_KEY_3`
4. Optionally choose one or more fallback models in `GEMINI_MODELS`
3. Install packages
4. Start the server

```bash
npm install
npm run start
```

Default URL:

- `http://localhost:8080`

Example `backend/.env`:

```env
PORT=8080
GEMINI_API_KEY=YOUR_FIRST_PROJECT_KEY
GEMINI_API_KEY_1=YOUR_SECOND_PROJECT_KEY
GEMINI_API_KEY_2=YOUR_THIRD_PROJECT_KEY
GEMINI_MODELS=gemini-2.5-flash,gemini-2.0-flash
```

Important:

- Multiple keys only help if they are from different Google projects.
- Keys from the same project share the same Gemini quota.
- The backend now cools down rate-limited keys automatically and tries the next key/model.

## Endpoints

- `GET /health`
- `POST /extract`
- `POST /fill-missing`
- `POST /generate-field`
- `POST /generate-summary`
- `POST /extract-single-field`
- `POST /smart-scan-field`

## Flutter Connection

Set the Flutter `.env` file:

- emulator: `BACKEND_URL=http://10.0.2.2:8080`
- real phone: `BACKEND_URL=http://YOUR_PC_LAN_IP:8080`
