# Privacy Policy

All audio is processed on-device. Audio buffers are never saved or transmitted.

## Live Link

- **Public Tunnel (default when sharing)**: When Public Tunnel is enabled, caption payloads are encrypted end-to-end (`AES-256-GCM`) using a session key placed in the `#k=` URL fragment (which is never sent in HTTP requests) and relayed through a third-party `localhost.run` SSH reverse tunnel. `localhost.run` terminates TLS, serves the viewer HTML/JS page, and can observe connection metadata such as IP addresses, request paths/tokens, timing, and packet sizes, though it cannot decrypt the `AES-256-GCM` caption payloads without the `#k=` fragment.
- **Localhost (`127.0.0.1`)**: Connections on the local Mac use `AES-256-GCM` encrypted payloads via WebCrypto.
- **Local Wi-Fi (LAN)**: When Local Wi-Fi (LAN) is explicitly enabled, viewers on the local network connect over unencrypted HTTP (because browser WebCrypto requires HTTPS or `localhost`). Only enable Local Wi-Fi (LAN) on trusted networks.

## Local Storage

User preferences are stored locally in `UserDefaults`. Transcripts are held only in memory during the active session and are cleared when you clear the transcript or quit the app. No analytics or telemetry are collected.
