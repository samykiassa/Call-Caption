# Call Caption

Minimal macOS menu-bar app for live call captions, translation, and encrypted live transcript sharing. Runs on-device using Apple's Speech and Translation frameworks.

## Core Capabilities

- **Transcribed Caption mode**: Captures system audio via CoreAudio process tap (`CATapDescription`) and transcribes/translates the caller on-device.
- **Conversational mode**: Adds microphone capture alongside system audio with acoustic-isolation / turn-taking arbitration for bidirectional live captions.
- **Live Link sharing**: Streams live captions via an embedded local web server with `AES-256-GCM` end-to-end encrypted payloads on `localhost` and over the optional `localhost.run` HTTPS SSH tunnel (`ssh_known_hosts` pinned; key stays in the `#k=` URL fragment), while optional LAN-only HTTP links stream unencrypted on the local Wi-Fi network.

## Requirements

- macOS 26+
- Apple Silicon

## Build, Run & Test

```bash
./build.sh
./run.sh
./test.sh
SANITIZE=thread ./test.sh
```

## License

[MIT](LICENSE)
