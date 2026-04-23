# Backend

Small Express server that receives OCR requests from Flutter and calls Gemini
with a server-side API key.

## Setup

1. Copy `.env.example` to `.env`
2. Put your Gemini key in `GEMINI_API_KEY`
3. Optionally choose a model in `GEMINI_MODEL`
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
GEMINI_API_KEY=YOUR_KEY
GEMINI_MODEL=gemini-2.5-flash
```

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
