# Contributing

Thanks for helping. Issues and pull requests are welcome.

## Getting started

```sh
brew install xcodegen
make test
```

## Guidelines

- Keep the project dependency-free. If a library seems necessary, open an issue first.
- Add a test (Swift Testing) for any protocol or parsing change.
- Never weaken transport security. That means no plaintext `ws://`, no disabling certificate pinning, and no logging of client keys.
- Keep UI changes consistent with `Views/Components.swift`, and attach a `--snapshot` render to the PR.
- **Testing on another TV model?** Please mention the model and webOS version in your PR or issue, because compatibility reports are very useful.

## Reporting a bug

Include your macOS version, TV model, webOS version and what you expected to happen. The Activity tab in Settings, and `--probe` in a Debug build, often show the cause. Remove IP and MAC addresses before posting.
