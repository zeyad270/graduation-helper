# Graduation GPRR Helper

Flutter app for scanning graduation project pages, extracting fields with Gemini,
storing projects locally, and syncing them to Google Sheets.

## Architecture

- `lib/`: Flutter app
- `backend/`: Node.js server that calls Gemini securely

The Flutter app no longer needs Gemini API keys inside the APK. It now sends
requests to the backend, and the backend talks to Gemini.

## Flutter Setup

1. Copy `.env.example` to `.env` if needed.
2. Set `BACKEND_URL`.

Examples:

- Android emulator: `BACKEND_URL=http://10.0.2.2:8080`
- Real phone on same Wi-Fi as your PC: `BACKEND_URL=http://YOUR_PC_LAN_IP:8080`

## Backend Setup

1. Open `backend/`
2. Copy `.env.example` to `.env`
3. Add your server-side `GEMINI_API_KEY`
4. Run:

```bash
npm install
npm run start
```

Health check:

- `GET http://localhost:8080/health`

## Important

- Rebuild and reinstall the APK after changing `.env`
- For a real phone, `10.0.2.2` will not work. Use your computer's LAN IP instead.
- Keep Gemini keys only in `backend/.env`, never in the Flutter app
