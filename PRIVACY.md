# openTihui Privacy Policy

**Last updated: June 30, 2026**

openTihui is designed so that your data stays on your device. The app collects
no analytics, contains no trackers and no ads, and has no server of its own.

## What stays on your device

- **Chats and generated text** — conversations are stored only on your device
  (in the app's private storage) and are processed by the language model running
  **on-device** via llama.cpp.
- **Models** — GGUF model files you download or import are stored in the app's
  Documents folder, under your control in the Files app.
- **Settings and shortcuts** — stored locally as plain JSON.
- **API keys** — keys for endpoints you add are stored only on your device, in a
  file written with complete file protection. They are sent only to the endpoint
  they belong to.

## What leaves your device (only at your direction)

- **Cloud endpoints you configure.** If you add an OpenAI-compatible API
  endpoint, the content of the chats you run against it (your messages, and
  images if you attach them) is sent to **that endpoint** so it can generate a
  reply. openTihui adds no other destination. The endpoint's own privacy policy
  applies to that traffic.
- **Model downloads.** Downloading a model contacts the source you chose
  (e.g. Hugging Face, or a URL you paste).
- Local-network endpoints (e.g. a self-hosted `llama-server`) are reached only
  when you add one; iOS asks for Local Network permission first.

## The keyboard extension

- The keyboard **makes no network requests** and never transmits what you type.
- Typing works entirely locally. Text near the cursor is handed to the openTihui
  app **only when you tap a shortcut or "Generate in app"**, and is processed as
  described above.
- **Full Access is used solely to exchange data with the openTihui app**: your
  shortcut setup and generated results are shared through a private App Group
  container between the app and the keyboard (with the clipboard as a fallback
  for the same data). Nothing else.

## Permissions

- **Camera / Photos** — used only to attach images you choose (or a recent
  screenshot you explicitly accept) to a chat for on-device multimodal
  inference.
- **Microphone** — used only when you tap Record Audio, to attach a clip to a
  chat for on-device multimodal inference.
- **Local Network** — used only to reach LAN model servers you add.

## Analytics and tracking

None. openTihui collects no personal data, no usage analytics, and does no
tracking. There are no third-party SDKs.

## Open source

openTihui is open source — you can verify all of the above in the code:
<https://github.com/cyyself/OpenTihui>

## Contact

Questions or concerns: please open an issue at
<https://github.com/cyyself/OpenTihui/issues>.
